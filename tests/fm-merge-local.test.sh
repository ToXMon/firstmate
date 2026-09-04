#!/usr/bin/env bash
# tests/fm-merge-local.test.sh - behavioral tests for bin/fm-merge-local.sh,
# the guarded local-only landing helper, covering the detected-default path
# and the explicit --target-branch option. Every case drives the executable
# against a real throwaway git project; no implementation source is asserted.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

MERGE="$ROOT/bin/fm-merge-local.sh"
TMP_ROOT=$(fm_test_tmproot fm-merge-local)

make_case() { # <name> -> prints "home|proj|meta"
  local name=$1 home proj id
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/proj"
  mkdir -p "$home/state"
  fm_git_init_commit "$proj"
  git -C "$proj" branch -m main
  id="mml-$name"
  fm_write_meta "$home/state/$id.meta" "project=$proj" "mode=local-only" "task=$id"
  printf '%s|%s|%s' "$home" "$proj" "$id"
}

# Run like tests/fm-branch-supervision.test.sh does: plain FM_HOME scoping,
# letting bin/fm-guard.sh emit its advisory banners untouched.
run_merge() { # <home> <task-id> [extra args...]
  local home=$1 id=$2
  shift 2
  FM_HOME="$home" "$MERGE" "$id" "$@"
}

commit_on() { # <proj> <branch> <file> <content>
  local proj=$1 branch=$2 file=$3 content=$4
  git -C "$proj" checkout -q "$branch"
  printf '%s\n' "$content" > "$proj/$file"
  git -C "$proj" add "$file"
  git -C "$proj" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm "$content"
}

# 1. default landing fast-forwards the detected default branch.
read -r HOME_DIR PROJ ID < <(make_case plain | tr '|' ' ')
commit_on "$PROJ" main work.txt default-landed
git -C "$PROJ" branch "fm/$ID"
out=$(run_merge "$HOME_DIR" "$ID")
status=$?
expect_code 0 "$status" "default landing should succeed"
assert_contains "$out" "merged fm/$ID into local main (" "default landing reported the wrong target"
[ "$(git -C "$PROJ" rev-parse main)" = "$(git -C "$PROJ" rev-parse "fm/$ID")" ] \
  || fail "default landing did not fast-forward main"
pass "default landing fast-forwards the detected default branch"

# 2. --target-branch lands onto the named local branch.
read -r HOME_DIR PROJ ID < <(make_case target | tr '|' ' ')
git -C "$PROJ" branch harness/integration
git -C "$PROJ" checkout -q harness/integration
commit_on "$PROJ" harness/integration integration.txt seeded
git -C "$PROJ" checkout -q -b "fm/$ID"
commit_on "$PROJ" "fm/$ID" work.txt targeted-landed
git -C "$PROJ" checkout -q harness/integration
out=$(run_merge "$HOME_DIR" "$ID" --target-branch harness/integration)
status=$?
expect_code 0 "$status" "--target-branch landing should succeed"
assert_contains "$out" "merged fm/$ID into local harness/integration (" "target landing reported the wrong target"
[ "$(git -C "$PROJ" rev-parse harness/integration)" = "$(git -C "$PROJ" rev-parse "fm/$ID")" ] \
  || fail "target landing did not fast-forward harness/integration"
pass "--target-branch lands onto the named local branch"

# 3. --target-branch refuses a name that is not a local branch.
read -r HOME_DIR PROJ ID < <(make_case notlocal | tr '|' ' ')
git -C "$PROJ" checkout -q -b "fm/$ID"
commit_on "$PROJ" "fm/$ID" work.txt notlocal-work
git -C "$PROJ" checkout -q main
if run_merge "$HOME_DIR" "$ID" --target-branch no-such-branch >/dev/null 2>&1; then
  fail "--target-branch accepted a branch that does not exist"
fi
run_merge "$HOME_DIR" "$ID" --target-branch no-such-branch 2>&1 | grep -q "not a local branch" \
  || fail "non-local target refusal lacks the reason"
[ "$(git -C "$PROJ" rev-parse main)" != "$(git -C "$PROJ" rev-parse "fm/$ID")" ] \
  || fail "refused target landing still moved main"
pass "--target-branch refuses a non-local branch without merging"

# 4. --target-branch refuses when the checkout is not on the target.
read -r HOME_DIR PROJ ID < <(make_case wrongcur | tr '|' ' ')
git -C "$PROJ" branch harness/integration
git -C "$PROJ" checkout -q -b "fm/$ID"
commit_on "$PROJ" "fm/$ID" work.txt wrongcur-work
git -C "$PROJ" checkout -q main
if run_merge "$HOME_DIR" "$ID" --target-branch harness/integration >/dev/null 2>&1; then
  fail "target landing accepted a checkout sitting on a different branch"
fi
run_merge "$HOME_DIR" "$ID" --target-branch harness/integration 2>&1 | grep -q "expected landing target 'harness/integration'" \
  || fail "wrong-checkout refusal lacks the reason"
pass "--target-branch refuses when the checkout is not on the target"

# 5. a diverged branch is refused for a named target exactly as for the default.
read -r HOME_DIR PROJ ID < <(make_case diverged | tr '|' ' ')
git -C "$PROJ" branch harness/integration
git -C "$PROJ" checkout -q harness/integration
commit_on "$PROJ" harness/integration integration.txt diverged-seed
git -C "$PROJ" checkout -q -b "fm/$ID" HEAD~1 2>/dev/null || git -C "$PROJ" checkout -q -b "fm/$ID"
commit_on "$PROJ" "fm/$ID" work.txt diverged-work
git -C "$PROJ" checkout -q harness/integration
if run_merge "$HOME_DIR" "$ID" --target-branch harness/integration >/dev/null 2>&1; then
  fail "diverged branch landed despite not being a fast-forward"
fi
run_merge "$HOME_DIR" "$ID" --target-branch harness/integration 2>&1 | grep -q "REFUSED" \
  || fail "divergence refusal missing"
pass "a diverged branch is refused for a named target"

# 6. a dirty working tree on the target is refused.
read -r HOME_DIR PROJ ID < <(make_case dirty | tr '|' ' ')
git -C "$PROJ" branch harness/integration
git -C "$PROJ" checkout -q harness/integration
commit_on "$PROJ" harness/integration integration.txt dirty-seed
git -C "$PROJ" checkout -q -b "fm/$ID"
commit_on "$PROJ" "fm/$ID" work.txt dirty-work
git -C "$PROJ" checkout -q harness/integration
printf 'uncommitted\n' > "$PROJ/integration.txt"
if run_merge "$HOME_DIR" "$ID" --target-branch harness/integration >/dev/null 2>&1; then
  fail "dirty tree accepted for target landing"
fi
run_merge "$HOME_DIR" "$ID" --target-branch harness/integration 2>&1 | grep -q "dirty working tree" \
  || fail "dirty-tree refusal lacks the reason"
pass "a dirty working tree on the target is refused"

# 7. only mode=local-only tasks may land, target option or not.
read -r HOME_DIR PROJ ID < <(make_case wrongmode | tr '|' ' ')
fm_write_meta "$HOME_DIR/state/$ID.meta" "project=$PROJ" "mode=no-mistakes" "task=$ID"
git -C "$PROJ" checkout -q -b "fm/$ID"
if run_merge "$HOME_DIR" "$ID" --target-branch main >/dev/null 2>&1; then
  fail "non-local-only task landed locally"
fi
run_merge "$HOME_DIR" "$ID" --target-branch main 2>&1 | grep -q "not local-only" \
  || fail "mode refusal lacks the reason"
pass "non-local-only tasks are refused regardless of the target option"

echo "fm-merge-local: all tests passed"
