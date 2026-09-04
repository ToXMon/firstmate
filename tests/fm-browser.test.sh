#!/usr/bin/env bash
# tests/fm-browser.test.sh - behavioral tests for the dedicated-Chrome lease
# lifecycle in bin/fm-browser.sh, driven entirely through a fake dedicated
# Chrome binary (FM_BROWSER_CHROME_BIN) that really serves /json/version on
# its allocated port. No real browser, no network beyond loopback, and no
# chrome-devtools-axi (FM_BROWSER_AXI_BIN points at a nonexistent path so
# bridge cleanup is skipped). Every assertion drives the executable's public
# interface; no implementation source bytes are asserted.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

BROWSER="$ROOT/bin/fm-browser.sh"
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }
[ -x "$BROWSER" ] || { echo "not ok - fm-browser.sh is not executable"; exit 1; }

TMP_ROOT=$(fm_test_tmproot fm-browser)
CASE="$TMP_ROOT/case"
HOME_DIR="$CASE/home"
mkdir -p "$HOME_DIR"

make_fake_chrome() { # kept local: thin wrapper over the shared fixture helper
  fm_test_fake_chrome "$1"
}

lease_json() { cat "$HOME_DIR/state/browser-leases/$1.json"; }

fresh_lease() { # <owner> [extra args...]
  local owner=$1; shift || true
  FM_HOME="$HOME_DIR" FM_BROWSER_AXI_BIN=/nonexistent-axi \
    FM_BROWSER_CHROME_BIN="$FAKE_CHROME" FM_BROWSER_START_TIMEOUT=15 \
    FM_TEST_FAKE_SERVE="$CASE/fakebin/serve.py" \
    FM_TEST_FAKE_CHROME_ARGS="$CASE/chrome.args" FM_TEST_FAKE_CHROME_PID="$CASE/chrome.pid" \
    "$BROWSER" lease "$owner" "$@"
}

destroy() { FM_HOME="$HOME_DIR" FM_BROWSER_AXI_BIN=/nonexistent-axi "$BROWSER" destroy "$1"; }

FAKE_CHROME=$(make_fake_chrome "$CASE/fakebin")

# 1. lease launches the dedicated binary, records identity, and exports env.
out=$(fresh_lease alpha) || fail "lease alpha failed"
assert_contains "$out" "lease alpha: browser_id=fmb-alpha-" "lease output missing browser_id line"
assert_contains "$out" "export CHROME_DEVTOOLS_AXI_BROWSER_URL=http://127.0.0.1:" \
  "lease output missing browser url export"
assert_contains "$out" "export CHROME_DEVTOOLS_AXI_SESSION=fmb-alpha-" \
  "lease output missing axi session export"
rec=$(lease_json alpha)
port=$(jq -r .cdp_port <<<"$rec")
[ "$port" != 9222 ] && [ "$port" != 9224 ] || fail "allocator picked a forbidden port: $port"
[ "$(jq -r .pid <<<"$rec")" = "$(cat "$CASE/chrome.pid")" ] || fail "record pid is not the launched process"
jq -e '.pid_start != null' <<<"$rec" >/dev/null || fail "record missing process start time"
grep -q -- "--remote-debugging-port=$port" "$CASE/chrome.args" || fail "launched without the recorded port"
grep -q -- "--user-data-dir=$HOME_DIR/state/browser-profiles/fmb-alpha-" "$CASE/chrome.args" \
  || fail "launched without a unique per-lease profile directory"
grep -q -- "--window-size=390,844" "$CASE/chrome.args" || fail "default window is not 390x844"
jq -e 'has("browser_id") and has("task_id") and has("pid") and has("cdp_port")
  and has("browser_url") and has("profile_path") and has("axi_session") and has("created_at")
  and has("chrome_bin") and has("pid_start") and has("window")' <<<"$rec" >/dev/null \
  || fail "lease record is missing required metadata keys"
jq -e --argjson p "$port" '.browser_url == ("http://127.0.0.1:" + ($p|tostring))
  and .task_id == "alpha" and (.browser_id | startswith("fmb-alpha-"))
  and .axi_session == .browser_id' <<<"$rec" >/dev/null \
  || fail "lease record metadata values are inconsistent"
pass "lease launches dedicated chrome with the required record metadata"

# 2. status and env answer for the live lease; unknown owners exit 2.
FM_HOME="$HOME_DIR" "$BROWSER" status alpha | grep -q "^alpha: running pid=" || fail "status does not report running lease"
FM_HOME="$HOME_DIR" "$BROWSER" status alpha --json | jq -e --argjson p "$port" '.health == "running" and .cdp_port == $p' >/dev/null \
  || fail "status --json lost record fields or health"
FM_HOME="$HOME_DIR" "$BROWSER" status alpha >/dev/null 2>&1 && pass "status answers a live lease" || fail "status failed"
if FM_HOME="$HOME_DIR" "$BROWSER" status no-such-owner >/dev/null 2>&1; then
  fail "status accepted an unknown owner"
fi
[ "$(FM_HOME="$HOME_DIR" "$BROWSER" status no-such-owner >/dev/null 2>&1; echo $?)" = 2 ] \
  || fail "unknown owner status did not exit 2"
FM_HOME="$HOME_DIR" "$BROWSER" env alpha | grep -q "^export CHROME_DEVTOOLS_AXI_BROWSER_URL=http://127.0.0.1:$port$" \
  || fail "env output wrong url"
pass "status and env report the live lease; unknown owners exit 2"

# 3. a second lease for the same owner is refused with exit 3.
if fresh_lease alpha >/dev/null 2>&1; then fail "second lease for alpha succeeded"; fi
[ "$(fresh_lease alpha >/dev/null 2>&1; echo $?)" = 3 ] || fail "duplicate lease did not exit 3"
pass "duplicate lease refused with exit 3"

# 4. destroying the live lease kills the process and removes every trace.
destroy alpha | grep -q "^destroyed alpha" || fail "destroy did not report success"
kill -0 "$(cat "$CASE/chrome.pid")" 2>/dev/null && fail "fake chrome survived destroy"
[ -f "$HOME_DIR/state/browser-leases/alpha.json" ] && fail "lease record survived destroy"
ls "$HOME_DIR/state/browser-profiles/" 2>/dev/null | grep -q "^alpha-" && fail "profile dir survived destroy"
[ -z "$(ls "$HOME_DIR/state/browser-profiles/" 2>/dev/null)" ] || fail "unexpected leftovers in profiles dir"
pass "destroy kills the leased process and removes record and profile"

# 5. env and destroy refuse a dead lease; destroy then cleans the leftovers.
fresh_lease beta >/dev/null || fail "lease beta failed"
beta_pid=$(lease_json beta | jq -r .pid)
kill "$beta_pid" 2>/dev/null; sleep 1
if FM_HOME="$HOME_DIR" "$BROWSER" env beta >/dev/null 2>&1; then fail "env accepted a dead lease"; fi
FM_HOME="$HOME_DIR" "$BROWSER" status beta | grep -q "^beta: dead" || fail "status does not report dead lease"
destroy beta | grep -q "was already dead" || fail "destroy of dead lease did not take the dead path"
[ -f "$HOME_DIR/state/browser-leases/beta.json" ] && fail "dead lease record survived destroy"
pass "dead lease is reported, env is refused, and destroy cleans records"

# 6. destroy refuses to signal a pid that no longer matches the lease.
fresh_lease gamma >/dev/null || fail "lease gamma failed"
sleep 60 &
foreign_pid=$!
lease_json gamma | jq --argjson p "$foreign_pid" '.pid = $p | .pid_start = null' > "$CASE/gamma-tampered" \
  && mv "$CASE/gamma-tampered" "$HOME_DIR/state/browser-leases/gamma.json"
if FM_HOME="$HOME_DIR" "$BROWSER" destroy gamma >/dev/null 2>&1; then
  fail "destroy signaled a pid that does not match the lease"
fi
FM_HOME="$HOME_DIR" "$BROWSER" destroy gamma 2>&1 | grep -q "REFUSED" || fail "refusal lacks evidence output"
kill -0 "$foreign_pid" 2>/dev/null || fail "refused destroy still killed the foreign process"
[ -f "$HOME_DIR/state/browser-leases/gamma.json" ] || fail "refused destroy dropped the lease record"
FM_HOME="$HOME_DIR" "$BROWSER" status gamma | grep -q "^gamma: foreign" || fail "status does not flag foreign pid"
kill "$foreign_pid" 2>/dev/null || true
pass "destroy refuses a foreign pid and keeps the record as evidence"

# 7. a recycled pid (same pid, new start time) is also refused.
fresh_lease delta >/dev/null || fail "lease delta failed"
delta_json="$HOME_DIR/state/browser-leases/delta.json"
jq '.pid_start = (if .pid_start == null then "1" else (.pid_start + "0") end)' "$delta_json" > "$CASE/delta-tampered" \
  && mv "$CASE/delta-tampered" "$delta_json"
if FM_HOME="$HOME_DIR" FM_BROWSER_AXI_BIN=/nonexistent-axi "$BROWSER" destroy delta >/dev/null 2>&1; then
  fail "destroy accepted a recycled pid"
fi
FM_HOME="$HOME_DIR" "$BROWSER" status delta | grep -q "^delta: foreign" || fail "recycled pid not flagged foreign"
# Restore the true start time and the same live lease must destroy normally.
true_start=$(awk '{print $22}' "/proc/$(jq -r .pid "$delta_json")/stat" 2>/dev/null || true)
if [ -n "$true_start" ]; then
  jq --arg s "$true_start" '.pid_start = $s' "$delta_json" > "$CASE/delta-fixed" && mv "$CASE/delta-fixed" "$delta_json"
  destroy delta | grep -q "^destroyed delta" || fail "destroy failed after restoring identity"
else
  destroy delta | grep -q "^destroyed delta" || fail "destroy failed on a host without /proc start times"
fi
pass "recycled-pid start-time mismatch is refused; true identity still destroys"

# 8. owner and flag validation.
if FM_HOME="$HOME_DIR" "$BROWSER" lease 'bad owner!' >/dev/null 2>&1; then fail "invalid owner accepted"; fi
if FM_HOME="$HOME_DIR" "$BROWSER" env >/dev/null 2>&1; then fail "env without owner accepted"; fi
if FM_HOME="$HOME_DIR" "$BROWSER" lease eps --window notawindow >/dev/null 2>&1; then fail "bad window accepted"; fi
pass "owner and window validation refuse bad input"

# 9. custom window size reaches chrome and the record.
out=$(fresh_lease zeta --window 800x600) || fail "lease with custom window failed"
grep -q -- "--window-size=800,600" "$CASE/chrome.args" || fail "custom window not passed to chrome"
lease_json zeta | jq -e '.window == "800,600"' >/dev/null || fail "record lost custom window"
destroy zeta >/dev/null || fail "destroy zeta failed"
pass "custom window size is honored end to end"

# 10. the scripts/browser-lease-* entry points are reusable wrappers.
EP_CREATE="$ROOT/scripts/browser-lease-create"
EP_STATUS="$ROOT/scripts/browser-lease-status"
EP_DESTROY="$ROOT/scripts/browser-lease-destroy"
for ep in "$EP_CREATE" "$EP_STATUS" "$EP_DESTROY"; do
  [ -x "$ep" ] || fail "entry point not executable: $ep"
done
FM_HOME="$HOME_DIR" FM_BROWSER_AXI_BIN=/nonexistent-axi \
  FM_BROWSER_CHROME_BIN="$FAKE_CHROME" FM_BROWSER_START_TIMEOUT=15 \
  FM_TEST_FAKE_SERVE="$CASE/fakebin/serve.py" \
  FM_TEST_FAKE_CHROME_ARGS="$CASE/chrome.args" FM_TEST_FAKE_CHROME_PID="$CASE/chrome.pid" \
  "$EP_CREATE" entry --window 390x844 >/dev/null || fail "browser-lease-create failed"
FM_HOME="$HOME_DIR" "$EP_STATUS" entry | grep -q "^entry: running pid=" || fail "browser-lease-status did not report the lease"
lease_json entry | jq -e '.task_id == "entry" and (.browser_url | startswith("http://127.0.0.1:"))' >/dev/null \
  || fail "entry-point lease record is malformed"
FM_HOME="$HOME_DIR" FM_BROWSER_AXI_BIN=/nonexistent-axi "$EP_DESTROY" entry | grep -q "^destroyed entry" \
  || fail "browser-lease-destroy failed"
[ -f "$HOME_DIR/state/browser-leases/entry.json" ] && fail "entry-point lease record survived destroy"
pass "scripts/browser-lease-create/status/destroy are reusable entry points"

# 11. the home is required explicitly.
if env -u FM_HOME "$BROWSER" status >/dev/null 2>&1; then fail "status ran with no home"; fi
pass "home resolution fails closed"

echo "fm-browser: all tests passed"
