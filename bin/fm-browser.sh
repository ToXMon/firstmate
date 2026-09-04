#!/usr/bin/env bash
# fm-browser.sh - dedicated-Chrome browser lease lifecycle for autonomous workers.
#
# Every lease launches its OWN headless Chrome from the dedicated automation
# binary (never the operator's shared Chrome at 127.0.0.1:9222), bound to
# 127.0.0.1 on a dynamically allocated port, with a single-use profile
# directory and a unique chrome-devtools-axi named session. Workers reach
# their browser only through the exported CHROME_DEVTOOLS_AXI_BROWSER_URL /
# CHROME_DEVTOOLS_AXI_SESSION pair, so no worker can ever see another
# worker's tabs, storage, or session state.
#
# Usage:
#   fm-browser.sh lease <owner-id> [--home PATH] [--window WxH]
#   fm-browser.sh status [<owner-id>] [--home PATH] [--json]
#   fm-browser.sh env <owner-id> [--home PATH]
#   fm-browser.sh destroy <owner-id> [--home PATH]
#
# lease starts a dedicated Chrome for <owner-id> (normally a Firstmate task
# id, any [A-Za-z0-9._-]+ name works for ad-hoc use) and records the lease.
# The lease record and profiles live under the target home's state/
# directory: state/browser-leases/<owner>.json and
# state/browser-profiles/<owner>-<epoch>-<token>. The home is --home or
# $FM_HOME (fail-closed: one must be explicit, like bin/fm-send.sh);
# FM_STATE_OVERRIDE relocates state/ exactly as fm-send allows.
#
# status prints one line per lease: owner, health, pid, port, profile, axi
# session. --json prints the full records with live health merged. Without
# an owner id it lists every recorded lease, so orphaned browsers are
# discoverable (a lease whose Chrome died without destroy shows dead).
# Health values: running (pid, identity, and CDP endpoint all verified),
# unresponsive (identity verified but CDP endpoint not answering), dead
# (process gone), foreign (pid alive but no longer provably this lease's
# Chrome; destroy refuses to signal it).
#
# env prints `export CHROME_DEVTOOLS_AXI_BROWSER_URL=...` and
# `export CHROME_DEVTOOLS_AXI_SESSION=...` lines for one running lease; this
# is the integration point dispatchers use (bin/fm-spawn.sh ships these
# lines into a worker pane before launch when a lease exists for the task).
#
# destroy verifies ownership before signaling anything: the recorded pid
# must still exist, its process start time must still match the recorded one
# (defeats pid recycling), and its command line must still contain the exact
# lease-only --user-data-dir and --remote-debugging-port arguments. A
# mismatch is refused loudly with evidence and nothing is signaled; that
# guard is what makes the legacy shared Chrome at :9222 unreachable from
# here, together with the allocator refusing the 9222/9224 ports outright.
# A verified kill is TERM, then KILL after a grace period; the axi named
# session is stopped best-effort, and the profile directory and lease record
# are removed only after the process is gone.
#
# Environment overrides (tests and air-gapped hosts):
#   FM_BROWSER_CHROME_BIN   dedicated Chrome binary (default
#                           /home/opadmin/.local/chrome/opt/google/chrome/chrome)
#   FM_BROWSER_AXI_BIN      chrome-devtools-axi binary (default from PATH);
#                           set to a nonexistent path to skip bridge cleanup
#   FM_BROWSER_START_TIMEOUT  readiness seconds (default 20)
#
# Exit codes: 0 success, 1 usage/verification failure or refused destroy,
# 2 unknown owner for status/env/destroy, 3 lease already exists.
set -euo pipefail

DEFAULT_CHROME_BIN="/home/opadmin/.local/chrome/opt/google/chrome/chrome"
# 9222: the operator's legacy shared Chrome; 9224: axi default bridge port.
FORBIDDEN_PORTS="9222 9224"

die() { echo "fm-browser: $*" >&2; exit 1; }
warn() { echo "fm-browser: warning: $*" >&2; }

# --- home / state resolution -------------------------------------------------

HOME_ARG=
STATE_OVERRIDE="${FM_STATE_OVERRIDE:-}"

resolve_state() {
  local home="${HOME_ARG:-${FM_HOME:-}}"
  [ -n "$home" ] || die "no home: pass --home PATH or set FM_HOME"
  [ -d "$home" ] || die "home directory not found: $home"
  if [ -n "$STATE_OVERRIDE" ]; then printf '%s' "$STATE_OVERRIDE"; else printf '%s/state' "$home"; fi
}

# Resolved once at entry: helpers below read the variable, never a nested
# substitution, so a fatal resolve_state inside $( ) can never be silently
# swallowed into an empty path that reads the filesystem root.
STATE_ROOT=

leases_dir() { printf '%s/browser-leases' "$STATE_ROOT"; }
profiles_dir() { printf '%s/browser-profiles' "$STATE_ROOT"; }
lease_path() { printf '%s/%s.json' "$(leases_dir)" "$1"; }

valid_owner() { case "$1" in ''|*[!A-Za-z0-9._-]*) return 1 ;; *) return 0 ;; esac; }

require_owner_arg() {
  [ -n "${OWNER_ARG:-}" ] || die "$1 requires an owner id"
  valid_owner "$OWNER_ARG" || die "owner id must match [A-Za-z0-9._-]+ (got: $OWNER_ARG)"
}

# --- process identity ---------------------------------------------------------

pid_alive() { kill -0 "$1" 2>/dev/null; }

# Process start time from /proc (Linux); empty where /proc cannot provide it.
pid_starttime() {
  local stat
  stat=$(cat "/proc/$1/stat" 2>/dev/null) || { printf ''; return 0; }
  # Field 22 sits after the parenthesized comm field; drop the first two.
  printf '%s' "$stat" | sed 's/.*) //' | awk '{print $20}'
}

# Full command line, NUL-separated args joined by spaces; empty when unreadable.
pid_cmdline() {
  if [ -r "/proc/$1/cmdline" ]; then
    tr '\0' ' ' < "/proc/$1/cmdline"
  else
    ps -p "$1" -o command= 2>/dev/null || printf ''
  fi
}

# True when the live pid provably still owns this lease's exact Chrome: the
# command line carries the lease-only user-data-dir and debugging port, and
# the process start time still matches where /proc provides one, so a
# recycled pid cannot pass even if an unrelated Chrome shares the arguments.
identity_matches() { # <record-json> <pid>
  local rec=$1 pid=$2 cmdline profile port recorded live
  profile=$(jq -r .profileDir <<<"$rec")
  port=$(jq -r .port <<<"$rec")
  cmdline=$(pid_cmdline "$pid")
  [ -n "$cmdline" ] || return 1
  case "$cmdline" in
    *"--user-data-dir=$profile"*) : ;;
    *) return 1 ;;
  esac
  case "$cmdline" in
    *"--remote-debugging-port=$port"*) : ;;
    *) return 1 ;;
  esac
  recorded=$(jq -r '.pidStart // ""' <<<"$rec")
  live=$(pid_starttime "$pid")
  if [ -n "$recorded" ] && [ -n "$live" ] && [ "$recorded" != "$live" ]; then
    return 1
  fi
  return 0
}

# --- port allocation ------------------------------------------------------------

port_in_use() { if (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; then return 0; fi; return 1; }

pick_port() {
  local port
  for _ in $(seq 1 25); do
    port=$(( (RANDOM % 20000) + 25000 ))
    case " $FORBIDDEN_PORTS " in *" $port "*) continue ;; esac
    if ! port_in_use "$port"; then printf '%s' "$port"; return 0; fi
  done
  return 1
}

endpoint_ready() { # <port>
  curl -s --max-time 2 -o /dev/null "http://127.0.0.1:$1/json/version" 2>/dev/null
}

# --- serialization ---------------------------------------------------------------

# Serialize mutating lease operations on one home with flock on fd 9.
open_and_lock() {
  mkdir -p "$(leases_dir)" "$(profiles_dir)"
  exec 9>"$STATE_ROOT/.browser-leases.lock"
  flock 9
}

# --- record helpers ----------------------------------------------------------------

read_record() {
  local p
  p=$(lease_path "$1")
  [ -f "$p" ] || return 1
  jq -e . "$p" >/dev/null 2>&1 || return 1
  cat "$p"
}

lease_health() { # <record> -> prints running|unresponsive|dead|foreign
  local rec=$1 pid port
  pid=$(jq -r .pid <<<"$rec")
  port=$(jq -r .port <<<"$rec")
  if ! pid_alive "$pid"; then printf 'dead'; return 0; fi
  if ! identity_matches "$rec" "$pid"; then printf 'foreign'; return 0; fi
  if ! endpoint_ready "$port"; then printf 'unresponsive'; return 0; fi
  printf 'running'
}

stop_axi_session_best_effort() { # <axi-session> <port>
  local axi=$1 port=$2 bin
  bin="${FM_BROWSER_AXI_BIN:-chrome-devtools-axi}"
  command -v "$bin" >/dev/null 2>&1 || return 0
  CHROME_DEVTOOLS_AXI_BROWSER_URL="http://127.0.0.1:$port" \
    CHROME_DEVTOOLS_AXI_SESSION="$axi" timeout 30 "$bin" stop >/dev/null 2>&1 || true
}

# --- subcommands ----------------------------------------------------------------------

cmd_lease() {
  require_owner_arg lease
  open_and_lock
  lease_locked
}

lease_locked() {
  local chrome_bin profile port pid rec start timeout_s waited attempt=0
  chrome_bin="${FM_BROWSER_CHROME_BIN:-$DEFAULT_CHROME_BIN}"
  [ -x "$chrome_bin" ] || die "dedicated Chrome binary not executable: $chrome_bin (override with FM_BROWSER_CHROME_BIN)"
  if [ -f "$(lease_path "$OWNER_ARG")" ]; then
    echo "fm-browser: lease already exists for $OWNER_ARG (destroy it first or choose another owner)" >&2
    exit 3
  fi
  case "${WINDOW_ARG:-390x844}" in
    [0-9]*x[0-9]*) : ;;
    *) die "--window expects WxH such as 390x844" ;;
  esac
  window_flag="${WINDOW_ARG:-390x844}"
  window_flag="${window_flag/x/,}"
  profile="$(profiles_dir)/$OWNER_ARG-$(date +%s)-$(head -c4 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  timeout_s="${FM_BROWSER_START_TIMEOUT:-20}"
  while :; do
    attempt=$((attempt + 1))
    port=$(pick_port) || die "no free port found after 25 probes"
    # 9>&- keeps the lease lock's fd out of the Chrome child: an inherited
    # open file description would hold the flock for the browser's lifetime.
    "$chrome_bin" --headless=new --no-sandbox \
      --user-data-dir="$profile" \
      --remote-debugging-port="$port" \
      --no-first-run --no-default-browser-check \
      --window-size="$window_flag" about:blank \
      >"$profile.log" 2>&1 9>&- &
    pid=$!
    waited=0
    while [ "$waited" -lt "$timeout_s" ]; do
      endpoint_ready "$port" && break
      if ! pid_alive "$pid"; then
        warn "chrome exited during startup (attempt $attempt); see $(profiles_dir)/lease-startup.log"
        { echo "--- attempt $attempt port $port"; tail -5 "$profile.log" 2>/dev/null; } >> "$(profiles_dir)/lease-startup.log"
        break
      fi
      sleep 1
      waited=$((waited + 1))
    done
    endpoint_ready "$port" && break
    kill "$pid" 2>/dev/null || true
    [ "$attempt" -ge 3 ] && die "dedicated Chrome never answered on its CDP port after $attempt attempts"
  done
  start=$(pid_starttime "$pid")
  rec=$(jq -n \
    --arg owner "$OWNER_ARG" --arg chromeBin "$chrome_bin" \
    --argjson pid "$pid" --arg pidStart "$start" --argjson port "$port" \
    --arg profileDir "$profile" --arg axiSession "fmb-$OWNER_ARG-$(date +%s)" \
    --arg window "$window_flag" --arg createdAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{schemaVersion: 1, owner: $owner, chromeBin: $chromeBin, pid: $pid,
      pidStart: (if $pidStart == "" then null else $pidStart end),
      port: $port, profileDir: $profileDir, axiSession: $axiSession,
      window: $window, createdAt: $createdAt}')
  printf '%s\n' "$rec" > "$(lease_path "$OWNER_ARG")"
  rm -f "$profile.log"
  echo "lease $OWNER_ARG: pid=$pid port=$port window=$window_flag axi=$(jq -r .axiSession <<<"$rec")"
  cmd_env
}

print_record_line() { # <record>
  local rec=$1
  printf '%s: %s pid=%s port=%s profile=%s axi=%s\n' \
    "$(jq -r .owner <<<"$rec")" "$(lease_health "$rec")" "$(jq -r .pid <<<"$rec")" \
    "$(jq -r .port <<<"$rec")" "$(jq -r .profileDir <<<"$rec")" "$(jq -r .axiSession <<<"$rec")"
}

cmd_status() {
  local dir rec found=0
  if [ -n "${OWNER_ARG:-}" ]; then
    require_owner_arg status
    rec=$(read_record "$OWNER_ARG") || { echo "fm-browser: no lease record for $OWNER_ARG" >&2; exit 2; }
    if [ "${JSON_OUT:-0}" = 1 ]; then
      jq --arg h "$(lease_health "$rec")" '. + {health: $h}' <<<"$rec"
    else
      print_record_line "$rec"
    fi
    return 0
  fi
  dir=$(leases_dir)
  [ -d "$dir" ] || { echo "no leases"; return 0; }
  if [ "${JSON_OUT:-0}" = 1 ]; then
    printf '['
    local first=1
    for f in "$dir"/*.json; do
      [ -f "$f" ] || continue
      rec=$(cat "$f"); found=1
      [ "$first" = 1 ] || printf ','
      first=0
      jq -c --arg h "$(lease_health "$rec")" '. + {health: $h}' <<<"$rec"
    done
    printf ']\n'
  else
    for f in "$dir"/*.json; do
      [ -f "$f" ] || continue
      rec=$(cat "$f"); found=1
      print_record_line "$rec"
    done
  fi
  [ "$found" = 1 ] || echo "no leases"
  return 0
}

cmd_env() {
  require_owner_arg env
  local rec health
  rec=$(read_record "$OWNER_ARG") || { echo "fm-browser: no lease record for $OWNER_ARG" >&2; exit 2; }
  health=$(lease_health "$rec")
  case "$health" in
    running) : ;;
    *)
      echo "fm-browser: lease $OWNER_ARG is $health; refusing to export its env (destroy and re-lease)" >&2
      exit 1
      ;;
  esac
  printf 'export CHROME_DEVTOOLS_AXI_BROWSER_URL=http://127.0.0.1:%s\n' "$(jq -r .port <<<"$rec")"
  printf 'export CHROME_DEVTOOLS_AXI_SESSION=%s\n' "$(jq -r .axiSession <<<"$rec")"
}

cmd_destroy() {
  require_owner_arg destroy
  open_and_lock
  destroy_locked
}

destroy_locked() {
  local rec pid port profile axi waited
  rec=$(read_record "$OWNER_ARG") || { echo "fm-browser: no lease record for $OWNER_ARG" >&2; exit 2; }
  pid=$(jq -r .pid <<<"$rec")
  port=$(jq -r .port <<<"$rec")
  profile=$(jq -r .profileDir <<<"$rec")
  axi=$(jq -r .axiSession <<<"$rec")
  if ! pid_alive "$pid"; then
    warn "chrome for $OWNER_ARG (pid $pid) already exited; cleaning records"
    stop_axi_session_best_effort "$axi" "$port"
    rm -rf "$profile" "$(lease_path "$OWNER_ARG")"
    echo "destroyed $OWNER_ARG (was already dead)"
    return 0
  fi
  if ! identity_matches "$rec" "$pid"; then
    echo "fm-browser: REFUSED destroy for $OWNER_ARG: pid $pid is alive but no longer matches the lease identity (pid recycling or a foreign Chrome); nothing was signaled" >&2
    echo "fm-browser: live cmdline: $(pid_cmdline "$pid")" >&2
    echo "fm-browser: expected --user-data-dir=$profile --remote-debugging-port=$port; resolve by hand, then remove $(lease_path "$OWNER_ARG")" >&2
    exit 1
  fi
  kill "$pid" 2>/dev/null || true
  waited=0
  while pid_alive "$pid" && [ "$waited" -lt 10 ]; do sleep 1; waited=$((waited + 1)); done
  if pid_alive "$pid"; then
    warn "chrome for $OWNER_ARG ignored TERM; sending KILL"
    kill -9 "$pid" 2>/dev/null || true
    waited=0
    while pid_alive "$pid" && [ "$waited" -lt 5 ]; do sleep 1; waited=$((waited + 1)); done
    if pid_alive "$pid"; then
      echo "fm-browser: REFUSED cleanup: pid $pid survived KILL; leaving record $(lease_path "$OWNER_ARG") for manual resolution" >&2
      exit 1
    fi
  fi
  stop_axi_session_best_effort "$axi" "$port"
  rm -rf "$profile" "$(lease_path "$OWNER_ARG")"
  echo "destroyed $OWNER_ARG (pid $pid port $port)"
}

# --- argument parsing -------------------------------------------------------------------

CMD=
OWNER_ARG=
WINDOW_ARG=
JSON_OUT=0

while [ $# -gt 0 ]; do
  case "$1" in
    lease|status|env|destroy) CMD=$1 ;;
    --home) HOME_ARG=${2:-}; [ -n "$HOME_ARG" ] || die "--home requires a path"; shift ;;
    --home=*) HOME_ARG=${1#--home=}; [ -n "$HOME_ARG" ] || die "--home requires a path" ;;
    --window) WINDOW_ARG=${2:-}; [ -n "$WINDOW_ARG" ] || die "--window requires WxH"; shift ;;
    --json) JSON_OUT=1 ;;
    -*) die "unknown option: $1" ;;
    *) OWNER_ARG=$1 ;;
  esac
  shift
done

[ -n "$CMD" ] || die "usage: fm-browser.sh lease|status|env|destroy <owner-id> [--home PATH]"

STATE_ROOT=$(resolve_state) || exit 1

case "$CMD" in
  lease) cmd_lease ;;
  status) cmd_status ;;
  env) cmd_env ;;
  destroy) cmd_destroy ;;
esac
