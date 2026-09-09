#!/usr/bin/env bash
# fm-mission-kun-advisor.sh - record Mission Control /kun engineering-advisor checkpoints.
#
# Usage:
#   fm-mission-kun-advisor.sh checkpoint --mission-id ID --stage STAGE --repository PATH_OR_URL [--commit-sha SHA] [--ledger PATH] [--summary TEXT] [--accepted TEXT]
#   fm-mission-kun-advisor.sh stages
#
# The checkpoint command appends one JSONL provenance record for an optional
# PRINCIPAL_ENGINEER_ADVISOR review performed through the globally installed
# /kun skill. It records the mission id, checkpoint stage, repository, commit
# SHA when available, timestamp, advisor source, and accepted engineering
# improvements without invoking /kun or vendoring Kun's living upstream files.
# Default ledger path is $FM_DATA_OVERRIDE/mission-control/kun-advisor-ledger.jsonl,
# or $FM_HOME/data/mission-control/kun-advisor-ledger.jsonl, or this repo's
# data/mission-control/kun-advisor-ledger.jsonl when no home override exists.
#
# Valid stages:
#   after-idea-selection
#   after-architecture
#   after-material-tradeoffs
#   before-final-qa
#
# This helper is deliberately a ledger seam only. Mission Control still uses
# SeedForge for competitive/prize/demo strategy, Greg/Web3 for implementation
# expertise, CRITIC for adversarial verification, and BROWSER_OPERATOR for real
# UI validation.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ROLE="PRINCIPAL_ENGINEER_ADVISOR"
KUN_REPO="https://github.com/kunchenguid/kun"
KUN_INSTALL="npx skills add kunchenguid/kun -g"
STAGES="after-idea-selection after-architecture after-material-tradeoffs before-final-qa"

usage() {
  sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'
}

default_ledger() {
  local data_root
  if [ -n "${FM_DATA_OVERRIDE:-}" ]; then
    data_root=$FM_DATA_OVERRIDE
  else
    data_root="${FM_HOME:-$ROOT}/data"
  fi
  printf '%s/mission-control/kun-advisor-ledger.jsonl\n' "$data_root"
}

is_stage() {
  local needle=$1 stage
  for stage in $STAGES; do
    [ "$needle" = "$stage" ] && return 0
  done
  return 1
}

detect_commit_sha() {
  local repository=$1
  [ -d "$repository" ] || return 0
  git -C "$repository" rev-parse --verify HEAD 2>/dev/null || true
}

json_null_or_string_arg() {
  local value=$1
  if [ -n "$value" ]; then
    jq -n --arg v "$value" '$v'
  else
    printf 'null\n'
  fi
}

cmd_stages() {
  printf '%s\n' after-idea-selection after-architecture after-material-tradeoffs before-final-qa
}

cmd_checkpoint() {
  local mission_id stage repository commit_sha ledger summary accepted timestamp record
  mission_id=
  stage=
  repository=
  commit_sha=
  summary=
  accepted=
  ledger=$(default_ledger)
  while [ $# -gt 0 ]; do
    case "$1" in
      --mission-id)
        mission_id=${2:-}
        shift
        ;;
      --stage)
        stage=${2:-}
        shift
        ;;
      --repository)
        repository=${2:-}
        shift
        ;;
      --commit-sha)
        commit_sha=${2:-}
        shift
        ;;
      --ledger)
        ledger=${2:-}
        shift
        ;;
      --summary)
        summary=${2:-}
        shift
        ;;
      --accepted)
        accepted=${2:-}
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        echo "fm-mission-kun-advisor.sh: unknown argument: $1" >&2
        exit 1
        ;;
    esac
    shift
  done

  [ -n "$mission_id" ] || { echo "fm-mission-kun-advisor.sh: --mission-id is required" >&2; exit 1; }
  [ -n "$stage" ] || { echo "fm-mission-kun-advisor.sh: --stage is required" >&2; exit 1; }
  [ -n "$repository" ] || { echo "fm-mission-kun-advisor.sh: --repository is required" >&2; exit 1; }
  [ -n "$ledger" ] || { echo "fm-mission-kun-advisor.sh: --ledger resolved empty" >&2; exit 1; }
  is_stage "$stage" || { echo "fm-mission-kun-advisor.sh: invalid stage '$stage'; run stages for allowed values" >&2; exit 1; }
  if [ -z "$commit_sha" ]; then
    commit_sha=$(detect_commit_sha "$repository")
  fi
  timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  record=$(jq -cn \
    --arg mission_id "$mission_id" \
    --arg checkpoint "$stage" \
    --arg timestamp "$timestamp" \
    --arg role "$ROLE" \
    --arg kun_repo "$KUN_REPO" \
    --arg kun_install "$KUN_INSTALL" \
    --arg repository "$repository" \
    --argjson commit_sha "$(json_null_or_string_arg "$commit_sha")" \
    --argjson summary "$(json_null_or_string_arg "$summary")" \
    --argjson accepted "$(json_null_or_string_arg "$accepted")" \
    '{schema:"firstmate.mission_control.kun_advisor_checkpoint.v1", mission_id:$mission_id, checkpoint:$checkpoint, timestamp:$timestamp, advisor_role:$role, advisor_skill:{repository:$kun_repo, install:$kun_install, live_files:["ENTRY.md","TOOLS.md","OPINIONS.md","VOICE.md"]}, repository:$repository, commit_sha:$commit_sha, summary:$summary, accepted_engineering_improvements:$accepted}')

  mkdir -p "$(dirname "$ledger")"
  printf '%s\n' "$record" >> "$ledger"
  printf 'recorded %s %s for mission_id=%s in %s\n' "$ROLE" "$stage" "$mission_id" "$ledger"
  printf 'next: invoke /kun for engineering critique only; keep SeedForge on prize strategy and use CRITIC/BROWSER_OPERATOR for validation.\n'
}

case "${1:-}" in
  checkpoint)
    shift
    cmd_checkpoint "$@"
    ;;
  stages)
    cmd_stages
    ;;
  -h|--help|'')
    usage
    ;;
  *)
    echo "fm-mission-kun-advisor.sh: unknown command: $1" >&2
    usage >&2
    exit 1
    ;;
esac
