#!/usr/bin/env bash
# tests/model-router.test.sh - behavioral tests for scripts/model-router-refresh
# against fixture catalogs and the committed config/model-roles.json.
#
# All catalog access goes through --catalog file:PATH fixtures or a stubbed
# offline environment (MODEL_ROLES_PI_BIN / MODEL_ROLES_SNAPSHOT pointing at
# nonexistent paths), so the suite never touches the network or the live
# Surplus credential store. Every assertion drives the executable's public
# interface; no implementation source bytes are asserted.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROUTER="$ROOT/scripts/model-router-refresh"
CONFIG="$ROOT/config/model-roles.json"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
[ -x "$ROUTER" ] || { echo "not ok - router is not executable"; exit 1; }

WORK="$(mktemp -d)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

copy_config() { cp "$CONFIG" "$WORK/roles.json"; printf '%s' "$WORK/roles.json"; }

healthy_catalog() { # <path> - every committed assignment and alternate stays healthy
  local ids
  ids=$(jq -r '[.roles[].model, (.roles[].alternates[]?)] | map(sub("^surplus/"; "")) | unique | .[]' "$CONFIG")
  {
    printf '%s\n' "$ids" | while IFS= read -r id; do printf '%s\n' "$id"; done
  } | jq -R -s '{catalogModels: (split("\n") | map(select(length > 0)) | map({id: ., active: true, toolCapable: true}))}' > "$1"
}

# 1. resolve answers every role with its configured model.
all_resolved=yes
while IFS= read -r role; do
  model=$(MODEL_ROLES_CONFIG="$CONFIG" "$ROUTER" resolve "$role" | sed -n 's/^model=//p')
  want=$(jq -r --arg r "$role" '.roles[$r].model' "$CONFIG")
  [ "$model" = "$want" ] || all_resolved=no
done <<EOF
FRONTIER_PLANNER
CODER
CHEAP_WORKER
SCOUT
CRITIC
EOF
[ "$all_resolved" = yes ] || fail "resolve did not return the configured model for every role"
pass "resolve returns the configured model for every role"

# 2. resolve rejects an unknown role with exit code 2.
if MODEL_ROLES_CONFIG="$CONFIG" "$ROUTER" resolve NOT_A_ROLE >/dev/null 2>&1; then
  fail "resolve accepted an unknown role"
fi
[ "$(MODEL_ROLES_CONFIG="$CONFIG" "$ROUTER" resolve NOT_A_ROLE >/dev/null 2>&1; echo $?)" = 2 ] \
  || fail "resolve of an unknown role did not exit 2"
pass "resolve rejects an unknown role with exit 2"

# 3. resolve --json emits a valid assignment object.
MODEL_ROLES_CONFIG="$CONFIG" "$ROUTER" resolve CODER --json > "$WORK/resolve.json" 2>/dev/null \
  || fail "resolve --json failed"
jq -e '.harness == "pi" and (.model | startswith("surplus/")) and (.effort | IN("low","medium","high","xhigh","max")) and (.fallback.harness == "codex")' \
  "$WORK/resolve.json" >/dev/null || fail "resolve --json payload is malformed"
pass "resolve --json emits a concrete assignment with the codex fallback"

# 4. emit-dispatch prints a five-rule crew-dispatch document.
MODEL_ROLES_CONFIG="$CONFIG" "$ROUTER" emit-dispatch > "$WORK/dispatch.json" 2>/dev/null \
  || fail "emit-dispatch failed"
jq -e '(.rules | length == 5) and (.rules[] | has("when") and (.use | has("harness") and has("model"))) and (.default | has("model"))' \
  "$WORK/dispatch.json" >/dev/null || fail "emit-dispatch document is malformed"
pass "emit-dispatch emits five dispatch rules plus a default profile"

# 5. refresh against a fully healthy catalog keeps assignments and verifies.
cfg=$(copy_config)
healthy_catalog "$WORK/healthy.json"
MODEL_ROLES_CONFIG="$cfg" "$ROUTER" refresh --catalog "file:$WORK/healthy.json" >/dev/null 2>&1 \
  || fail "refresh against a healthy catalog failed"
jq -e --arg c "$CONFIG" '.catalog.state == "verified"' "$cfg" >/dev/null || fail "healthy refresh did not mark state verified"
jq -S '.roles' "$cfg" > "$WORK/roles-a.json"
jq -S '.roles' "$CONFIG" > "$WORK/roles-b.json"
cmp -s "$WORK/roles-a.json" "$WORK/roles-b.json" || fail "healthy refresh changed role assignments"
pass "refresh over a healthy catalog keeps every assignment"

# 6. refresh promotes a healthy alternate when the primary goes unhealthy.
cfg=$(copy_config)
jq '.catalogModels += [{id: "qwen3-235b-a22b-2507", active: true, toolCapable: true}]' "$WORK/healthy.json" > "$WORK/promote.json"
jq '(.catalogModels[] | select(.id == "glm-5.2") | .active) = false' "$WORK/promote.json" > "$WORK/promote2.json" && mv "$WORK/promote2.json" "$WORK/promote.json"
MODEL_ROLES_CONFIG="$cfg" "$ROUTER" refresh --catalog "file:$WORK/promote.json" >/dev/null 2>&1 \
  || fail "refresh with an unhealthy primary failed"
[ "$(jq -r '.roles.CODER.model' "$cfg")" = "surplus/qwen3-235b-a22b-2507" ] \
  || fail "refresh did not promote the healthy alternate for CODER"
pass "refresh promotes a healthy alternate when the primary is unhealthy"

# 7. refresh keeps last-known-good and stays degraded when nothing is healthy.
cfg=$(copy_config)
printf '{"catalogModels": [{"id": "unrelated-model", "active": true, "toolCapable": true}]}' > "$WORK/empty.json"
MODEL_ROLES_CONFIG="$cfg" "$ROUTER" refresh --catalog "file:$WORK/empty.json" >/dev/null 2>&1 \
  || fail "refresh with no healthy models failed"
jq -e '.catalog.state == "degraded" and .fallback.harness == "codex"' "$cfg" >/dev/null \
  || fail "degraded refresh lost state or codex fallback"
jq -S '.roles' "$cfg" > "$WORK/roles-c.json"
cmp -s "$WORK/roles-c.json" "$WORK/roles-b.json" || fail "degraded refresh changed role assignments"
pass "refresh with no healthy catalog entry keeps last-known-good routing and the codex fallback"

# 8. refresh never reassigns a pinned manual override.
cfg=$(copy_config)
jq '.roles.CODER.pinned = true' "$cfg" > "$WORK/roles-pin.json" && mv "$WORK/roles-pin.json" "$cfg"
MODEL_ROLES_CONFIG="$cfg" "$ROUTER" refresh --catalog "file:$WORK/promote.json" 2>"$WORK/pin-warn.txt" >/dev/null \
  || fail "refresh with a pinned role failed"
[ "$(jq -r '.roles.CODER.model' "$cfg")" = "surplus/glm-5.2" ] \
  || fail "refresh reassigned a pinned manual override"
grep -q "pinned role CODER keeps manual assignment" "$WORK/pin-warn.txt" \
  || fail "pinned override was not reported with a warning"
pass "refresh leaves pinned manual overrides untouched with a warning"

# 9. refresh with no reachable catalog source preserves the file byte for byte.
cfg=$(copy_config)
before=$(sha256sum "$cfg" | cut -d' ' -f1)
MODEL_ROLES_CONFIG="$cfg" MODEL_ROLES_PI_BIN=/nonexistent-pi MODEL_ROLES_SNAPSHOT=/nonexistent-snap.json \
  "$ROUTER" refresh >/dev/null 2>&1 || fail "offline refresh failed"
after=$(sha256sum "$cfg" | cut -d' ' -f1)
[ "$before" = "$after" ] || fail "offline refresh modified the config file"
pass "refresh with no catalog source preserves the config byte for byte"

echo "model-router: all tests passed"
