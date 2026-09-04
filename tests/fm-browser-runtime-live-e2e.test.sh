#!/usr/bin/env bash
# Opt-in live dedicated-Chrome runtime acceptance for bin/fm-browser.sh.
# Exercises the real dedicated Chrome binary, real chrome-devtools-axi named
# sessions, and a disposable loopback fixture site: the full one-worker
# acceptance surface (navigation, snapshot, click, fill, submit, DOM/state,
# console, network, screenshot, exact 390x844 viewport), two-worker
# isolation (separate pid/profile/CDP port/axi session, no tab or storage
# crossover, independent cleanup), and - only when additionally opted in -
# a real pi-driven browser task on the current Surplus assignment.
set -u

if [ "${FM_BROWSER_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_BROWSER_LIVE_E2E=1 to run the dedicated-Chrome runtime acceptance"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
unset NO_MISTAKES_GATE

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}
pass() {
  printf 'ok - %s\n' "$1"
}

BROWSER="$ROOT/bin/fm-browser.sh"
CHROME_BIN="${FM_BROWSER_CHROME_BIN:-/home/opadmin/.local/chrome/opt/google/chrome/chrome}"
AXI="chrome-devtools-axi"
command -v "$AXI" >/dev/null 2>&1 || fail "chrome-devtools-axi not found"
command -v python3 >/dev/null 2>&1 || fail "python3 not found"
command -v jq >/dev/null 2>&1 || fail "jq not found"
command -v curl >/dev/null 2>&1 || fail "curl not found"
[ -x "$CHROME_BIN" ] || fail "dedicated Chrome not executable: $CHROME_BIN"

LAB="$ROOT/.browser-live-e2e.$$"
HOME_DIR="$LAB/home"
WWW="$LAB/www"
mkdir -p "$HOME_DIR" "$WWW"
cleanup() {
  FM_HOME="$HOME_DIR" FM_BROWSER_AXI_BIN=/nonexistent-axi "$BROWSER" destroy w1 >/dev/null 2>&1 || true
  FM_HOME="$HOME_DIR" FM_BROWSER_AXI_BIN=/nonexistent-axi "$BROWSER" destroy worker-a >/dev/null 2>&1 || true
  FM_HOME="$HOME_DIR" FM_BROWSER_AXI_BIN=/nonexistent-axi "$BROWSER" destroy worker-b >/dev/null 2>&1 || true
  [ -n "${SERVE_PID:-}" ] && kill "$SERVE_PID" 2>/dev/null || true
  rm -rf "$LAB"
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

# --- disposable loopback fixture site ----------------------------------------

cat > "$WWW/index.html" <<'EOF'
<!doctype html><html><head><meta charset="utf-8"><title>lease-fixture</title></head><body>
<h1 id="hdr">ready</h1>
<form id="f" action="thanks.html" method="get">
<input id="q" name="q" placeholder="query">
<button id="go" type="submit">go</button>
</form>
<script>
console.log('boot-marker-fixture');
localStorage.setItem('visited', 'yes');
fetch('api.json').then(r => r.json()).then(d => { window.apiBoot = d.ok; });
</script>
</body></html>
EOF
cat > "$WWW/thanks.html" <<'EOF'
<!doctype html><html><head><meta charset="utf-8"><title>thanks-fixture</title></head><body>
<h1 id="out">submitted:</h1>
<script>
const q = new URLSearchParams(location.search).get('q') || 'none';
document.getElementById('out').textContent = 'submitted:' + q;
localStorage.setItem('submitted', q);
console.log('submit-marker-' + q);
</script>
</body></html>
EOF
cat > "$WWW/api.json" <<'EOF'
{"ok": true}
EOF

SERVE_PORT=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')
python3 -m http.server "$SERVE_PORT" --bind 127.0.0.1 --directory "$WWW" >/dev/null 2>&1 &
SERVE_PID=$!
sleep 1
BASE_URL="http://127.0.0.1:$SERVE_PORT"

axi() { # <owner> <args...> - one axi call against one lease's browser
  local owner=$1; shift
  local port session
  port=$(FM_HOME="$HOME_DIR" "$BROWSER" status "$owner" --json | jq -r .cdp_port)
  session=$(FM_HOME="$HOME_DIR" "$BROWSER" status "$owner" --json | jq -r .axi_session)
  CHROME_DEVTOOLS_AXI_BROWSER_URL="http://127.0.0.1:$port" \
    CHROME_DEVTOOLS_AXI_SESSION="$session" \
    timeout 120 "$AXI" "$@" 2>&1
}

png_size() { # <file> -> prints "W H"
  python3 - "$1" <<'PY'
import struct, sys
with open(sys.argv[1], 'rb') as f:
    head = f.read(26)
if head[12:16] != b'IHDR':
    print('not-png'); raise SystemExit
w, h = struct.unpack('>II', head[16:24])
print(w, h)
PY
}

# --- part 1: one-worker full fixture acceptance ---------------------------------

FM_HOME="$HOME_DIR" "$BROWSER" lease w1 >/dev/null || fail "could not lease w1"

axi w1 open "$BASE_URL/index.html" | grep -q 'title: lease-fixture' || fail "navigation did not open the fixture page"

snapshot=$(axi w1 snapshot)
textbox_uid=$(printf '%s\n' "$snapshot" | grep -o 'uid=[^ ]* textbox' | head -1 | sed 's/^uid=//; s/ .*//')
button_uid=$(printf '%s\n' "$snapshot" | grep -o 'uid=[^ ]* button "go"' | head -1 | sed 's/^uid=//; s/ .*//')
[ -n "$textbox_uid" ] || fail "snapshot exposed no textbox ref"
[ -n "$button_uid" ] || fail "snapshot exposed no button ref"
pass "navigation and snapshot expose interactive refs"

axi w1 fill "@$textbox_uid" "lease-acceptance" >/dev/null || fail "fill did not run"
axi w1 eval "() => document.getElementById('q').value" | grep -q 'lease-acceptance' \
  || fail "fill did not land in the textbox"
axi w1 eval "() => localStorage.getItem('visited')" | grep -q 'yes' \
  || fail "fixture page state (localStorage) missing on the index page"
sleep 1
axi w1 eval "() => window.apiBoot" | grep -q true || fail "fixture api fetch did not land"
axi w1 console | grep -q 'boot-marker-fixture' || fail "console log not captured"
axi w1 network | grep -q 'api.json' || fail "network log does not show the fetch"
pass "fill, page state, console, network, and api fetch verified on the index page"
# Refs are page-state scoped, so re-read the snapshot after the fill before
# clicking; the pre-fill button ref may already be stale.
snapshot=$(axi w1 snapshot)
button_uid=$(printf '%s\n' "$snapshot" | grep -o 'uid=[^ ]* button "go"' | head -1 | sed 's/^uid=//; s/ .*//')
[ -n "$button_uid" ] || fail "post-fill snapshot exposed no button ref"
axi w1 click "@$button_uid" >/dev/null || fail "click on submit did not run"
sleep 1
axi w1 eval "() => document.getElementById('out') && document.getElementById('out').textContent" \
  | grep -q 'submitted:lease-acceptance' || fail "submit did not reach the thanks page with the filled value"
axi w1 eval "() => localStorage.getItem('submitted')" | grep -q 'lease-acceptance' \
  || fail "page state (localStorage) lost the submitted value"
axi w1 console | grep -q 'submit-marker-lease-acceptance' || fail "submit console marker not captured"
pass "click and submit verified through DOM state, storage, and console"

axi w1 resize 390 844 >/dev/null || fail "resize to the acceptance viewport did not run"
viewport=$(axi w1 eval "() => innerWidth + 'x' + innerHeight" | grep -oE '[0-9]+x[0-9]+' | head -1)
[ "$viewport" = "390x844" ] || fail "viewport is $viewport, not the exact 390x844"
shot="$LAB/shot-w1.png"
axi w1 screenshot "$shot" | grep -q 'screenshot:' || fail "screenshot did not run"
size=$(png_size "$shot")
[ "$size" = "390 844" ] || fail "screenshot is ${size}px, not 390x844"
pass "exact 390x844 viewport and screenshot dimensions"

w1_port=$(FM_HOME="$HOME_DIR" "$BROWSER" status w1 --json | jq -r .cdp_port)
if command -v ss >/dev/null 2>&1; then
  ss -tln | grep ":$w1_port " | grep -q '127.0.0.1:' || fail "CDP port $w1_port is not loopback-bound"
  pass "CDP endpoint binds to 127.0.0.1 only"
else
  echo "note: ss not found; loopback binding left to the listener default"
fi

FM_HOME="$HOME_DIR" "$BROWSER" destroy w1 | grep -q '^destroyed w1' || fail "destroy w1 failed"
[ -f "$HOME_DIR/state/browser-leases/w1.json" ] && fail "w1 lease record survived destroy"
pass "one-worker acceptance complete and lease cleaned up"

# --- part 2: two-worker isolation ----------------------------------------------

FM_HOME="$HOME_DIR" "$BROWSER" lease worker-a >/dev/null || fail "could not lease worker-a"
FM_HOME="$HOME_DIR" "$BROWSER" lease worker-b >/dev/null || fail "could not lease worker-b"

ra=$(FM_HOME="$HOME_DIR" "$BROWSER" status worker-a --json)
rb=$(FM_HOME="$HOME_DIR" "$BROWSER" status worker-b --json)
[ "$(jq -r .pid <<<"$ra")" != "$(jq -r .pid <<<"$rb")" ] || fail "workers share a Chrome pid"
[ "$(jq -r .cdp_port <<<"$ra")" != "$(jq -r .cdp_port <<<"$rb")" ] || fail "workers share a CDP port"
[ "$(jq -r .profile_path <<<"$ra")" != "$(jq -r .profile_path <<<"$rb")" ] || fail "workers share a profile"
[ "$(jq -r .axi_session <<<"$ra")" != "$(jq -r .axi_session <<<"$rb")" ] || fail "workers share an axi session"
pass "two workers hold separate pid, CDP port, profile, and axi session"

axi worker-a open "$BASE_URL/index.html?q=aaa" >/dev/null || fail "worker-a could not open its page"
axi worker-b open "$BASE_URL/thanks.html?q=bbb" >/dev/null || fail "worker-b could not open its page"

axi worker-a eval "() => localStorage.setItem('cross', 'from-a')" >/dev/null || fail "worker-a storage write failed"
sleep 1
axi worker-b eval "() => localStorage.getItem('cross')" | grep -q 'result: "null"' \
  || fail "worker-b sees worker-a's storage: profiles are not isolated"
axi worker-a pages | grep -q 'q=bbb' && fail "worker-a sees worker-b's tab"
axi worker-b pages | grep -q 'index.html?q=aaa' && fail "worker-b sees worker-a's tab"
pass "no tab or storage crossover between workers"

FM_HOME="$HOME_DIR" "$BROWSER" destroy worker-a | grep -q '^destroyed worker-a' || fail "destroy worker-a failed"
axi worker-b eval "() => localStorage.getItem('visited') === null ? 'still-alive' : document.title" >/dev/null \
  || fail "worker-b stopped working after worker-a was destroyed"
FM_HOME="$HOME_DIR" "$BROWSER" status worker-b | grep -q '^worker-b: running' \
  || fail "worker-b lease is not running after worker-a cleanup"
pass "independent cleanup: destroying one worker leaves the other fully working"

FM_HOME="$HOME_DIR" "$BROWSER" destroy worker-b | grep -q '^destroyed worker-b' || fail "destroy worker-b failed"
[ -z "$(ls "$HOME_DIR/state/browser-leases/" 2>/dev/null)" ] || fail "lease records survived both destroys"
[ -z "$(ls "$HOME_DIR/state/browser-profiles/" 2>/dev/null)" ] || fail "profiles survived both destroys"
pass "two-worker isolation acceptance complete with clean teardown"

# --- part 3: real pi-driven browser task (extra opt-in) ---------------------------

if [ "${FM_BROWSER_LIVE_E2E_PI:-0}" = 1 ]; then
  command -v pi >/dev/null 2>&1 || fail "pi not found for the model-driven section"
  model="${FM_BROWSER_LIVE_E2E_MODEL:?set FM_BROWSER_LIVE_E2E_MODEL, e.g. surplus/glm-5.2}"
  FM_HOME="$HOME_DIR" "$BROWSER" lease model-worker >/dev/null || fail "could not lease model-worker"
  port=$(FM_HOME="$HOME_DIR" "$BROWSER" status model-worker --json | jq -r .cdp_port)
  session=$(FM_HOME="$HOME_DIR" "$BROWSER" status model-worker --json | jq -r .axi_session)
  prompt="You have a dedicated browser through the chrome-devtools-axi CLI (already on PATH). \
Your browser is selected by the exported CHROME_DEVTOOLS_AXI_BROWSER_URL and CHROME_DEVTOOLS_AXI_SESSION environment variables; do not change them and never pass a --port. \
Use bash to run: chrome-devtools-axi open '$BASE_URL/index.html', then snapshot, fill the textbox with modeltask, click the go button, then eval that the heading reads submitted:modeltask. \
When every step has really succeeded, reply with exactly: BROWSER-TASK-PASS"
  # The nested pi must never adopt the invoking project's pi state: a cwd
  # with a live session makes pi submit into that session ("Agent is already
  # processing" while it streams), and a cwd with project-local .pi/extensions
  # loads them into the probe (firstmate's fm-calm emits a stale-ctx error on
  # ephemeral nested sessions). Running from this scratch lab dir with its own
  # session dir isolates the probe without disabling any pi or axi behavior;
  # the model, its tools, and the lease env are all still fully real.
  answer=$(cd "$LAB" && CHROME_DEVTOOLS_AXI_BROWSER_URL="http://127.0.0.1:$port" \
    CHROME_DEVTOOLS_AXI_SESSION="$session" \
    timeout 420 pi --model "$model" --no-session --session-dir "$LAB/pi-sessions" -p "$prompt" 2>&1)
  printf '%s\n' "$answer" | grep -q 'BROWSER-TASK-PASS' \
    || fail "model $model did not complete the browser task: $(printf '%s' "$answer" | tail -5)"
  FM_HOME="$HOME_DIR" "$BROWSER" destroy model-worker >/dev/null || fail "destroy model-worker failed"
  pass "real pi-driven browser task completed by $model"
else
  echo "note: set FM_BROWSER_LIVE_E2E_PI=1 and FM_BROWSER_LIVE_E2E_MODEL=<model> to also exercise a model-driven task"
fi

echo "# fm-browser-runtime-live-e2e acceptance passed"
