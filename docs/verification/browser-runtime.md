# Dedicated-Chrome browser runtime verification

Audience: maintainer verification.

This record supports the dedicated-Chrome browser runtime: `bin/fm-browser.sh` (lease lifecycle), the `bin/fm-spawn.sh` lease-env seam, the `bin/fm-teardown.sh` best-effort lease cleanup, the `WEB_RESEARCH` and `BROWSER_OPERATOR` roles in `config/model-roles.json` and `scripts/model-router-refresh`, and the acceptance evidence behind the current role assignments.
Task chronology and per-run transcripts stay in private task reports or PR evidence.

## What is verified

`bin/fm-browser.sh lease` launches a dedicated headless Chrome with a single-use profile, a dynamically allocated loopback CDP port (9222 and 9224 refused), and a unique chrome-devtools-axi named session; `status`, `env`, and `destroy` answer lease health, export lines, and verified-ownership teardown.
The behavioral coverage in `tests/fm-browser.test.sh` drives all of that against a fake dedicated Chrome with no network beyond loopback, including the duplicate-lease refusal, the dead-lease paths, the foreign-pid refusal (identity mismatch keeps the record and signals nothing), the recycled-pid start-time refusal, and fail-closed home resolution.
The dispatch seam is covered in `tests/fm-spawn-dispatch-profile.test.sh`: a real lease's exports reach the worker pane before launch, and a no-lease control run sends no browser env.
The router's browser roles are covered in `tests/model-router.test.sh` (seven rules, browser rules ordered ahead of the generic coding rule).
Live end-to-end coverage, opt-in via `FM_BROWSER_LIVE_E2E=1`, is `tests/fm-browser-runtime-live-e2e.test.sh`, registered in the `live-harness-optin` family.

## Environment

Verified 2026-09-04 on Ubuntu 24.04 (kernel 6.8, `apparmor_restrict_unprivileged_userns=1`) with Google Chrome 148.0.7778.215 at `/home/opadmin/.local/chrome/opt/google/chrome/chrome`, chrome-devtools-axi 0.1.33, pi 0.84.4 with the surplus provider extension, jq 1.7, python 3.12.3, and bash 5.2.21.

## Live one-worker acceptance

`FM_BROWSER_LIVE_E2E=1 bash tests/fm-browser-runtime-live-e2e.test.sh`, 2026-09-04, passed every check:

- navigation (`open`) and `snapshot` exposing interactive refs;
- `fill` landing its value in the textbox (asserted through `eval`, not the CLI echo);
- click-through submit navigating to the thanks page with the filled value in DOM text and `localStorage`;
- console capture of the boot and submit markers and network capture of the fixture `api.json` fetch;
- exact 390x844 viewport via `eval` of `innerWidth`/`innerHeight` and a screenshot parsed as exactly 390x844 pixels;
- the CDP endpoint bound to 127.0.0.1 only (`ss`);
- destroy removing the record and profile.

An honest sequencing note: assertions that read the index page's JavaScript state (`window.apiBoot`, console boot marker, network log) run before the submit click, because the navigation replaces that document; every required check is retained, none weakened.

## Live two-worker isolation

Same run, passed:

- two concurrent leases held separate Chrome pid, CDP port, profile directory, and axi session;
- no tab crossover (each worker's `pages` listing omits the other's URL) and no storage crossover (a `localStorage` key written by worker-a reads as `null` in worker-b);
- destroying worker-a left worker-b running and operational, then worker-b destroyed cleanly, with zero leftover lease records or profiles.

## Surplus model evaluation for the browser roles

Protocol: each candidate ran the full live acceptance including a real pi-driven browser task (`FM_BROWSER_LIVE_E2E_PI=1`, one bounded attempt per candidate per supervisor instruction), then a task-only timed run of the same fill/click/verify prompt with a recovery clause, on 2026-09-04:

| Model | Full acceptance | Task latency | List $/M in/out | Context |
|---|---|---|---|---|
| `surplus/deepseek-v4-flash` | pass | 19s | 0.0886 / 0.1772 | 1M |
| `surplus/qwen3.5-flash` | pass | 26s | 0.1 / 0.4 | 1M |
| `surplus/minimax-m2.1` | pass | 27s | 0.3 / 1.2 | 198K |
| `surplus/glm-5.2` | pass | 37s | 0.966 / 3.036 | 1M |

All four completed the task through the chrome-devtools-axi CLI on the first attempt, so selection leaned on the workload economics and tool-discipline evidence rather than a pass/fail split:

- `WEB_RESEARCH` = `surplus/deepseek-v4-flash`: fastest task completion, lowest price, 1M context for page-volume reading; acceptance quality was equal across candidates.
- `BROWSER_OPERATOR` = `surplus/glm-5.2`: the strongest sustained tool user (it also drives complete agentic coding sessions per `docs/verification/multi-model-crew.md`), which matters most for multi-step precise form flows; price is mid-tier.
- Alternates: `qwen3.5-flash` (WEB_RESEARCH), `minimax-m2.1` (BROWSER_OPERATOR), both acceptance-passed here and previously smoke-verified for tool calls.
- The top-level codex fallback block is untouched, and `scripts/model-router-refresh refresh` against the live catalog on 2026-09-04 retained all seven assignments (`catalog: verified`).

## Honest limitations

- Selection is one bounded attempt per candidate per the supervisor's instruction, not a repeated-trial benchmark; latency numbers are single-run wall-clock and include model thinking time.
- The pinned ShellCheck lint (`bin/fm-lint.sh`) could not run here (ShellCheck and actionlint are not installed on this host); every changed shell file passed `bash -n`, and the pinned CI lint is the outstanding gate.
- Chrome's `--window-size=390,844` launch flag does not by itself pin the observed viewport (one fresh session reported 500x757 until an explicit `chrome-devtools-axi resize 390 844`); the acceptance therefore pins the viewport with resize before asserting it.
- A wedged CDP target (`Network.enable` timeout, `Bridge ... CDP target appears to have gone away`) was observed only when an ad-hoc smoke reused a profile directory after an unclean Chrome kill; per-lease fresh profiles never reproduced it, and the full acceptance runs clean.
- chrome-devtools-axi named sessions keep a bridge process alive after the CLI exits; lease destroy stops the named session best-effort, but an orphaned bridge from a manually killed run must be resolved by hand.
- Persistent authenticated profiles are design only (see `docs/browser-runtime.md`); nothing in this run verifies credential persistence.

Re-run `tests/fm-browser.test.sh`, `tests/model-router.test.sh`, and the seam case in `tests/fm-spawn-dispatch-profile.test.sh` after any lease-contract change, and re-establish the model table whenever the Surplus provider extension, pi, or Chrome version changes materially.
