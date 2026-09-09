# Kun advisor in Mission Control

Mission Control uses Kun as an optional principal-engineer checkpoint, not as the whole crew.
The integration is deliberately small: install the public `/kun` skill globally, invoke it only at bounded engineering checkpoints, and record the provenance of any accepted engineering advice with `bin/fm-mission-kun-advisor.sh`.
Kun's living files stay in `kunchenguid/kun`; Firstmate records their source names and never vendors `ENTRY.md`, `TOOLS.md`, `OPINIONS.md`, or `VOICE.md`.

## Install and verify

Install the skill globally with:

```sh
npx skills add kunchenguid/kun -g
```

Pi discovers it through the normal global skill symlink at `~/.pi/agent/skills/kun`.
The installed `SKILL.md` is only a loader stub, and each `/kun` use fetches the current upstream files from `https://raw.githubusercontent.com/kunchenguid/kun/main/` with jsDelivr as the documented fallback.
That means the Mission Control repo keeps only the seam and provenance ledger, while the advisor knowledge remains upstream-owned.

Use `gh-axi api repos/kunchenguid/kun/commits/main --jq .sha` when you need to record the upstream commit observed during a verification pass.
Use the raw-file hashes in [`docs/verification/mission-control-kun-advisor.md`](../verification/mission-control-kun-advisor.md) as dated evidence only, not as vendored content.

## Role split

| Role | Owns | Must not own |
| --- | --- | --- |
| SeedForge | Competitive, prize, demo, and proposal strategy. | Engineering sign-off or code validation. |
| `PRINCIPAL_ENGINEER_ADVISOR` through `/kun` | Senior engineering critique after the idea is selected, after architecture, after material tradeoffs, and before final QA. | Prize strategy, every worker task, implementation ownership, or final validation. |
| Greg/Web3 | Implementation expertise for protocol, wallet, chain, and Web3 integration details. | Prize positioning or broad mission selection. |
| `CRITIC` | Fresh-context adversarial review and test-running skepticism. | Authoring the implementation it reviews. |
| `BROWSER_OPERATOR` | Real browser validation through `chrome-devtools-axi`. | Static review that should be handled by Critic or Kun. |

Kun is useful when the question is "what is the engineering trap here?" or "what would a strong principal engineer challenge before we commit?"
SeedForge remains the place for "what wins the hackathon?" and "what demo is most competitive?"
Critic and Browser Operator remain mandatory validation roles where their evidence is required.

## Checkpoints and ledger

The allowed Kun checkpoints are:

- `after-idea-selection` - SeedForge has selected the proposal, and Kun checks whether the engineering path is real enough to pursue.
- `after-architecture` - the planned system shape exists, and Kun challenges missing boundaries, tests, and failure modes.
- `after-material-tradeoffs` - major build-versus-buy, protocol, dependency, or UX tradeoffs are on the table, and Kun pushes for the simplest credible path.
- `before-final-qa` - implementation is nearing validation, and Kun looks for engineering gaps before Critic and Browser Operator perform their evidence work.

Record each checkpoint with:

```sh
bin/fm-mission-kun-advisor.sh checkpoint \
  --mission-id <mission_id> \
  --stage after-architecture \
  --repository <repo-path-or-url> \
  --summary "Kun's engineering critique" \
  --accepted "Accepted engineering improvements"
```

The helper appends one JSONL record under the active home's `data/mission-control/kun-advisor-ledger.jsonl` unless `--ledger` is supplied.
Each record includes the `mission_id`, checkpoint stage, UTC timestamp, repository, commit SHA when the repository is a git checkout or `--commit-sha` is supplied, advisor role, upstream Kun repository, install command, living file names, critique summary, and accepted engineering improvements.
The helper does not invoke `/kun`, install tools, or decide which advice to accept.

## Tool classification

| Tool | Classification | Mission Control use |
| --- | --- | --- |
| `lavish-axi` | CURRENT | Structured human review artifacts and visual decision boards. |
| `no-mistakes` | CURRENT | Independent validation for implementation branches before a PR or local landing path. |
| `gh-axi` | CURRENT | GitHub issue, PR, repository, workflow, and bounty research. |
| `chrome-devtools-axi` | CURRENT | Real browser operation and UI validation through Browser Operator. |
| `quota-axi` | CURRENT | Quota-aware worker routing and capacity checks before parallel work. |
| `vision` | RECOMMENDED NEXT | Acceptance-principle extraction before recurring bounty selection. |
| `gnhf` | LATER | Overnight autonomous loops only after the mission flow has a measurable objective and safe rollback. |
| `backpass` | LATER | Memory and instruction improvement after enough completed missions produce transcript evidence. |

Do not auto-install `vision`, `gnhf`, or `backpass` as part of the Kun advisor seam.
Install each only when its classification changes or a concrete mission needs it.

## Hackathon flow

1. SeedForge identifies a proposal and records why it can compete.
2. `/kun` runs the `after-idea-selection` advisor checkpoint and challenges engineering feasibility, failure modes, and testability.
3. Mission Control accepts only engineering improvements that make the proposal more buildable without changing SeedForge's prize strategy.
4. The first mate dispatches the worker DAG with Greg/Web3, Coder, Critic, and Browser Operator roles as needed.
5. Implementation workers build the accepted path.
6. Tests and real-browser checks prove the mission still works.
7. `no-mistakes` or the selected project validation path reviews the final branch.
8. The captain receives the PR, local branch, or demo package for approval.

## Future bounty flow

The future bounty path is:

```text
bounty URL -> gh-axi research -> vision acceptance principles -> /kun plan -> Firstmate worker DAG -> implementation -> tests -> no-mistakes validation -> PR/bounty package -> human submission approval
```

`gh-axi` gathers bounty facts from GitHub or linked repositories.
`vision` turns prior shipped history or bounty-owner signals into acceptance principles before work is proposed.
`/kun` then critiques the engineering plan against those principles, but it still does not choose the prize strategy or submit on the human's behalf.
Firstmate workers implement and validate, and the human approves the final bounty submission package.
