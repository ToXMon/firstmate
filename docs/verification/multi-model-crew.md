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
