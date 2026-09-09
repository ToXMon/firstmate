#!/usr/bin/env bash
# Tests for the Mission Control Kun advisor provenance ledger seam.

set -euo pipefail

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$ROOT/bin/fm-mission-kun-advisor.sh"
TMP_ROOT=$(fm_test_tmproot fm-mission-kun-advisor)

repo="$TMP_ROOT/repo"
ledger="$TMP_ROOT/ledger/kun-advisor.jsonl"
fm_git_init_commit "$repo"
head_sha=$(git -C "$repo" rev-parse HEAD)

output=$("$SCRIPT" checkpoint \
  --mission-id hackathon-alpha \
  --stage after-architecture \
  --repository "$repo" \
  --ledger "$ledger" \
  --summary "Kun found the ingestion path lacked a typed acceptance contract." \
  --accepted "Add a contract test before wiring workers." 2>&1)
assert_contains "$output" "recorded PRINCIPAL_ENGINEER_ADVISOR after-architecture" "checkpoint output names the advisor role and stage"
assert_contains "$output" "engineering critique only" "checkpoint output keeps Kun scoped to engineering advice"
[ "$(wc -l < "$ledger")" = 1 ] || fail "checkpoint did not append exactly one ledger line"

jq -e --arg repo "$repo" --arg sha "$head_sha" '
  .schema == "firstmate.mission_control.kun_advisor_checkpoint.v1" and
  .mission_id == "hackathon-alpha" and
  .checkpoint == "after-architecture" and
  (.timestamp | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")) and
  .advisor_role == "PRINCIPAL_ENGINEER_ADVISOR" and
  .advisor_skill.repository == "https://github.com/kunchenguid/kun" and
  .advisor_skill.install == "npx skills add kunchenguid/kun -g" and
  (.advisor_skill.live_files == ["ENTRY.md", "TOOLS.md", "OPINIONS.md", "VOICE.md"]) and
  .repository == $repo and
  .commit_sha == $sha and
  .summary == "Kun found the ingestion path lacked a typed acceptance contract." and
  .accepted_engineering_improvements == "Add a contract test before wiring workers."
' "$ledger" >/dev/null || fail "ledger record did not preserve checkpoint provenance"
pass "checkpoint records repository, commit, source files, and accepted improvements"

nongit="$TMP_ROOT/not-a-repo"
mkdir -p "$nongit"
"$SCRIPT" checkpoint \
  --mission-id bounty-beta \
  --stage before-final-qa \
  --repository "$nongit" \
  --ledger "$ledger" >/dev/null
jq -e 'select(.mission_id == "bounty-beta") | .commit_sha == null' "$ledger" >/dev/null \
  || fail "non-git repositories should record null commit_sha"
pass "checkpoint records null commit SHA when no git commit is available"

if "$SCRIPT" checkpoint \
  --mission-id bad \
  --stage prize-strategy \
  --repository "$repo" \
  --ledger "$TMP_ROOT/bad.jsonl" >/"$TMP_ROOT/bad.out" 2>&1; then
  fail "invalid checkpoint stage was accepted"
fi
assert_grep "invalid stage 'prize-strategy'" "$TMP_ROOT/bad.out" "invalid stage message was not actionable"
assert_absent "$TMP_ROOT/bad.jsonl" "invalid stage should not create a ledger"
pass "checkpoint refuses to turn Kun into a prize-strategy role"

stages=$("$SCRIPT" stages)
assert_contains "$stages" "after-idea-selection" "stages output missing idea-selection checkpoint"
assert_contains "$stages" "after-material-tradeoffs" "stages output missing tradeoff checkpoint"
pass "stages output lists bounded advisor checkpoints"
