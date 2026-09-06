#!/usr/bin/env bash
# Opt-in live lifecycle gate for the dormant OMP candidate.
#
# The guard stages one real OMP process in a private tmux server through the
# candidate manifest, then drives interrupt, exit, and relaunch only through
# bin/fm-control.sh.
# The manifest's complete configuration environment is resolved and proven to
# stay inside scratch space before the first process starts.
# Set FM_OMP_LIFECYCLE_PREFLIGHT_ONLY=1 to exercise that proof and its deliberate
# negative control without launching OMP.
# Standard CI does not run installed harnesses, so this guard is opt-in.
set -u

if [ "${FM_OMP_LIFECYCLE_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_OMP_LIFECYCLE_LIVE_E2E=1 to run the real OMP lifecycle gate"
  exit 0
fi

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

OMP_MODEL=anthropic/claude-sonnet-4-5
OMP_BIN=$(command -v omp 2>/dev/null || true)
[ -n "$OMP_BIN" ] && [ -x "$OMP_BIN" ] \
  || fail "omp not found; this gate refuses to pass without the real candidate"
OMP_BIN_REAL=$(realpath "$OMP_BIN" 2>/dev/null || true)
[ -n "$OMP_BIN_REAL" ] && [ -x "$OMP_BIN_REAL" ] \
  || fail "the resolved OMP candidate is not executable"
OMP_PROVENANCE=$(dirname "$OMP_BIN_REAL")/PROVENANCE.json
[ -r "$OMP_PROVENANCE" ] \
  || fail "the resolved OMP candidate has no readable provenance record"
EXPECTED_OMP_SHA=$(PROVENANCE="$OMP_PROVENANCE" node -e '
const p = require(process.env.PROVENANCE);
if (p.release !== "v17.2.9" || p.reportedVersion !== "omp/17.2.9") process.exit(1);
process.stdout.write(p.sha256);
' 2>/dev/null) || fail "the OMP provenance record is not pinned to v17.2.9"
ACTUAL_OMP_SHA=$(shasum -a 256 "$OMP_BIN_REAL" | awk '{ print $1 }') \
  || fail "the OMP candidate digest could not be calculated"
[ "$ACTUAL_OMP_SHA" = "$EXPECTED_OMP_SHA" ] \
  || fail "the OMP candidate digest does not match its v17.2.9 provenance"
REAL_TMUX=$(command -v tmux 2>/dev/null || true)
[ -n "$REAL_TMUX" ] && [ -x "$REAL_TMUX" ] \
  || fail "tmux not found; the OMP lifecycle gate requires the verified backend"

LAB=$(mktemp -d "$ROOT/.fm-omp-lifecycle.XXXXXX") \
  || fail "could not create the OMP lifecycle scratch directory"
HOME_DIR="$LAB/home"
STATE="$HOME_DIR/state"
DATA="$HOME_DIR/data"
AGENT_DIR="$LAB/isolated-agent"
WORKTREE="$LAB/isolated-cwd"
SHIM_DIR="$LAB/bin"
SOCKET_PATH="$ROOT/.fm-omp-$$"
SESSION=fm-omp-lifecycle
ID=omp-lifecycle-live
TARGET="$SESSION:fm-$ID"
MANIFEST="$LAB/manifest.json"
NEGATIVE_MANIFEST="$LAB/manifest-negative.json"
BRIEF="$DATA/$ID/brief.md"
LAUNCHER="$LAB/launch-omp.sh"
CONTROL="$ROOT/bin/fm-control.sh"
BOUNDARY="$ROOT/bin/fm-omp-candidate-artifacts.sh"
CONSTRUCTED_ARGV="$LAB/constructed-argv.json"
PANE_TRANSCRIPT="$LAB/pane-transcript.txt"
MCP_RECORD="$LAB/mcp-source-status.txt"
OPEN_FILES="$LAB/process-open-files.txt"
PROCESS_ENVIRONMENT="$LAB/process-environment.txt"
NETWORK_CONNECTIONS="$LAB/network-connections.txt"
EVIDENCE_ROOT=${FM_OMP_LIFECYCLE_EVIDENCE_DIR:-"$ROOT/.no-mistakes/omp-lifecycle-evidence"}
EVIDENCE_BUNDLE=

sanitize_copy() {
  local source=$1 destination=$2
  SOURCE_PATH="$source" DESTINATION_PATH="$destination" node <<'NODE'
const fs = require("node:fs");
const source = process.env.SOURCE_PATH;
let content = fs.existsSync(source) ? fs.readFileSync(source, "utf8") : "";
content = content
  .replace(/((?:api[_-]?key|access[_-]?token|refresh[_-]?token|authorization|password|secret)\s*[:=]\s*)[^\s,'"}]+/gi, "$1<redacted>")
  .replace(/(Bearer\s+)[A-Za-z0-9._~+\/-]+/gi, "$1<redacted>");
fs.writeFileSync(process.env.DESTINATION_PATH, content);
NODE
}

capture_runtime_evidence() {
  local pid=${1:-}
  if tmux display-message -p -t "$TARGET" '#{pane_id}' >/dev/null 2>&1; then
    tmux capture-pane -p -S -500 -t "$TARGET" > "$PANE_TRANSCRIPT" 2>/dev/null || : > "$PANE_TRANSCRIPT"
  else
    : > "$PANE_TRANSCRIPT"
  fi
  grep -Ei 'mcp' "$PANE_TRANSCRIPT" > "$MCP_RECORD" 2>/dev/null || : > "$MCP_RECORD"
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    /usr/sbin/lsof -Fn -p "$pid" > "$OPEN_FILES" 2>/dev/null || : > "$OPEN_FILES"
    /usr/sbin/lsof -nP -a -p "$pid" -i > "$NETWORK_CONNECTIONS" 2>/dev/null \
      || : > "$NETWORK_CONNECTIONS"
    ps eww -p "$pid" -o command= > "$PROCESS_ENVIRONMENT" 2>/dev/null \
      || : > "$PROCESS_ENVIRONMENT"
  else
    : > "$OPEN_FILES"
    : > "$NETWORK_CONNECTIONS"
    : > "$PROCESS_ENVIRONMENT"
  fi
}

retain_failure_evidence() {
  local reason=$1 stamp
  [ -n "$EVIDENCE_BUNDLE" ] && return 0
  stamp=$(date -u +%Y%m%dT%H%M%SZ)
  EVIDENCE_BUNDLE="$EVIDENCE_ROOT/failure-$stamp-$$"
  mkdir -p "$EVIDENCE_BUNDLE" || return 1
  sanitize_copy "$MANIFEST" "$EVIDENCE_BUNDLE/manifest.json"
  sanitize_copy "$CONSTRUCTED_ARGV" "$EVIDENCE_BUNDLE/constructed-argv.json"
  sanitize_copy "$PANE_TRANSCRIPT" "$EVIDENCE_BUNDLE/pane-transcript.txt"
  sanitize_copy "$MCP_RECORD" "$EVIDENCE_BUNDLE/mcp-source-status.txt"
  sanitize_copy "$OPEN_FILES" "$EVIDENCE_BUNDLE/process-open-files.txt"
  sanitize_copy "$PROCESS_ENVIRONMENT" "$EVIDENCE_BUNDLE/process-environment.txt"
  sanitize_copy "$NETWORK_CONNECTIONS" "$EVIDENCE_BUNDLE/network-connections.txt"
  printf '%s\n' "$reason" > "$EVIDENCE_BUNDLE/failure.txt"
  printf 'failure evidence: %s\n' "$EVIDENCE_BUNDLE" >&2
}

cleanup_all() {
  local trapped_status=$? requested_status=${1:-} status live_pid='' cleanup_error=0
  if [ -n "$requested_status" ]; then
    status=$requested_status
  else
    status=$trapped_status
  fi
  live_pid=$(omp_pid 2>/dev/null || true)
  capture_runtime_evidence "$live_pid"
  if [ "$status" -ne 0 ]; then
    retain_failure_evidence "test exited $status before cleanup" || true
  fi
  if [ -n "${REAL_TMUX:-}" ] && [ -n "${SOCKET_PATH:-}" ]; then
    "$REAL_TMUX" -S "$SOCKET_PATH" kill-server >/dev/null 2>&1 || true
  fi
  if [ -e "$SOCKET_PATH" ] || [ -L "$SOCKET_PATH" ]; then
    unlink "$SOCKET_PATH" 2>/dev/null || cleanup_error=1
  fi
  if [ -e "$SOCKET_PATH" ] || [ -L "$SOCKET_PATH" ]; then
    cleanup_error=1
    printf 'error: stale private tmux socket remains: %s\n' "$SOCKET_PATH" >&2
  fi
  if [ "$cleanup_error" -ne 0 ]; then
    retain_failure_evidence "private tmux socket cleanup failed" || true
    status=1
  fi
  case "${LAB:-}" in
    "$ROOT"/.fm-omp-lifecycle.*) rm -rf "$LAB" ;;
    '') ;;
    *)
      printf 'error: refusing to remove unexpected OMP laboratory path: %s\n' "$LAB" >&2
      status=1
      ;;
  esac
  trap - EXIT
  if [ -n "$requested_status" ]; then
    return "$status"
  fi
  exit "$status"
}
trap cleanup_all EXIT

harness_fail() {
  fail "$1 [binary: $OMP_BIN]"
}

note() {
  printf '# %s\n' "$1"
}

mkdir -p "$STATE" "$DATA/$ID" "$HOME_DIR/config" "$SHIM_DIR"
"$ROOT/bin/fm-omp-candidate-artifacts.sh" prepare "$AGENT_DIR" "$WORKTREE" \
  || harness_fail "the candidate artifact owner could not prepare isolated settings"

LAB_REAL=$(cd "$LAB" && pwd -P)
AGENT_REAL=$(cd "$AGENT_DIR" && pwd -P)
WORKTREE_REAL=$(cd "$WORKTREE" && pwd -P)
OPERATOR_HOME_REAL=$(cd "${HOME:?}" && pwd -P)
case "$AGENT_REAL" in
  "$LAB_REAL"/*) ;;
  *) harness_fail "the resolved OMP agent directory is not inside the scratch lab"
esac
case "$AGENT_REAL" in
  "$OPERATOR_HOME_REAL/.claude"|"$OPERATOR_HOME_REAL/.claude/"*)
    harness_fail "the resolved OMP agent directory points at the operator Claude directory"
    ;;
esac
pass "OMP lifecycle preflight: the resolved agent directory is scratch space outside the operator Claude directory"

git init -q "$WORKTREE_REAL" || harness_fail "could not initialize the scratch worktree"
printf '%s\n' 'lifecycle fixture' > "$WORKTREE_REAL/README.md"
git -C "$WORKTREE_REAL" add README.md
git -C "$WORKTREE_REAL" -c user.name=fmtest -c user.email=fmtest@example.invalid \
  commit -q -m fixture || harness_fail "could not commit the scratch worktree"

printf '%s\n' \
  '# OMP lifecycle laboratory' \
  '' \
  'Write the integers from 1 through 10000, one per line, and do nothing else.' > "$BRIEF"

GEN=$("$ROOT/bin/fm-busy-event.sh" arm "$STATE" "$ID") \
  || harness_fail "could not arm the OMP lifecycle extension"
"$ROOT/bin/fm-omp-candidate-artifacts.sh" extension "$STATE/$ID.omp-ext.ts" \
  "$ROOT/bin/fm-busy-event.sh" "$STATE" "$ID" "$GEN" "$STATE/$ID.turn-ended" \
  || harness_fail "could not render the OMP lifecycle extension"
"$ROOT/bin/fm-omp-candidate-artifacts.sh" manifest \
  "$AGENT_REAL" "$WORKTREE_REAL" "$OMP_BIN" "$OMP_MODEL" "$STATE/$ID.omp-ext.ts" \
  > "$MANIFEST" || harness_fail "could not render the OMP lifecycle manifest"

MANIFEST_PATH="$MANIFEST" EXPECTED_AGENT="$AGENT_REAL" EXPECTED_CWD="$WORKTREE_REAL" \
  EXPECTED_BINARY="$OMP_BIN" OPERATOR_CLAUDE="$OPERATOR_HOME_REAL/.claude" \
  node <<'NODE' || harness_fail "the rendered lifecycle manifest failed its pre-launch isolation assertion"
const fs = require("node:fs");
const manifest = JSON.parse(fs.readFileSync(process.env.MANIFEST_PATH, "utf8"));
const agent = manifest.environment.PI_CODING_AGENT_DIR;
const operatorClaude = process.env.OPERATOR_CLAUDE;
if (agent !== process.env.EXPECTED_AGENT) process.exit(1);
if (agent === operatorClaude || agent.startsWith(operatorClaude + "/")) process.exit(1);
if (manifest.argv[0] !== process.env.EXPECTED_BINARY) process.exit(1);
const cwdIndex = manifest.argv.indexOf("--cwd");
if (cwdIndex < 0 || manifest.argv[cwdIndex + 1] !== process.env.EXPECTED_CWD) process.exit(1);
if (!manifest.argv.includes("--no-tools")) process.exit(1);
NODE

BOUNDARY_OUTPUT=$("$BOUNDARY" verify-boundary "$MANIFEST" "$LAB_REAL" "$OPERATOR_HOME_REAL" 2>&1) \
  || harness_fail "the launch environment failed its fail-closed configuration-root boundary: $BOUNDARY_OUTPUT"
note "command: bin/fm-omp-candidate-artifacts.sh verify-boundary <manifest> <scratch-lab> <operator-home>"
note "observed: $BOUNDARY_OUTPUT"
pass "OMP lifecycle preflight: every effective compatibility configuration source resolves inside the lab"

MANIFEST_PATH="$MANIFEST" NEGATIVE_PATH="$NEGATIVE_MANIFEST" \
  OPERATOR_HOME="$OPERATOR_HOME_REAL" node <<'NODE' \
  || harness_fail "could not construct the deliberate incomplete-boundary control"
const fs = require("node:fs");
const manifest = JSON.parse(fs.readFileSync(process.env.MANIFEST_PATH, "utf8"));
manifest.environment.HOME = process.env.OPERATOR_HOME;
fs.writeFileSync(process.env.NEGATIVE_PATH, JSON.stringify(manifest));
NODE
if NEGATIVE_OUTPUT=$("$BOUNDARY" verify-boundary \
  "$NEGATIVE_MANIFEST" "$LAB_REAL" "$OPERATOR_HOME_REAL" 2>&1); then
  harness_fail "the deliberate incomplete HOME boundary was accepted: $NEGATIVE_OUTPUT"
fi
case "$NEGATIVE_OUTPUT" in
  *HOME*) ;;
  *) harness_fail "the deliberate boundary refusal did not identify HOME: $NEGATIVE_OUTPUT" ;;
esac
note "negative control: $NEGATIVE_OUTPUT"
pass "OMP lifecycle preflight: an incomplete HOME boundary is refused before launch"

FM_OMP_INPUT=$("$ROOT/bin/fm-operational-input.sh" encode launch-brief < "$BRIEF") \
  MANIFEST_PATH="$MANIFEST" OUTPUT_PATH="$CONSTRUCTED_ARGV" node <<'NODE' \
  || harness_fail "could not record the constructed OMP argv"
const fs = require("node:fs");
const manifest = JSON.parse(fs.readFileSync(process.env.MANIFEST_PATH, "utf8"));
fs.writeFileSync(process.env.OUTPUT_PATH, JSON.stringify([...manifest.argv, process.env.FM_OMP_INPUT], null, 2) + "\n");
NODE

if [ "${FM_OMP_LIFECYCLE_PREFLIGHT_ONLY:-0}" = 1 ]; then
  cleanup_all 0
  trap - EXIT
  echo "all pre-launch OMP containment checks passed without launching OMP"
  exit 0
fi

cat > "$SHIM_DIR/tmux" <<'SH'
#!/usr/bin/env bash
exec "${FM_OMP_REAL_TMUX:?}" -S "${FM_OMP_TMUX_SOCKET:?}" "$@"
SH
chmod +x "$SHIM_DIR/tmux"

cat > "$LAUNCHER" <<'SH'
#!/usr/bin/env bash
set -eu
environment=()
argv=()
while IFS= read -r entry; do
  environment+=("$entry")
done < <(node -e 'const m=require(process.argv[1]); for (const [k,v] of Object.entries(m.environment)) console.log(`${k}=${v}`)' "$FM_OMP_MANIFEST")
while IFS= read -r word; do
  argv+=("$word")
done < <(node -e 'const m=require(process.argv[1]); for (const x of m.argv) console.log(x)' "$FM_OMP_MANIFEST")
input=$("$FM_OMP_OPINPUT" encode launch-brief < "$FM_OMP_BRIEF")
exec env -i "${environment[@]}" OMP_SKIP_SETUP=1 "${argv[@]}" "$input"
SH
chmod +x "$LAUNCHER"

export FM_OMP_REAL_TMUX="$REAL_TMUX"
export FM_OMP_TMUX_SOCKET="$SOCKET_PATH"
export PATH="$SHIM_DIR:$PATH"
export FM_OMP_MANIFEST="$MANIFEST"
export FM_OMP_OPINPUT="$ROOT/bin/fm-operational-input.sh"
export FM_OMP_BRIEF="$BRIEF"

cat > "$STATE/$ID.meta" <<EOF
window=$TARGET
endpoint_task_id=$ID
worktree=$WORKTREE_REAL
project=omp-lifecycle-lab
harness=omp
kind=ship
mode=no-mistakes
yolo=off
backend=tmux
model=$OMP_MODEL
effort=default
EOF

tmux new-session -d -s "$SESSION" -n "fm-$ID" -c "$WORKTREE_REAL" \
  || harness_fail "could not start the private tmux server"

pane_pid() {
  tmux display-message -p -t "$TARGET" '#{pane_pid}' 2>/dev/null
}

omp_pid() {
  local parent
  parent=$(pane_pid)
  [ -n "$parent" ] || return 1
  ps -axo pid=,ppid=,comm= | awk -v parent="$parent" \
    '$2 == parent && $3 ~ /(^|\/)omp$/ { print $1; exit }'
}

wait_for_omp() {
  local i=0 pid=
  while [ "$i" -lt 300 ]; do
    pid=$(omp_pid || true)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      printf '%s\n' "$pid"
      return 0
    fi
    sleep 0.2
    i=$((i + 1))
  done
  return 1
}

wait_for_pane_pattern() {
  local pattern=$1 i=0
  while [ "$i" -lt 300 ]; do
    if tmux capture-pane -p -S -200 -t "$TARGET" 2>/dev/null | grep -Eiq "$pattern"; then
      return 0
    fi
    sleep 0.2
    i=$((i + 1))
  done
  return 1
}

wait_for_pane_quiet() {
  local i=0 stable=0 previous='' current=''
  while [ "$i" -lt 150 ]; do
    current=$(tmux capture-pane -p -S -500 -t "$TARGET" 2>/dev/null | shasum -a 256 | awk '{ print $1 }')
    if [ -n "$current" ] && [ "$current" = "$previous" ]; then
      stable=$((stable + 1))
      [ "$stable" -ge 10 ] && return 0
    else
      stable=0
      previous=$current
    fi
    sleep 0.2
    i=$((i + 1))
  done
  return 1
}

launch_real_omp() {
  tmux send-keys -t "$TARGET" -l "$LAUNCHER" \
    || harness_fail "could not type the manifest consumer into the private tmux pane"
  tmux send-keys -t "$TARGET" Enter \
    || harness_fail "could not submit the manifest consumer in the private tmux pane"
  wait_for_omp || {
    tmux capture-pane -p -S -200 -t "$TARGET" >&2 || true
    harness_fail "the manifest did not start a real OMP process"
  }
}

run_control() {
  FM_HOME="$HOME_DIR" FM_CONTROL_POLL=0.2 FM_CONTROL_SETTLE_WAIT=0.2 \
    FM_CONTROL_EXIT_WAIT=30 FM_CONTROL_LAUNCH_WAIT=30 "$CONTROL" "$@"
}

note "launch environment: OMP_SKIP_SETUP=1 PI_CODING_AGENT_DIR=$AGENT_REAL"
note "launch manifest: binary=$OMP_BIN cwd=$WORKTREE_REAL model=$OMP_MODEL tools=disabled"

FIRST_PID=$(launch_real_omp) || harness_fail "the first manifest launch failed"
FIRST_COMMAND=$(ps -p "$FIRST_PID" -o command= 2>/dev/null || true)
case "$FIRST_COMMAND" in
  "$OMP_BIN"|"$OMP_BIN "*) ;;
  *) harness_fail "the tmux child is not the manifest-selected real OMP binary"
esac
wait_for_pane_pattern 'No model|No API key found|not found|Ask anything' \
  || {
    tmux capture-pane -p -S -200 -t "$TARGET" >&2 || true
    harness_fail "the setup-skipped OMP process never reached its credential-free input loop"
  }
wait_for_pane_quiet \
  || harness_fail "the setup-skipped OMP surface did not settle for containment observation"
capture_runtime_evidence "$FIRST_PID"

for actual_root in \
  "HOME=$AGENT_REAL/home" \
  "PI_CODING_AGENT_DIR=$AGENT_REAL" \
  'PI_CONFIG_DIR=.omp' \
  "XDG_CONFIG_HOME=$AGENT_REAL/xdg/config" \
  "XDG_DATA_HOME=$AGENT_REAL/xdg/data" \
  "XDG_STATE_HOME=$AGENT_REAL/xdg/state" \
  "XDG_CACHE_HOME=$AGENT_REAL/xdg/cache" \
  'OMP_SKIP_SETUP=1'; do
  grep -Fq "$actual_root" "$PROCESS_ENVIRONMENT" \
    || harness_fail "the running OMP process did not retain the proven root $actual_root"
done
if grep -Fq " HOME=$OPERATOR_HOME_REAL " "$PROCESS_ENVIRONMENT"; then
  harness_fail "the running OMP process retained the operator HOME"
fi

for operator_source in \
  "$OPERATOR_HOME_REAL/.claude.json" \
  "$OPERATOR_HOME_REAL/.claude/" \
  "$OPERATOR_HOME_REAL/.cursor/" \
  "$OPERATOR_HOME_REAL/.gemini/" \
  "$OPERATOR_HOME_REAL/.codex/" \
  "$OPERATOR_HOME_REAL/.config/opencode/" \
  "$OPERATOR_HOME_REAL/.codeium/windsurf/" \
  "$OPERATOR_HOME_REAL/.vscode/"; do
  if grep -Fq "$operator_source" "$OPEN_FILES"; then
    harness_fail "the running OMP process held an operator configuration path: $operator_source"
  fi
done

if [ -s "$MCP_RECORD" ]; then
  printf '%s\n' 'observed MCP source/status lines:' >&2
  cat "$MCP_RECORD" >&2
  harness_fail "the contained OMP process still rendered MCP discovery or connection activity"
fi
NETWORK_CONNECTION_COUNT=$(awk 'NR > 1 && /TCP/ { count += 1 } END { print count + 0 }' "$NETWORK_CONNECTIONS")
note "running-process environment: isolated HOME, PI_CONFIG_DIR, PI_CODING_AGENT_DIR, and XDG roots verified; operator HOME absent"
note "running-process open-file snapshot: no operator Claude, Cursor, Gemini, Codex, OpenCode, Windsurf, or VS Code configuration path"
note "running-process MCP source/status lines: none"
note "running-process network connections: $NETWORK_CONNECTION_COUNT external TCP connection(s) observed; no evidence classified them as MCP"
pass "real OMP containment: zero MCP reach and no operator configuration access observed"

if [ "${FM_OMP_LIFECYCLE_OBSERVE_ONLY:-0}" = 1 ]; then
  cleanup_all 0
  trap - EXIT
  echo "all live OMP containment observations passed; lifecycle controls not exercised"
  exit 0
fi

set +e
INTERRUPT_OUTPUT=$(run_control "$ID" interrupt 2>&1)
INTERRUPT_RC=$?
set -e
[ "$INTERRUPT_RC" -eq 0 ] \
  || harness_fail "fm-control interrupt exited ${INTERRUPT_RC}: $INTERRUPT_OUTPUT"
assert_contains "$INTERRUPT_OUTPUT" "interrupt-delivered $ID harness=omp backend=tmux verified=agent-alive cancel=unconfirmed" \
  "fm-control interrupt did not report its exact live-process postcondition"
AFTER_INTERRUPT_PID=$(omp_pid || true)
[ "$AFTER_INTERRUPT_PID" = "$FIRST_PID" ] && kill -0 "$FIRST_PID" 2>/dev/null \
  || harness_fail "interrupt did not preserve the exact running OMP process"
note "command: FM_HOME=<scratch-home> bin/fm-control.sh $ID interrupt"
note "observed: $INTERRUPT_OUTPUT; pid $FIRST_PID remained alive in the same tmux endpoint"
note "mechanism strength: the same single Escape and process-liveness postcondition apply to a configured session, but this idle no-model run does not prove mid-inference cancellation"
pass "real OMP control: interrupt delivery preserved the exact idle process"

set +e
EXIT_OUTPUT=$(run_control "$ID" exit 2>&1)
EXIT_RC=$?
set -e
[ "$EXIT_RC" -eq 0 ] \
  || harness_fail "fm-control exit exited ${EXIT_RC}: $EXIT_OUTPUT"
! kill -0 "$FIRST_PID" 2>/dev/null \
  || harness_fail "fm-control exit returned while the original OMP process was still alive"
tmux display-message -p -t "$TARGET" '#{pane_id}' >/dev/null 2>&1 \
  || harness_fail "fm-control exit removed the preserved tmux endpoint"
[ -z "$(omp_pid || true)" ] \
  || harness_fail "an OMP process remained in the preserved endpoint after exit"
note "command: FM_HOME=<scratch-home> bin/fm-control.sh $ID exit"
note "observed: $EXIT_OUTPUT; pid $FIRST_PID was gone and the tmux endpoint remained"
note "mechanism strength: the same /quit submission and dead-process classifier apply to a configured idle session, but this no-model run does not cover interrupt-first or provider teardown while inference is active"
pass "real OMP control: exit stopped the process and preserved the tmux endpoint"

SECOND_PID=$(launch_real_omp) || harness_fail "the second manifest launch failed"
[ -n "$SECOND_PID" ] && [ "$SECOND_PID" != "$FIRST_PID" ] \
  || harness_fail "the relaunch precondition did not contain a fresh real OMP process"

set +e
RELAUNCH_OUTPUT=$(run_control "$ID" relaunch --harness omp --model "$OMP_MODEL" \
  --note 'Lifecycle gate relaunch probe.' 2>&1)
RELAUNCH_RC=$?
set -e
if [ "$RELAUNCH_RC" -ne 0 ]; then
  ! kill -0 "$SECOND_PID" 2>/dev/null \
    || harness_fail "the refused relaunch left its prior OMP process running unexpectedly"
  [ -z "$(omp_pid || true)" ] \
    || harness_fail "the refused relaunch produced an unattributed replacement OMP process"
  note "command: FM_HOME=<scratch-home> bin/fm-control.sh $ID relaunch --harness omp --model $OMP_MODEL --note <probe-note>"
  note "observed: the prior pid $SECOND_PID stopped, no replacement OMP pid appeared, and fm-spawn retained the dormancy refusal"
  note "mechanism strength: the stop half used the same /quit and dead-process proof, but replacement launch never occurred, so no configured or no-model relaunch postcondition was proven"
  printf '%s\n' "$RELAUNCH_OUTPUT" >&2
  harness_fail "fm-control relaunch could not replace OMP because fm-spawn retained the mandatory dormancy refusal"
fi

THIRD_PID=$(omp_pid || true)
[ -n "$THIRD_PID" ] && [ "$THIRD_PID" != "$SECOND_PID" ] && kill -0 "$THIRD_PID" 2>/dev/null \
  || harness_fail "fm-control relaunch returned without a fresh real OMP replacement"
pass "real OMP control: relaunch replaced the process in the same tmux endpoint"

cleanup_all 0
trap - EXIT
echo "all live OMP lifecycle checks passed"
