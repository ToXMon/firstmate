# Multi-model crew role routing verification

Audience: maintainer verification.

This record supports the semantic role routing in `config/model-roles.json` and the refresh tooling in `scripts/model-router-refresh`.
It records the live catalog evidence, per-role selection rationale, pricing limitations, fallback posture, and the exact commands and observed results that back the current routing.
Task chronology and per-run transcripts stay in private task reports or PR evidence.

## What is verified

`scripts/model-router-refresh resolve <ROLE>` answers a stable role name (`FRONTIER_PLANNER`, `CODER`, `CHEAP_WORKER`, `SCOUT`, `CRITIC`) with a concrete worker assignment (`harness`, `model`, `effort`) resolved from `config/model-roles.json`.
`model-router-refresh refresh` revalidates those assignments against the live Surplus catalog through pi's dynamic provider registry and the credential-free provider snapshot, promotes a healthy alternate when an assignment goes unhealthy, and preserves the last-known-good routing byte for byte when no catalog source is reachable.
Behavioral coverage for resolve, dispatch emission, alternate promotion, last-known-good retention, pinned manual overrides, and offline preservation lives in `tests/model-router.test.sh`, which runs entirely against fixture catalogs and stubbed offline sources.

## Environment

Verified 2026-09-03 on the acceptance host with pi 0.84.4, the global `~/.pi/agent/extensions/surplus.ts` provider extension registered against `https://api.surplusintelligence.ai/v1`, herdr 0.8.2, jq 1.7, and bash 5.
The Surplus catalog snapshot used for metadata (`~/.cache/dev-harness/surplus-models.json`) was refreshed live at 2026-09-03T04:17:25Z and reported 211 text-output models, of which the entries below were selected.

## Live catalog evidence and role selection

Selection rule: only models labeled `active` (healthy sellers in `/api/markets`) and tool-capable (`tools` in `supported_parameters` or `supported_features`) in the live snapshot were eligible, and every selected assignment then passed two live smoke tests through pi itself:

- an exact-string inference test: `pi --model surplus/<id> --no-session -p 'Reply with exactly this string and nothing else: OK-<slug>'`
- a real tool-call round trip: `pi --model surplus/<id> --no-session -p 'You must call your bash tool to run exactly: echo TOOLCALL-<slug>. After observing its output, reply with only that observed output.'`

Observed results, 2026-09-03 (inference/tool wall-clock seconds):

| Model | Role | Inference | Tool call | Reason |
|---|---|---|---|---|
| `surplus/claude-sonnet-5` | FRONTIER_PLANNER | pass (5s) | pass (13s) | frontier planning quality, 1M context, reasoning |
| `surplus/glm-5.2` | CODER | pass (4s) | pass (21s) | strong tool-using coder, 1M context; drove a full agentic session locally |
| `surplus/glm-5.3-flash` | CHEAP_WORKER | pass (40s cold, 8s warm) | pass (8s) | cheapest smoke-verified tool-capable reasoning model |
| `surplus/deepseek-v4-flash` | SCOUT | pass (4s) | pass (5s) | very cheap reasoning investigator, 1M context |
| `surplus/minimax-m2.1` | CRITIC | pass (2s) | pass (4s) | independent reviewer from a different model family than the coders |

Alternates also smoke-verified: `gemini-3.1-pro` (4s/8s), `qwen3-235b-a22b-2507` (3s/3s), `grok-4.1-fast` (3s/4s), `qwen3.5-flash` (5s/5s).
The CRITIC assignment deliberately sits on a different model family and context than CODER and its alternate, so implementation and review do not share a model.

## Pricing metadata and its limits

Per-role list prices are recorded in `config/model-roles.json` in USD per million tokens, converted from the Surplus `/v1/models` per-token decimals by the pi provider extension.
Known limitations, stated honestly: values are catalog-declared list prices at snapshot time, not invoice-verified amounts; marketplace seller pricing can differ from the catalog entry at billing time; and the `active` label reflects healthy sellers only at catalog refresh time.
No credential material appears in the config, the snapshot, this record, or the router.

## Codex fallback posture

The config preserves `codex`/`gpt-5.5` as the high-reliability escalation for every role when the Surplus path cannot serve a task: assigned model unhealthy, alternates unhealthy, or the catalog unreachable.
The codex CLI is not installed on the acceptance host (`command -v codex` finds nothing), so this fallback is documented and structurally preserved (refresh never modifies the fallback block) but was not smoke-tested in this environment.
Refresh is verified to keep the fallback block intact across healthy, degraded, and offline runs.

## Refresh verification

Commands run against the committed config on 2026-09-03:

- `scripts/model-router-refresh refresh` against the live registry: `refreshed .../config/model-roles.json`, `catalog: verified (last checked 2026-09-03T04:39:49Z)`, all five assignments retained.
- `scripts/model-router-refresh status` / `resolve <ROLE>` / `emit-dispatch`: expected outputs, unknown roles exit 2.
- `tests/model-router.test.sh`: all nine behavioral tests passed.
- `bash -n scripts/model-router-refresh tests/model-router.test.sh`: clean.

The pinned ShellCheck lint (`bin/fm-lint.sh`) could not run on the acceptance host because ShellCheck is not installed there; both scripts passed `bash -n` and await the pinned CI lint.
Re-run `bin/fm-lint.sh` and the colocated test suite after any change to the router or the roles file, and re-establish the smoke table above whenever the Surplus provider extension or pi version changes materially.

## LIVE CREW ACCEPTANCE

Audience: maintainer verification of the actual dispatch path, not just the router script in isolation.
This section records a real end-to-end run: a live Firstmate acceptance worktree (based on commit `35da744`), a temporary nested `FM_HOME`, a named non-`default` Herdr lab session, `bin/fm-spawn.sh` launching real `pi` workers against real Surplus models, and a real Codex-fallback smoke test - all torn down afterward with the captain's own Firstmate and Herdr left untouched. Every command below was actually executed on 2026-09-03; no worker, model call, or tool call was simulated, mocked, or performed by the acceptance agent standing in for a worker.

### Environment

pi 0.84.4, herdr 0.8.2, jq 1.7, bash 5.2.21, on the same acceptance host as the routing verification above. The captain's live Herdr `default` session was confirmed running (`herdr session list --json`) before any lab session was provisioned.

### Isolation: Herdr lab session and temporary FM_HOME

```
HERDR_LAB_HELPER=.../bin/fm-herdr-lab.sh
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name multi-model-crew-live)   # -> fm-lab-multi-model-crew-1984463-4902
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION"                    # exit 0; tripwire recorded default session state
export FM_HOME=<worktree>/.acceptance-fm-home   # scratch, nested under this worktree; never the primary FM_HOME
export HERDR_SESSION="$HERDR_LAB_SESSION"
echo off > "$FM_HOME/config/herdr-presentation-spaces"   # disable workspace-projection nesting for this scratch home
```

All five spawns below ran with `--backend herdr` and this `HERDR_SESSION`, so `fm-spawn.sh` created real, separate Herdr panes for every worker inside the named lab session, never the captain's `default` session.

### Disposable mobile-first web project

A throwaway static site (`index.html`, `src/style.css` with a `@media (min-width: 768px)` breakpoint, `src/app.js`) was created inside the worktree at `.acceptance-scratch/`, given a local bare `origin` remote and a `main` branch (required so `fm-spawn.sh`'s pooled-worktree fetch-before-launch check succeeds), committed once (`951a0f2`), and used as the project every worker below was dispatched against. It and its bare remote were deleted at cleanup; nothing from it was committed to this repository.

### Role resolution and live model-router evidence

Before any dispatch, `scripts/model-router-refresh status`, `refresh`, and `resolve <ROLE> --json` were run live against the committed config (see "Refresh verification" above for the exact refresh result: all five assignments retained, only `catalog.lastChecked` advanced). All five resolved roles' models were independently confirmed present and tool-capable in a fresh `pi --list-models surplus` listing, and each passed a live inference smoke test and a live bash-tool-call smoke test through `pi` directly (see the per-role transcript archived with this task's evidence). No assignment required moving to an alternate; live availability was confirmed without changing any assignment, satisfying the acceptance requirement to use an alternate only when a live failure requires it.

One artifact surfaced and is recorded here honestly rather than hidden: an ad-hoc `pi --model surplus/glm-5.3-flash -p ...` probe that omitted `--thinking` failed with a live `400 request_rejected` ("This model always engages in thinking and cannot be disabled"). This is a property of the raw CLI probe, not of the router or of real dispatch: `bin/fm-spawn.sh`'s `effort_flag_for_harness` always maps a `pi`-harness `--effort` value to `--thinking <level>`, so CHEAP_WORKER's actual spawn (`--effort low`) supplied `--thinking low` automatically and its real dispatched worker ran normally (see below). Retrying the ad-hoc probe with `--thinking low` passed.

### Dispatch: FRONTIER_PLANNER, then CODER and CHEAP_WORKER in parallel, then CRITIC

Each role was resolved with `scripts/model-router-refresh resolve <ROLE> --json` and dispatched with exactly that harness/model/effort through `bin/fm-spawn.sh --backend herdr`, never hand-picked.

| Role | Provider/model | Effort | Herdr session:workspace:tab:pane | Worktree | Kind |
|---|---|---|---|---|---|
| FRONTIER_PLANNER | `pi` / `surplus/claude-sonnet-5` | high | `fm-lab-...4902:w2:t2:p2` | `.../mmc-app-main-f2f148/1/mmc-app-main` | scout (plan report) |
| CODER | `pi` / `surplus/glm-5.2` | high | `fm-lab-...4902:w2:t3:p3` | `.../mmc-app-main-f2f148/2/mmc-app-main` | ship, local-only, branch `fm/mmc-coder` |
| CHEAP_WORKER | `pi` / `surplus/glm-5.3-flash` | low | `fm-lab-...4902:w2:t4:p4` | `.../mmc-app-main-f2f148/3/mmc-app-main` | ship, local-only, branch `fm/mmc-cheap` |
| CRITIC | `pi` / `surplus/minimax-m2.1` | high | `fm-lab-...4902:w2:t5:p5` | `.../mmc-app-main-f2f148/4/mmc-app-main` | scout (review report) |

Each `worktree=` path above was confirmed distinct and physically separate (four different treehouse pool directories, `1/` through `4/`) via each task's own `state/<id>.meta`.

**FRONTIER_PLANNER** actually read `index.html`, `src/style.css`, and `src/app.js` with its file tools and ran `git log --oneline` / `git status` / `git branch -a` with its bash tool before writing a plan (architecture, file-by-file decomposition, an explicit CODER/CHEAP_WORKER parallel-branch dependency contract keyed on an exported `toggleStatus(currentText) -> string` function, and three concrete acceptance criteria) to its report. It made no code changes and needed no captain decision.

**CODER and CHEAP_WORKER ran concurrently** (background-launched together; `mmc-cheap`'s first launch attempt hit a transient "task set is locked by another operation" error from the two spawns racing the same home's lock and was retried once, succeeding independently of CODER). Each created its own branch from the same base commit `951a0f2` in its own isolated worktree:

- CODER (`glm-5.2`) committed `e989045`: added `aria-live="polite"` and a `#toggle` button to `index.html`, a pure `toggleStatus` function plus click-handler wiring and a `module.exports` guard to `src/app.js`, and a 44px touch-target rule to `src/style.css`. It ran `node -e "const {toggleStatus}=require('./src/app.js'); ..."` itself and reported the real output (`paused ready`).
- CHEAP_WORKER (`glm-5.3-flash`, effort `low`) committed `539cc8d`: added `tests/toggle.test.mjs`, a dependency-free Node test asserting `toggleStatus('ready') === 'paused'` and the reverse. Per its brief, it ran the test against its *own* unmerged worktree (which does not yet have `toggleStatus`) and honestly reported the real failure (`ReferenceError: document is not defined`, exit 1) rather than hiding it - the test's correctness against the finished implementation was left for the merge-safety check below.

**Merge-safety proof**: both branches were fetched into a fresh clone of the same disposable project and merged in sequence (`main` + `fm/mmc-coder` + `fm/mmc-cheap`); `node tests/toggle.test.mjs` then exited 0 (`PASS: toggleStatus toggles ready<->paused`) against the merged `src/app.js`, proving the two independently-built branches are merge-safe exactly as FRONTIER_PLANNER's plan specified. This merged state was pushed to the disposable project's `origin` as `fm/mmc-integration` for CRITIC to inspect.

**CRITIC** (`minimax-m2.1`) was dispatched as a scout against the same disposable project, independently checked out `fm/mmc-integration`, and - using its own file/bash tools, not by trusting the plan or the other workers' claims - re-read the plan and the merged files, re-ran `node tests/toggle.test.mjs` itself (confirmed exit 0), and reviewed edge cases (rapid double-click, keyboard Enter/Space activation, initial load, repeated toggling), maintainability, and security (confirmed `textContent` only, no `innerHTML`/`eval`). Its verdict: **no substantive issues found**, all three acceptance criteria pass. Because no substantive issue was found, no repair task was created; the "create explicit repair work and rerun validation" branch of the acceptance requirement was not exercised in this run, and that is reported here as a limitation rather than a hidden gap.

### Codex fallback: real smoke test through pi

`command -v codex` finds nothing on this host (no standalone Codex CLI installed), but pi itself exposes the same GPT-5.5 target through its own `openai-codex` provider, which is what a pi-harness worker facing the configured `codex`/`gpt-5.5` fallback actually reaches. Both required probes were run live and passed:

- Harmless inference: `pi --model openai-codex/gpt-5.5 --no-session -p "Reply with exactly this string..."` returned live model output (`OK-codex-fallback`, prefixed with an unrelated "Captain, " framing artifact injected by this host's global pi system prompt - not a provider or routing defect; the same artifact appears independent of role or provider on this host).
- Harmless tool call: `pi --model openai-codex/gpt-5.5 --no-session --approve -p "...call your bash tool..."` returned `TOOLCALL-codexfallback`, exit 0, with no framing artifact.

**Verdict: PASS.** Normal crew routing (`config/model-roles.json`, `scripts/model-router-refresh`) was not touched by this test.

### Reversible preferred-model failure test

Using a temporary copy of the live config and a temporary fixture catalog file (`--catalog file:PATH`), never the live `config/model-roles.json`:

1. **Alternate selection**: fixture marked `glm-5.2` (CODER's preferred model) unhealthy, `qwen3-235b-a22b-2507` (its configured alternate) healthy. `model-router-refresh refresh --catalog file:...` against the temp copy reassigned CODER to the alternate (`reassignment CODER: surplus/glm-5.2 -> surplus/qwen3-235b-a22b-2507`).
2. **Codex-fallback escalation contract**: fixture marked both `glm-5.2` and its alternate unhealthy. Refresh against a second temp copy kept the last-known-good assignment (`surplus/glm-5.2`), set `catalog.state` to `degraded`, and `resolve CODER --json` still carried the `fallback: {"harness":"codex","model":"gpt-5.5"}` block - proving the documented escalation order (assigned model -> alternates -> codex fallback -> hold) stays intact and available to the dispatcher exactly when both live tiers fail.

`md5sum` of `config/model-roles.json` was captured before both tests and re-verified identical afterward (`OK`); the temporary copies and fixture file were deleted at cleanup.

### Cleanup

All four workers were torn down with `bin/fm-teardown.sh <id>` (CRITIC first needed `bin/fm-captain-hold.sh complete mmc-critic --none` to pass the captain-call completion gate, since its report held no open decision). Each teardown returned its treehouse worktree to the pool and closed its Herdr pane; `herdr workspace list` in the lab session showed zero workspaces afterward. The lab session itself was then torn down with `"$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION"`, which re-verified the captain's `default` session was unchanged (its own fleet-state tripwire) before deleting the lab session. `herdr session list --json` afterward showed only `default`, `pi`, and `iphone-test` - the lab session and every worker pane were gone, the captain's fleet was undisturbed. The disposable web project, its bare remote, the merge-check clone, the temporary nested `FM_HOME`, and every orphaned treehouse pool directory (`treehouse destroy --all --include-unlanded --yes`, since their backing scratch repos were already removed) were deleted.

### Honest limitations

- CRITIC found no substantive issue in this run, so the repair-dispatch-and-rerun path of the acceptance requirement was exercised only as a no-op (explicitly confirmed and not required), not with an actual repair worker; a future run that wants to exercise that specific path would need to seed a real defect for CRITIC to catch.
- The Codex fallback was smoke-tested through pi's own `openai-codex` provider addressing (`openai-codex/gpt-5.5`), since no standalone `codex` CLI binary is installed on this host; this reaches the same live GPT-5.5 target a pi-harness worker's fallback path would use, but a host with the standalone Codex CLI installed would additionally prove that binary's own invocation.
- A one-time transient lock contention on the concurrent CODER/CHEAP_WORKER spawn required one retry of the second spawn; it is recorded here rather than silently retried and omitted.
- All work in this section lived in a disposable scratch project and scratch `FM_HOME` inside this worktree, deleted at cleanup; nothing from the disposable project is committed to this repository.
