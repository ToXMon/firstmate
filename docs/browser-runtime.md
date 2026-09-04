# Dedicated-Chrome browser runtime

Autonomous browser work runs on a dedicated headless Chrome per task, never on the operator's shared Chrome at `127.0.0.1:9222`.
`bin/fm-browser.sh`'s header owns the lease contract, subcommands, environment overrides, and exit codes; this page is the operator reference for choosing and supervising browser work.

## Setup

The dedicated binary is `/home/opadmin/.local/chrome/opt/google/chrome/chrome` (override with `FM_BROWSER_CHROME_BIN`).
Browser operations go through `chrome-devtools-axi` on `PATH`.
Chrome launches headless with `--no-sandbox` because this host class (Ubuntu 24.04 with `apparmor_restrict_unprivileged_userns=1`) blocks Chrome's user-namespace sandbox and the user-local install has no setuid helper; the browser's exposure is bounded by its single-use profile and loopback-only CDP port.
The shared `:9222` Chrome stays legacy/manual/debug-only: the lease allocator refuses ports 9222 and 9224 outright, and destroy signals a process only after re-verifying the exact lease-only `--user-data-dir`, debugging port, and process start time recorded at lease time.

## Leases

```sh
bin/fm-browser.sh lease <task-id>        # start a dedicated Chrome for one worker
bin/fm-browser.sh status [<task-id>]     # health: running, unresponsive, dead, foreign
bin/fm-browser.sh env <task-id>          # export lines for dispatchers
bin/fm-browser.sh destroy <task-id>      # verified-ownership teardown
```

Every lease gets its own Chrome pid, single-use profile directory, dynamically allocated loopback CDP port, and unique `chrome-devtools-axi` named session, so two workers can never see each other's tabs or storage.
The home is `--home` or `$FM_HOME` (fail-closed, like `bin/fm-send.sh`); records live under `state/browser-leases/` and profiles under `state/browser-profiles/`.
Destroy refuses loudly rather than signaling any process it cannot prove is the leased Chrome; a refused destroy keeps the record as evidence.

## Dispatch

For a task routed to a browser role, create the lease before spawning the worker.
`bin/fm-spawn.sh` ships the lease's `CHROME_DEVTOOLS_AXI_BROWSER_URL` and `CHROME_DEVTOOLS_AXI_SESSION` exports into the worker pane before launch whenever a lease record exists for the task, and `bin/fm-teardown.sh` destroys the lease best-effort during task cleanup, so no firstmate-wide Chrome state or port pinning exists.
Never pass `CHROME_DEVTOOLS_AXI_PORT` for autonomous workers; the named session derives its own bridge port.

Browser-role routing is part of the semantic role router: `WEB_RESEARCH` and `BROWSER_OPERATOR` resolve like every other role through `scripts/model-router-refresh` against `config/model-roles.json`, with the shared codex fallback preserved.
The live acceptance, including two-worker isolation proof, is `tests/fm-browser-runtime-live-e2e.test.sh` (`FM_BROWSER_LIVE_E2E=1`), and its current evidence record is [`verification/browser-runtime.md`](verification/browser-runtime.md).

## Persistent authenticated profiles - design only

Authenticated browsing (a logged-in session surviving across tasks) is deliberately not implemented.
The designed shape, for a future decision: a named persistent profile directory per identity kept outside the disposable per-lease path, a lease flag opting a task into mounting it read-write, an explicit operator consent step before any credential-bearing profile is created or reused, and destroy semantics that never delete persistent profiles.
Until that design is implemented, every lease stays profile-disposable, and workers needing authenticated state re-authenticate per task.
