# Mission Control Kun advisor verification

This record supports the optional Mission Control Kun advisor seam in `bin/fm-mission-kun-advisor.sh` and the operator guide in [`docs/mission-control/kun-advisor.md`](../mission-control/kun-advisor.md).
It records active evidence for global skill installation, Pi discovery, upstream-file loading without vendoring, tool classification, and the bounded acceptance run.

## Global install and Pi discovery

Date: 2026-09-09.
Host: Ubuntu 24.04 class worker with Pi installed at `/home/opadmin/.nvm/versions/node/v22.22.3/bin/pi`.

Command:

```sh
npx skills add kunchenguid/kun -g
```

Observed result:

```text
Source: https://github.com/kunchenguid/kun.git
Found 1 skill
Skill: kun
Installing to: Claude Code, Codex, Devin for Terminal, GitHub Copilot, OpenCode, Pi, Windsurf, AdaL
Installation complete
Installed 1 skill
✓ ~/.agents/skills/kun
symlinked: Claude Code, Devin for Terminal, Pi, Windsurf, AdaL
Failed to install 1
✗ kun -> PromptScript: PromptScript does not support global skill installation
```

The PromptScript line is not a Pi failure.
Pi discovery was observed through the installed global symlink:

```sh
ls -la /home/opadmin/.pi/agent/skills/kun /home/opadmin/.pi/agent/skills/kun/SKILL.md /home/opadmin/.agents/skills/kun/SKILL.md
```

Observed result:

```text
/home/opadmin/.pi/agent/skills/kun -> ../../../.agents/skills/kun
/home/opadmin/.pi/agent/skills/kun/SKILL.md
/home/opadmin/.agents/skills/kun/SKILL.md
```

The live Pi session that produced this change also listed `kun` as an available skill with location `/home/opadmin/.pi/agent/skills/kun/SKILL.md`.

## Upstream Kun files

Date: 2026-09-09.
Repository: `kunchenguid/kun`.
Observed main commit:

```sh
gh-axi api repos/kunchenguid/kun/commits/main --jq .sha
```

Observed result:

```text
api_response:
  body: b56400136812801c94f36202013dc8c9717ba630
  truncated: false
```

Observed blob SHAs:

```text
ENTRY.md c4f6823b96fa71af890a768cb4e642b8757e73f8
TOOLS.md 2897240acb15432cdfd38cca8d2cfe7ba94747fe
OPINIONS.md b6dbc1f05798b6ca1425f6ba35f1df17a8ccb6d2
VOICE.md 1fc0dddc91753945f2e07d74aa01653985d4b92f
```

The files were fetched from the raw upstream URLs and fully read during the verification pass.
Observed byte counts and SHA-256 hashes:

```text
ENTRY.md 6316 bytes sha256=1da92b15ea0969669b08a95307a7eaf037500816460d12b7db17dbdac3eaca5b
TOOLS.md 14230 bytes sha256=ea448029f832b15071992d2e910a09f87b122a271f9c767c9d3ccae3706a4145
OPINIONS.md 70553 bytes sha256=8a1ee3e2284fc3af2ec48e669193eef7e21cbdccdc8899dbd3885eff321bdd8b
VOICE.md 20450 bytes sha256=84baff38548ccd1399b91231b4f923543c802b33bda63d5ddbd4dfa5545186ee
```

No copy of those files is committed in Firstmate.
The committed helper records only the upstream repository, install command, and living file names.

## Tool classification evidence

Date: 2026-09-09.
Command:

```sh
for c in lavish-axi no-mistakes gh-axi chrome-devtools-axi vision gnhf backpass quota-axi; do printf '%s: ' "$c"; command -v "$c" || true; done
```

Observed result:

```text
lavish-axi: /home/opadmin/.nvm/versions/node/v22.22.3/bin/lavish-axi
no-mistakes: /home/opadmin/.local/bin/no-mistakes
gh-axi: /home/opadmin/.nvm/versions/node/v22.22.3/bin/gh-axi
chrome-devtools-axi: /home/opadmin/.nvm/versions/node/v22.22.3/bin/chrome-devtools-axi
vision:
gnhf:
backpass:
quota-axi: /home/opadmin/.nvm/versions/node/v22.22.3/bin/quota-axi
```

Mission Control therefore classifies `lavish-axi`, `no-mistakes`, `gh-axi`, `chrome-devtools-axi`, and `quota-axi` as CURRENT.
It classifies `vision` as RECOMMENDED NEXT because the future bounty flow needs acceptance-principle extraction.
It classifies `gnhf` and `backpass` as LATER because the Kun advisor seam does not require an overnight loop or transcript-trained memory updates.
No recommended-next or later tool was installed by this task.

## Bounded acceptance

SeedForge proposal used for the bounded acceptance: "Build a bounty-mission intake that turns a repository issue or bounty URL into a small worker DAG, proves the submission path, and leaves a human-approved package."
SeedForge's role was treated as proposal and prize/demo strategy only.

Kun engineering critique, using the upstream `/kun` knowledge loaded above:

1. The proposal needs a typed acceptance artifact before worker dispatch, otherwise the mission can produce code that looks useful but cannot be judged against bounty requirements.
2. The design should keep the advisor checkpoint optional and recorded, because turning Kun into every worker would blur ownership and waste context.
3. The implementation should preserve fresh independent validation through Critic and real UI validation through Browser Operator rather than treating a senior-engineering critique as proof.
4. The ledger should record `mission_id`, repository, commit SHA when available, timestamp, and checkpoint stage so a future bounty package can explain which engineering advice was accepted.

Accepted engineering improvements incorporated in this branch:

- Added `bin/fm-mission-kun-advisor.sh` to record the bounded advisor checkpoint provenance as JSONL.
- Limited valid stages to `after-idea-selection`, `after-architecture`, `after-material-tradeoffs`, and `before-final-qa`.
- Documented that Kun is a principal-engineer advisor, SeedForge keeps competitive strategy, Greg/Web3 keeps implementation expertise, Critic keeps adversarial verification, and Browser Operator keeps real UI validation.
- Documented the future bounty flow from bounty URL through human submission approval.

Mission continuation criterion: after those improvements, the worker DAG and validation path remain unchanged except for the optional recorded Kun checkpoint.
The acceptance test for the helper verifies that the mission can continue with a recorded checkpoint and does not allow `prize-strategy` as a Kun advisor stage.
