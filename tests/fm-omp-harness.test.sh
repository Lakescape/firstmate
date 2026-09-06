#!/usr/bin/env bash
# tests/fm-omp-harness.test.sh - policy and artifact tests for the dormant
# CANDIDATE omp (Oh My Pi) crewmate/scout harness owned by bin/fm-spawn.sh, bin/fm-harness.sh,
# bin/fm-busy-lib.sh, and bin/backends/tmux.sh.
#
# Spawn cases run the REAL fm-spawn against a fake backend and hostile `omp`
# executables on PATH. Every executable stays untouched while the runnable
# boundary remains closed pending independent consumer-containment and ATX-2170
# lifecycle proofs.
#
# Two of the cases are POLICY MATRICES that report their own row counts rather
# than a bare pass, so a silently shrinking matrix cannot read as green:
#   - the model policy matrix, 12 equivalence classes of rejected model value;
#   - the selection policy matrix, 12 ways omp can be selected or refused.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-busy-lib.sh"

# The backend libraries are loaded through the dispatcher, never sourced
# directly: bin/fm-backend.sh is what binds FM_BACKEND_LIB_DIR, which
# bin/backends/tmux.sh needs to resolve its own dependencies.
# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source tmux || { echo "unable to load the tmux backend library" >&2; exit 1; }

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-omp-harness)

# The requested release recorded by the candidate metadata contract.
OMP_PINNED_VERSION="omp/17.2.9"

# Every omp launch requires an explicit, fully qualified provider/model. This is
# a STRUCTURAL fixture string only: no provider is contacted, no model catalog is
# queried, and no candidate executable is invoked.
OMP_MODEL="anthropic/claude-sonnet-4-5"

make_omp_fakebin() {  # <dir> [omp-version|absent] -> echoes fakebin dir
  local dir=$1 version=${2:-$OMP_PINNED_VERSION} fakebin node_bin
  fakebin=$(fm_fakebin "$dir")
  node_bin=$(command -v node) || fail "the OMP fixture requires node for adapter JSON parsing"
  ln -sf "$node_bin" "$fakebin/node"
  # The tmux stub records send-keys payloads so a test can read back the exact
  # launch command the adapter would deliver to a pane, without a real pane.
  # FM_FAKE_WINDOW/FM_FAKE_COMMAND model an existing, agent-free endpoint for
  # the relaunch case; every other case leaves them unset and unused.
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
  *"#{pane_tty}"*) exit 0 ;;
  *"#{pane_current_command}"*) printf '%s\n' "${FM_FAKE_COMMAND:-zsh}"; exit 0 ;;
esac
if [ "${1:-}" = send-keys ] && [ -n "${FM_TMUX_LOG:-}" ]; then
  printf '%s\n' "${!#}" >> "$FM_TMUX_LOG"
fi
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) [ -z "${FM_FAKE_WINDOW:-}" ] || printf '%s\n' "$FM_FAKE_WINDOW"; exit 0 ;;
  has-session|new-session|new-window|kill-window|send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  # `absent` deliberately installs no omp at all.
  if [ "$version" != absent ]; then
    cat > "$fakebin/omp" <<SH
#!/usr/bin/env bash
set -u
if [ -n "\${FM_OMP_STUB_LOG:-}" ]; then
  {
    printf 'omp'
    for a in "\$@"; do printf '\x1f%s' "\$a"; done
    printf '\n'
  } >> "\$FM_OMP_STUB_LOG"
fi
if [ "\${1:-}" = --version ]; then
  if [ "$version" = hang ]; then
    sleep 30
  else
    printf '%s\n' "$version"
  fi
  exit 0
fi
echo "omp stub refuses to run a session" >&2
exit 97
SH
    chmod +x "$fakebin/omp"
  fi
  printf '%s\n' "$fakebin"
}

make_omp_case() {  # <name> <crew-harness> <id> [omp-version|absent]
  local name=$1 harness=$2 id=$3 version=${4:-$OMP_PINNED_VERSION}
  local case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_omp_fakebin "$case_dir/fake" "$version")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf '%s\n' "$harness" > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  mkdir -p "$home/data/$id"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin"
}

read_case_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

run_spawn() {  # <home> <wt> <fakebin> <spawn-args...>
  local home=$1 wt=$2 fakebin=$3 path backend=${FM_TEST_BACKEND:-tmux}
  shift 3
  path="$fakebin:${FM_TEST_BASE_PATH:-$PATH}"
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    GROK_HOME="$home/grok-home" PATH="$path" FM_BACKEND="$backend" \
    FM_OMP_STUB_LOG="${FM_OMP_STUB_LOG:-}" FM_TMUX_LOG="${FM_TMUX_LOG:-}" \
    "$SPAWN" "$@" 2>&1
}

# The same environment as run_spawn but WITHOUT FM_SPAWN_NO_GUARD, so
# bin/fm-guard.sh actually runs. The guard is the earliest writer of home state
# on the spawn path, which is what makes it usable as an ordering probe.
run_spawn_guarded() {  # <home> <wt> <fakebin> <spawn-args...>
  local home=$1 wt=$2 fakebin=$3 path backend=${FM_TEST_BACKEND:-tmux}
  shift 3
  path="$fakebin:${FM_TEST_BASE_PATH:-$PATH}"
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    GROK_HOME="$home/grok-home" PATH="$path" FM_BACKEND="$backend" \
    FM_OMP_STUB_LOG="${FM_OMP_STUB_LOG:-}" FM_TMUX_LOG="${FM_TMUX_LOG:-}" \
    "$SPAWN" "$@" 2>&1
}



test_omp_token_is_not_normalized_to_pi() {
  local out
  # config/crew-harness carrying the exact token must resolve to omp, never to
  # the Pi family this fork descends from.
  mkdir -p "$TMP_ROOT/resolve/config"
  printf 'omp\n' > "$TMP_ROOT/resolve/config/crew-harness"
  out=$(FM_CONFIG_OVERRIDE="$TMP_ROOT/resolve/config" "$ROOT/bin/fm-harness.sh" crew)
  [ "$out" = omp ] || fail "config/crew-harness omp must resolve to 'omp', got '$out'"

  # The firstmate-owned launch marker identifies an omp worker as omp. The
  # foreign markers are cleared here exactly as bin/fm-spawn.sh clears them on
  # the omp launch, which is what makes this marker reachable at all - the test
  # itself may be running under one of those harnesses.
  out=$(env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u FM_PI_HARNESS \
    -u CURSOR_AGENT -u CURSOR_INVOKED_AS \
    FM_OMP_HARNESS=1 "$ROOT/bin/fm-harness.sh")
  [ "$out" = omp ] || fail "FM_OMP_HARNESS=1 must detect 'omp', got '$out'"

  # An UNcleared foreign marker still wins, proving adding omp changed no
  # pre-existing marker precedence. Both the oldest marker and the newest one
  # are checked, because the launch's clearing list is only correct while it
  # covers EVERY marker resolved ahead of omp.
  out=$(env -u PI_CODING_AGENT -u GROK_AGENT -u FM_PI_HARNESS \
    -u CURSOR_AGENT -u CURSOR_INVOKED_AS \
    CLAUDECODE=1 FM_OMP_HARNESS=1 "$ROOT/bin/fm-harness.sh")
  [ "$out" = claude ] || fail "existing marker precedence changed, got '$out'"
  out=$(env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u FM_PI_HARNESS \
    -u CURSOR_INVOKED_AS \
    CURSOR_AGENT=1 FM_OMP_HARNESS=1 "$ROOT/bin/fm-harness.sh")
  [ "$out" = cursor ] || fail "an uncleared CURSOR_AGENT must still outrank omp, got '$out'"

  pass "omp is recognized only through its configured token or First Mate-owned marker and is never normalized to pi"
}

test_omp_is_unreachable_without_explicit_selection() {
  local rec id=omp-default out
  # crew-harness stays claude: nothing may reach omp implicitly.
  rec=$(make_omp_case omp-default claude "$id")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off)
  expect_code 0 $? "default spawn should succeed: $out"
  assert_contains "$out" "spawned $id harness=claude" "an unselected omp must not be reachable"
  assert_absent "$HOME_DIR/state/$id.omp-ext.ts" "no omp extension may be written for another harness"
  pass "omp is dormant: it is unreachable unless it is explicitly selected"
}

# --- dormant executable boundary ------------------------------------------

test_omp_dormancy_never_resolves_or_executes_candidate() {
  local label version rec id out status stub_log row=0
  for label in requested drift substituted hanging absent; do
    case "$label" in
      requested) version=$OMP_PINNED_VERSION ;;
      drift) version=omp/17.3.0 ;;
      substituted) version=pi/0.82.0 ;;
      hanging) version=hang ;;
      absent) version=absent ;;
    esac
    row=$((row + 1))
    id="omp-dormant-$row"
    rec=$(make_omp_case "$id" claude "$id" "$version")
    read_case_record "$rec"
    stub_log="$CASE_DIR/omp-argv"
    : > "$stub_log"
    out=$(FM_OMP_STUB_LOG="$stub_log" run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" \
      "$id" "$PROJ_DIR" --harness omp --model "$OMP_MODEL" --mode no-mistakes --yolo off)
    status=$?
    [ "$status" -ne 0 ] || fail "$label candidate escaped dormancy: $out"
    assert_contains "$out" "session-free omp/17.2.9 consumer" \
      "$label candidate did not stop at both mandatory gates: $out"
    [ ! -s "$stub_log" ] || fail "$label candidate executable was invoked: $(cat "$stub_log")"
    assert_absent "$HOME_DIR/state/$id.meta" "$label dormant selection published metadata"
    assert_absent "$HOME_DIR/state/$id.omp-ext.ts" "$label dormant selection rendered an extension"
  done
  [ "$row" -eq 5 ] || fail "dormant executable matrix lost a row"
  pass "OMP dormancy ignores requested, drifted, substituted, hanging, and absent candidates"
}

# --- launch shape ----------------------------------------------------------

test_omp_launch_request_is_rendered() {
  local manifest template
  manifest=$("$ROOT/bin/fm-omp-candidate-artifacts.sh" manifest \
    /isolated/agent /isolated/cwd /opt/omp "$OMP_MODEL" /state/task.omp-ext.ts) \
    || fail "candidate OMP manifest did not render"
  template=$("$ROOT/bin/fm-omp-candidate-artifacts.sh" launch-template) \
    || fail "candidate OMP launch template did not render"
  MANIFEST=$manifest TEMPLATE=$template node <<'NODE' \
    || fail "candidate OMP manifest or launch template drifted from its requested output contract"
const manifest = JSON.parse(process.env.MANIFEST);
if (JSON.stringify(Object.keys(manifest).sort()) !== JSON.stringify(["argv", "environment", "unsetEnvironment"])) process.exit(1);
const expectedUnset = [
  "CLAUDECODE", "PI_CODING_AGENT", "PI_CONFIG_FILES", "OMP_PROFILE", "PI_PROFILE", "GROK_AGENT",
  "FM_PI_HARNESS", "CURSOR_AGENT", "CURSOR_INVOKED_AS", "TRACEPARENT",
];
const expectedArgv = [
  "/opt/omp", "--cwd", "/isolated/cwd", "--approval-mode", "yolo",
  "--no-title", "--no-extensions", "--no-skills",
  "--no-lsp", "--no-tools", "--model", "anthropic/claude-sonnet-4-5",
  "-e", "/state/task.omp-ext.ts",
];
if (JSON.stringify(manifest.unsetEnvironment) !== JSON.stringify(expectedUnset)) process.exit(1);
if (manifest.environment.FM_OMP_HARNESS !== "1") process.exit(1);
if (manifest.environment.PI_CODING_AGENT_DIR !== "/isolated/agent") process.exit(1);
if (JSON.stringify(manifest.argv) !== JSON.stringify(expectedArgv)) process.exit(1);
if (manifest.argv.includes("--tools")) process.exit(1);
if (!manifest.argv.includes("--no-tools")) process.exit(1);
if (manifest.argv.includes("--add-dir")) process.exit(1);
if (manifest.argv.includes("/task/worktree")) process.exit(1);
const templateManifest = {
  ...manifest,
  environment: { FM_OMP_HARNESS: "1", PI_CODING_AGENT_DIR: "__OMPAGENTDIR__" },
  argv: manifest.argv.map((word) => ({
    "/opt/omp": "__OMPBIN__",
    "/isolated/cwd": "__OMPCWD__",
    "anthropic/claude-sonnet-4-5": "__OMPMODEL__",
    "/state/task.omp-ext.ts": "__OMPEXT__",
  })[word] || word),
};
const words = ["env"];
for (const name of templateManifest.unsetEnvironment) words.push("-u", name);
for (const [name, value] of Object.entries(templateManifest.environment)) words.push(`${name}=${value}`);
words.push(...templateManifest.argv);
const expectedTemplate = words.join(" ") + ' "$(__OPINPUT__ encode launch-brief < __BRIEF__)"';
if (process.env.TEMPLATE !== expectedTemplate) process.exit(1);
NODE
  pass "OMP candidate renderer emits its requested argv and environment contract"
}

test_omp_consumer_proof_gate_never_executes_candidate() {
  local dir fakebin log out status
  dir="$TMP_ROOT/omp-consumer-proof"
  fakebin="$dir/fakebin"
  log="$dir/omp-invocations"
  mkdir -p "$fakebin"
  : > "$log"
  cat > "$fakebin/omp" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_OMP_PROOF_STUB_LOG"
if [ "${1:-}" = --version ]; then
  printf '%s\n' "${FM_OMP_PROOF_STUB_VERSION:-omp/17.2.9}"
  exit 0
fi
exit 97
SH
  chmod +x "$fakebin/omp"
  out=$(PATH="$fakebin:$PATH" FM_OMP_PROOF_STUB_LOG="$log" FM_OMP_TOOLS_LIVE_E2E=1 \
    "$ROOT/tests/fm-omp-tools-live-e2e.test.sh" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "the unavailable exact-version consumer proof must fail closed"
  assert_contains "$out" "no supported session-free configuration and tool consumer" \
    "the consumer proof gate did not name its unresolved prerequisite"
  assert_contains "$out" "executable provenance, version, and effective behavior remain unproven" \
    "the consumer proof gate overstated requested metadata as effective proof"
  [ ! -s "$log" ] || fail "the unresolved consumer proof gate executed OMP: $(cat "$log")"
  pass "OMP consumer proof gate fails closed without candidate execution"
}

test_omp_candidate_artifacts_render_requested_settings_and_handle_continuation() {
  local state id gen agent_dir isolated_cwd ambient_agent ambient_project ambient_overlay manifest ext record turnend
  state="$TMP_ROOT/candidate-artifacts/state"
  id=omp-candidate-artifacts
  agent_dir="$state/isolated-agent"
  isolated_cwd="$state/isolated-cwd"
  ambient_agent="$state/ambient-agent"
  ambient_project="$state/ambient-project"
  ambient_overlay="$state/ambient-overlay.json"
  ext="$state/$id.omp-ext.ts"
  record="$state/$id.busy-state"
  turnend="$state/$id.turn-ended"
  mkdir -p "$state"
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$state" "$id") || fail "could not arm the candidate artifact fixture"
  mkdir -p "$ambient_agent" "$ambient_project/.omp"
  printf '%s\n' '{"retry":{"modelFallback":true,"usageAwareFallback":true,"fallbackChains":{"ambient":["provider/model"]}}}' > "$ambient_agent/config.yml"
  printf '%s\n' '{"retry":{"fallbackChains":{"project":["provider/model"]}}}' > "$ambient_project/.omp/config.yml"
  printf '%s\n' '{"retry":{"fallbackChains":{"overlay":["provider/model"]}}}' > "$ambient_overlay"
  "$ROOT/bin/fm-omp-candidate-artifacts.sh" prepare "$agent_dir" "$isolated_cwd" \
    || fail "could not prepare isolated candidate OMP settings"
  manifest=$("$ROOT/bin/fm-omp-candidate-artifacts.sh" manifest \
    "$agent_dir" "$isolated_cwd" /opt/omp "$OMP_MODEL" "$ext") \
    || fail "could not render the candidate OMP manifest"
  MANIFEST=$manifest AGENT_DIR=$agent_dir ISOLATED_CWD=$isolated_cwd \
    AMBIENT_AGENT=$ambient_agent AMBIENT_PROJECT=$ambient_project \
    PI_CONFIG_FILES=$ambient_overlay node <<'NODE' \
    || fail "candidate OMP settings artifacts drifted from their requested isolation contract"
const fs = require("node:fs");
const path = require("node:path");
const manifest = JSON.parse(process.env.MANIFEST);
if (!manifest.unsetEnvironment.includes("PI_CONFIG_FILES")) process.exit(1);
if (!manifest.unsetEnvironment.includes("OMP_PROFILE") || !manifest.unsetEnvironment.includes("PI_PROFILE")) process.exit(1);
if (manifest.environment.PI_CODING_AGENT_DIR === process.env.AMBIENT_AGENT) process.exit(1);
if (manifest.environment.PI_CODING_AGENT_DIR !== process.env.AGENT_DIR) process.exit(1);
const cwdIndex = manifest.argv.indexOf("--cwd");
const cwd = manifest.argv[cwdIndex + 1];
if (cwd === process.env.AMBIENT_PROJECT) process.exit(1);
if (cwd !== process.env.ISOLATED_CWD) process.exit(1);
if (manifest.argv.includes("--add-dir") || manifest.argv.includes("/task/worktree")) process.exit(1);
if (!manifest.argv.includes("--no-lsp")) process.exit(1);
const config = JSON.parse(fs.readFileSync(path.join(manifest.environment.PI_CODING_AGENT_DIR, "config.yml"), "utf8"));
const retry = config.retry;
if (!retry || retry.modelFallback !== false || retry.usageAwareFallback !== false) process.exit(1);
if (!retry.fallbackChains || Array.isArray(retry.fallbackChains) || Object.keys(retry.fallbackChains).length !== 0) process.exit(1);
if (!config.astEdit || config.astEdit.enabled !== false) process.exit(1);
NODE
  "$ROOT/bin/fm-omp-candidate-artifacts.sh" extension "$ext" \
    "$ROOT/bin/fm-busy-event.sh" "$state" "$id" "$gen" "$turnend" \
    || fail "could not render the candidate OMP extension"
  EXT_PATH="$ext" node --experimental-strip-types --input-type=module <<'NODE' \
    || fail "the candidate OMP continuation event did not execute"
import { pathToFileURL } from "node:url";
const handlers = new Map();
const module = await import(pathToFileURL(process.env.EXT_PATH).href);
module.default({ on(name, handler) { handlers.set(name, handler); } });
await handlers.get("agent_start")();
await handlers.get("agent_end")({ willContinue: true }, { isIdle: () => true });
await new Promise((resolve) => setTimeout(resolve, 150));
NODE
  assert_grep 'state=busy source=omp-ext event=agent-start' "$record" \
    "willContinue=true incorrectly settled the candidate extension"
  EXT_PATH="$ext" node --experimental-strip-types --input-type=module <<'NODE' \
    || fail "the final OMP settle event did not execute"
import { pathToFileURL } from "node:url";
const handlers = new Map();
const module = await import(pathToFileURL(process.env.EXT_PATH).href);
module.default({ on(name, handler) { handlers.set(name, handler); } });
await handlers.get("agent_end")({ willContinue: false }, { isIdle: () => true });
await new Promise((resolve) => setTimeout(resolve, 150));
NODE
  assert_grep 'state=idle source=omp-ext event=agent-end' "$record" \
    "the final OMP settle event did not record idle"
  pass "OMP candidate renders requested settings and preserves busy across willContinue"
}
arm_ordering_probes() {  # <task-id>
  local id=$1
  rm -f "$HOME_DIR/state/.last-watcher-beat"
  rm -f "$HOME_DIR/state/.guard-watcher-stale-banner"
  printf 'window=fm-decoy\nharness=claude\n' > "$HOME_DIR/state/decoy.meta"
  mkdir -p "$HOME_DIR/state/.spawn-$id.lock"
  printf '%s\n' "$$" > "$HOME_DIR/state/.spawn-$id.lock/pid"
}

test_ordering_probes_are_live() {
  local rec id=omp-probe out status guard_marker
  # Both ordering probes must actually fire on a launch that is ALLOWED to run
  # the whole preamble. Without this control, every "refused before the guard
  # and the lock" assertion below could pass while proving nothing.
  rec=$(make_omp_case omp-probe-control claude "$id")
  read_case_record "$rec"
  guard_marker="$HOME_DIR/state/.guard-watcher-stale-banner"
  arm_ordering_probes "$id"
  out=$(run_spawn_guarded "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" \
    "$id" "$PROJ_DIR" --harness claude --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "the held per-task spawn lock must refuse this spawn: $out"
  assert_contains "$out" "another spawn is already creating task $id" \
    "the held-lock probe is not blocking acquisition: $out"
  assert_present "$guard_marker" \
    "the watcher-guard probe never fired, so it cannot prove anything about ordering"
  rm -rf "$HOME_DIR/state/.spawn-$id.lock"
  pass "both refusal-ordering probes fire on a launch that runs the whole spawn preamble"
}

# assert_omp_launch_refused <task-id> <expected-message> [extra spawn args...]
#
# One omp spawn that must be refused, plus the proof that the refusal landed
# before any mutation: the watcher guard never wrote its episode marker, the
# per-task spawn lock was never reached, no task metadata, no busy contract, no
# extension, nothing sent to a pane, and the pinned executable never even probed
# for its version. The caller supplies the fixture, so a whole table of rejected
# values shares one worktree - a refused spawn creates nothing to isolate.
assert_omp_launch_refused() {  # <task-id> <expected-message> [extra spawn args...]
  local id=$1 want=$2 out status stub_log tmux_log
  shift 2
  stub_log="$CASE_DIR/omp-argv-$id"
  tmux_log="$CASE_DIR/tmux-sends-$id"
  : > "$stub_log"
  : > "$tmux_log"
  mkdir -p "$HOME_DIR/data/$id"
  printf 'brief for %s\n' "$id" > "$HOME_DIR/data/$id/brief.md"
  arm_ordering_probes "$id"
  out=$(FM_OMP_STUB_LOG="$stub_log" FM_TMUX_LOG="$tmux_log" \
    run_spawn_guarded "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" \
    "$id" "$PROJ_DIR" --harness omp "$@" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "$id: the spawn must be refused: $out"
  assert_contains "$out" "$want" "$id: refusal did not name the launch pin: $out"
  assert_not_contains "$out" "another spawn is already creating" \
    "$id: the refusal must precede per-task spawn-lock acquisition: $out"
  assert_absent "$HOME_DIR/state/.guard-watcher-stale-banner" \
    "$id: the refusal must precede the watcher guard's own state write"
  assert_absent "$HOME_DIR/state/$id.meta" "$id: refused spawn published task metadata"
  assert_absent "$HOME_DIR/state/$id.omp-ext.ts" "$id: refused spawn wrote the extension"
  assert_absent "$HOME_DIR/state/$id.busy-gen" "$id: refused spawn armed a busy contract"
  [ ! -s "$tmux_log" ] || fail "$id: refused spawn sent a command to a pane: $(cat "$tmux_log")"
  [ ! -s "$stub_log" ] || fail "$id: refused spawn invoked the pinned executable: $(cat "$stub_log")"
  rm -rf "$HOME_DIR/state/.spawn-$id.lock"
}

# --- policy matrix 1: the model pin, 12 equivalence classes -----------------

# Row counters for the model policy matrix. Class-scoped rather than
# test-scoped so a class that silently stops asserting cannot go unnoticed: the
# matrix reports both the class count and the concrete-value count.
OMP_MODEL_CLASSES=0
OMP_MODEL_VALUES=0
OMP_MODEL_LABELS=

# omp_model_class <label> <expected-message> [rejected values...]
# One equivalence class of model value omp must never launch on. With no values
# the class is "the flag was never passed at all". Every value is asserted
# through assert_omp_launch_refused, so widening a class cannot quietly shrink
# the matrix.
omp_model_class() {
  local label=$1 want=$2 bad
  shift 2
  OMP_MODEL_CLASSES=$((OMP_MODEL_CLASSES + 1))
  OMP_MODEL_LABELS="$OMP_MODEL_LABELS$OMP_MODEL_CLASSES. $label"$'\n'
  if [ "$#" -eq 0 ]; then
    OMP_MODEL_VALUES=$((OMP_MODEL_VALUES + 1))
    assert_omp_launch_refused "omp-m$OMP_MODEL_VALUES" "$want"
    return 0
  fi
  for bad in "$@"; do
    OMP_MODEL_VALUES=$((OMP_MODEL_VALUES + 1))
    assert_omp_launch_refused "omp-m$OMP_MODEL_VALUES" "$want" --model "$bad"
  done
}

test_omp_model_policy_matrix() {
  local rec want_absent want_shape
  want_absent="omp requires an explicit --model <provider>/<model>"
  want_shape="omp --model must be exactly '<provider>/<model>'"
  rec=$(make_omp_case omp-model-matrix claude omp-m0)
  read_case_record "$rec"

  # Twelve equivalence classes. Classes 1-2 are the "no usable model at all"
  # shapes; class 3 is what omp's own fuzzy matcher would resolve across
  # providers; classes 4-12 are structurally malformed or ambiguous. No catalog
  # is consulted for any of them - the refusal is purely structural.
  omp_model_class 'absent' "$want_absent"
  omp_model_class 'no-model sentinel' "$want_absent" default
  omp_model_class 'unqualified bare identifier' "$want_shape" opus claude-sonnet-4-5
  omp_model_class 'empty provider segment' "$want_shape" '/claude-sonnet-4-5'
  omp_model_class 'empty model segment' "$want_shape" 'anthropic/' 'anthropic/claude/'
  omp_model_class 'doubled separator' "$want_shape" 'anthropic//claude-sonnet-4-5'
  omp_model_class 'extra path segment' "$want_shape" 'anthropic/claude/sonnet'
  omp_model_class 'embedded whitespace' "$want_shape" 'anthropic claude' 'anthropic/claude sonnet'
  omp_model_class 'glob metacharacter' "$want_shape" 'anthropic/claude*' '*/claude-sonnet-4-5' 'anthropic/claude?'
  # shellcheck disable=SC2016  # the metacharacter cases must stay LITERAL: they are rejected input, not expansions
  omp_model_class 'shell metacharacter' "$want_shape" 'anthropic/claude;id' 'anthropic/$(id)' 'anthropic/`id`' 'anthropic/claude|tee'
  omp_model_class 'non-identifier segment start' "$want_shape" '-anthropic/claude' 'anthropic/-claude' '.anthropic/claude'
  omp_model_class 'wrong separator' "$want_shape" 'anthropic:claude'

  [ "$OMP_MODEL_CLASSES" -eq 12 ] \
    || fail "the omp model policy matrix must carry 12 classes, found $OMP_MODEL_CLASSES"$'\n'"$OMP_MODEL_LABELS"
  printf 'omp model-policy matrix: %d/%d classes refused before any mutation (%d concrete values)\n' \
    "$OMP_MODEL_CLASSES" 12 "$OMP_MODEL_VALUES"
  printf '%s' "$OMP_MODEL_LABELS"
  pass "omp model policy matrix: $OMP_MODEL_CLASSES/12 rejected-model classes refuse before the watcher guard, the task lock, and every other mutation"
}

# assert_raw_launch_refused_before_mutation <case> <task-id> <raw-command> <message>
assert_raw_launch_refused_before_mutation() {
  local case_name=$1 id=$2 raw=$3 want=$4 rec out status guard_marker tmux_log
  rec=$(make_omp_case "$case_name" claude "$id")
  read_case_record "$rec"
  guard_marker="$HOME_DIR/state/.guard-watcher-stale-banner"
  tmux_log="$CASE_DIR/tmux-sends"
  : > "$tmux_log"
  arm_ordering_probes "$id"
  out=$(FM_TMUX_LOG="$tmux_log" run_spawn_guarded "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" \
    "$id" "$PROJ_DIR" "$raw" --model "$OMP_MODEL" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "$case_name raw launch must be refused: $out"
  assert_contains "$out" "$want" "$case_name refusal did not name the raw-launch boundary: $out"
  assert_not_contains "$out" "another spawn is already creating" \
    "$case_name reached the task lock: $out"
  assert_absent "$guard_marker" "$case_name was refused after the watcher guard wrote state"
  assert_absent "$HOME_DIR/state/$id.meta" "$case_name published task metadata"
  assert_absent "$HOME_DIR/state/$id.omp-ext.ts" "$case_name wrote the extension"
  assert_absent "$HOME_DIR/state/$id.busy-gen" "$case_name armed a busy contract"
  [ ! -s "$tmux_log" ] || fail "$case_name sent a raw command to the backend: $(cat "$tmux_log")"
  rm -rf "$HOME_DIR/state/.spawn-$id.lock"
}

# --- policy matrix 2: selection shapes, 16 rows -----------------------------

test_omp_selection_policy_matrix() {
  local rec out status guard_marker sub_home tmux_log rows=0 enforced=0
  local want_model="omp requires an explicit --model"
  local want_second="omp is a candidate crewmate/scout adapter only"
  local want_explicit="every omp spawn and relaunch requires an explicit --harness omp selection"
  local want_raw="opaque raw launch commands are disabled because their execution identity cannot be verified"

  # Row 1: an explicit --harness omp with no model.
  rec=$(make_omp_case omp-sel-explicit claude omp-s1)
  read_case_record "$rec"
  rows=$((rows + 1))
  assert_omp_launch_refused omp-s1 "$want_model"
  assert_absent "$HOME_DIR/state/omp-s1.meta" "explicit shape published task metadata"
  enforced=$((enforced + 1))

  # Row 2: the back-compat positional argument must not activate this candidate.
  rec=$(make_omp_case omp-sel-positional claude omp-s2)
  read_case_record "$rec"
  guard_marker="$HOME_DIR/state/.guard-watcher-stale-banner"
  rows=$((rows + 1))
  arm_ordering_probes omp-s2
  out=$(run_spawn_guarded "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" \
    omp-s2 "$PROJ_DIR" omp --model "$OMP_MODEL" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "a positional omp selection must be refused: $out"
  assert_contains "$out" "$want_explicit" "positional shape: $out"
  assert_not_contains "$out" "another spawn is already creating" "positional shape reached the task lock: $out"
  assert_absent "$guard_marker" "positional shape was refused after the watcher guard wrote state"
  assert_absent "$HOME_DIR/state/omp-s2.meta" "positional shape published task metadata"
  rm -rf "$HOME_DIR/state/.spawn-omp-s2.lock"
  enforced=$((enforced + 1))

  # Row 3: config/crew-harness must not activate this candidate implicitly.
  rec=$(make_omp_case omp-sel-config omp omp-s3)
  read_case_record "$rec"
  guard_marker="$HOME_DIR/state/.guard-watcher-stale-banner"
  tmux_log="$CASE_DIR/tmux-sends"
  : > "$tmux_log"
  rows=$((rows + 1))
  arm_ordering_probes omp-s3
  out=$(FM_TMUX_LOG="$tmux_log" run_spawn_guarded "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" \
    omp-s3 "$PROJ_DIR" --model "$OMP_MODEL" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "a config-resolved omp launch must be refused: $out"
  assert_contains "$out" "$want_explicit" "config-resolved refusal did not require the explicit selector: $out"
  assert_not_contains "$out" "another spawn is already creating" "config shape reached the task lock: $out"
  assert_absent "$guard_marker" "config shape was refused after the watcher guard wrote state"
  assert_absent "$HOME_DIR/state/omp-s3.meta" "config shape published task metadata"
  [ ! -s "$tmux_log" ] || fail "refused config-resolved omp spawn sent a command to a pane"
  rm -rf "$HOME_DIR/state/.spawn-omp-s3.lock"
  enforced=$((enforced + 1))

  # Row 4: batch dispatch, refused once up front so no pair is ever re-exec'd.
  rec=$(make_omp_case omp-sel-batch claude omp-s4)
  read_case_record "$rec"
  guard_marker="$HOME_DIR/state/.guard-watcher-stale-banner"
  mkdir -p "$HOME_DIR/data/omp-s4b"
  printf 'brief for omp-s4b\n' > "$HOME_DIR/data/omp-s4b/brief.md"
  rows=$((rows + 1))
  arm_ordering_probes omp-s4
  out=$(run_spawn_guarded "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" \
    "omp-s4=$PROJ_DIR" "omp-s4b=$PROJ_DIR" --harness omp --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "a batch selecting omp with no model must be refused: $out"
  assert_contains "$out" "$want_model" "batch shape: $out"
  assert_not_contains "$out" "spawned " "a refused batch must not spawn any pair"
  assert_not_contains "$out" "batch: FAILED" "a refused batch must be refused before any pair is attempted"
  assert_absent "$guard_marker" "batch shape was refused after the watcher guard wrote state"
  assert_absent "$HOME_DIR/state/omp-s4.meta" "batch shape published task metadata"
  assert_absent "$HOME_DIR/state/omp-s4b.meta" "batch shape published task metadata"
  rm -rf "$HOME_DIR/state/.spawn-omp-s4.lock"
  enforced=$((enforced + 1))

  # Rows 5-7: a secondmate is refused on adapter identity ALONE, so the model
  # never changes the verdict - absent, structurally invalid, and fully qualified
  # all land on the same refusal, before every mutation.
  rec=$(make_omp_case omp-sel-secondmate claude omp-s5)
  read_case_record "$rec"
  guard_marker="$HOME_DIR/state/.guard-watcher-stale-banner"
  sub_home="$CASE_DIR/secondmate-home"
  local model_args
  for model_args in "" "--model opus" "--model $OMP_MODEL"; do
    rows=$((rows + 1))
    rm -rf "$sub_home"
    mkdir -p "$sub_home"
    arm_ordering_probes omp-s5
    # shellcheck disable=SC2086  # deliberate word split: the empty case must pass NO model flag at all
    out=$(run_spawn_guarded "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" \
      omp-s5 "$sub_home" --harness omp $model_args --secondmate)
    status=$?
    [ "$status" -ne 0 ] || fail "omp must be refused for a secondmate ('$model_args'): $out"
    assert_contains "$out" "$want_second" "secondmate refusal missing for '$model_args': $out"
    assert_not_contains "$out" "requires an explicit --model" \
      "the secondmate refusal must not depend on the model ('$model_args'): $out"
    assert_not_contains "$out" "another spawn is already creating" \
      "the secondmate refusal must precede task-lock acquisition ('$model_args'): $out"
    assert_absent "$guard_marker" \
      "the secondmate refusal must precede the watcher guard's own state write ('$model_args')"
    assert_absent "$HOME_DIR/state/omp-s5.meta" "refused omp secondmate published task metadata ('$model_args')"
    assert_absent "$HOME_DIR/state/omp-s5.omp-ext.ts" "refused omp secondmate wrote the extension ('$model_args')"
    assert_absent "$HOME_DIR/state/omp-s5.busy-gen" "refused omp secondmate armed a busy contract ('$model_args')"
    assert_absent "$HOME_DIR/data/secondmates.md" "refused omp secondmate touched the registry ('$model_args')"
    assert_absent "$sub_home/config" "refused omp secondmate mutated the secondmate home config ('$model_args')"
    assert_absent "$sub_home/state" "refused omp secondmate mutated the secondmate home state ('$model_args')"
    enforced=$((enforced + 1))
  done
  rm -rf "$HOME_DIR/state/.spawn-omp-s5.lock"

  # Row 8: the negative control. The pin is omp-only, so a claude launch that
  # requested no model must carry no model or provider flag at all, exactly as
  # before.
  rec=$(make_omp_case omp-sel-nonomp claude omp-s8)
  read_case_record "$rec"
  tmux_log="$CASE_DIR/tmux-sends"
  : > "$tmux_log"
  rows=$((rows + 1))
  out=$(FM_TMUX_LOG="$tmux_log" run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" \
    omp-s8 "$PROJ_DIR" --mode no-mistakes --yolo off)
  expect_code 0 $? "default claude spawn should succeed: $out"
  assert_grep 'model=default' "$HOME_DIR/state/omp-s8.meta" \
    "a non-OMP launch that requested no model did not preserve the default model request"
  [ -s "$tmux_log" ] || fail "the non-OMP control did not reach the fake backend"
  assert_not_contains "$(cat "$tmux_log")" "--model" \
    "the non-OMP control unexpectedly received an OMP model flag"
  assert_not_contains "$(cat "$tmux_log")" "--provider" \
    "the non-OMP control unexpectedly received an OMP provider flag"
  enforced=$((enforced + 1))

  # Row 9: an opaque raw launch command must not bypass the named adapter boundary.
  rec=$(make_omp_case omp-sel-raw claude omp-s9)
  read_case_record "$rec"
  guard_marker="$HOME_DIR/state/.guard-watcher-stale-banner"
  rows=$((rows + 1))
  arm_ordering_probes omp-s9
  out=$(run_spawn_guarded "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" \
    omp-s9 "$PROJ_DIR" "omp --approval-mode yolo" --model "$OMP_MODEL" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "an opaque raw launch must be refused: $out"
  assert_contains "$out" "$want_raw" "raw omp shape: $out"
  assert_not_contains "$out" "another spawn is already creating" "raw omp shape reached the task lock: $out"
  assert_absent "$guard_marker" "raw omp shape was refused after the watcher guard wrote state"
  assert_absent "$HOME_DIR/state/omp-s9.meta" "raw omp shape published task metadata"
  assert_absent "$HOME_DIR/state/omp-s9.omp-ext.ts" "raw omp shape wrote the extension"
  assert_absent "$HOME_DIR/state/omp-s9.busy-gen" "raw omp shape armed a busy contract"
  rm -rf "$HOME_DIR/state/.spawn-omp-s9.lock"
  enforced=$((enforced + 1))

  # Row 10: an env-wrapped raw launch has no verifiable adapter identity and is refused.
  rec=$(make_omp_case omp-sel-raw-env claude omp-s10)
  read_case_record "$rec"
  guard_marker="$HOME_DIR/state/.guard-watcher-stale-banner"
  rows=$((rows + 1))
  arm_ordering_probes omp-s10
  out=$(run_spawn_guarded "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" \
    omp-s10 "$PROJ_DIR" "env -u TRACEPARENT FM_TEST=1 omp --approval-mode yolo" \
    --model "$OMP_MODEL" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "an env-wrapped raw launch must be refused: $out"
  assert_contains "$out" "$want_raw" "env-wrapped raw omp shape: $out"
  assert_not_contains "$out" "another spawn is already creating" "env-wrapped raw omp shape reached the task lock: $out"
  assert_absent "$guard_marker" "env-wrapped raw omp shape was refused after the watcher guard wrote state"
  assert_absent "$HOME_DIR/state/omp-s10.meta" "env-wrapped raw omp shape published task metadata"
  assert_absent "$HOME_DIR/state/omp-s10.omp-ext.ts" "env-wrapped raw omp shape wrote the extension"
  assert_absent "$HOME_DIR/state/omp-s10.busy-gen" "env-wrapped raw omp shape armed a busy contract"
  rm -rf "$HOME_DIR/state/.spawn-omp-s10.lock"
  enforced=$((enforced + 1))

  # Row 11: the opaque raw boundary also precedes secondmate provisioning.
  rec=$(make_omp_case omp-sel-raw-secondmate claude omp-s11)
  read_case_record "$rec"
  guard_marker="$HOME_DIR/state/.guard-watcher-stale-banner"
  sub_home="$CASE_DIR/secondmate-home"
  rows=$((rows + 1))
  rm -rf "$sub_home"
  mkdir -p "$sub_home"
  arm_ordering_probes omp-s11
  out=$(run_spawn_guarded "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" \
    omp-s11 "$sub_home" "omp --approval-mode yolo" --secondmate)
  status=$?
  [ "$status" -ne 0 ] || fail "a raw --secondmate launch that names omp must be refused: $out"
  assert_contains "$out" "$want_raw" "raw omp secondmate refusal missing: $out"
  assert_not_contains "$out" "requires an explicit --model" \
    "the raw omp secondmate refusal must not depend on the model: $out"
  assert_not_contains "$out" "another spawn is already creating" \
    "the raw omp secondmate refusal must precede task-lock acquisition: $out"
  assert_absent "$guard_marker" \
    "the raw omp secondmate refusal must precede the watcher guard's own state write"
  assert_absent "$HOME_DIR/state/omp-s11.meta" "raw omp secondmate published task metadata"
  assert_absent "$HOME_DIR/state/omp-s11.omp-ext.ts" "raw omp secondmate wrote the extension"
  assert_absent "$HOME_DIR/state/omp-s11.busy-gen" "raw omp secondmate armed a busy contract"
  assert_absent "$HOME_DIR/data/secondmates.md" "raw omp secondmate touched the registry"
  assert_absent "$sub_home/config" "raw omp secondmate mutated the secondmate home config"
  assert_absent "$sub_home/state" "raw omp secondmate mutated the secondmate home state"
  rm -rf "$HOME_DIR/state/.spawn-omp-s11.lock"
  enforced=$((enforced + 1))

  # Rows 12-15: shell wrappers, compound expressions, and nested argv parsing
  # remain opaque and are refused without inferring an executable identity.
  # The public spawn command must refuse each form before the watcher guard,
  # task lock, metadata publication, or backend submission.
  rows=$((rows + 1))
  assert_raw_launch_refused_before_mutation \
    omp-sel-command-wrapper omp-s12 "command omp --approval-mode yolo" "$want_raw"
  enforced=$((enforced + 1))

  rows=$((rows + 1))
  assert_raw_launch_refused_before_mutation \
    omp-sel-shell-wrapper omp-s13 "sh -c 'omp --approval-mode yolo'" \
    "raw launch command must be one literal command"
  enforced=$((enforced + 1))

  rows=$((rows + 1))
  assert_raw_launch_refused_before_mutation \
    omp-sel-compound omp-s14 "true && omp --approval-mode yolo" \
    "raw launch command must be one literal command"
  enforced=$((enforced + 1))

  rows=$((rows + 1))
  assert_raw_launch_refused_before_mutation \
    omp-sel-env-split omp-s15 "env -Somp --approval-mode yolo" \
    "raw launch command must be one literal command"
  enforced=$((enforced + 1))

  # Row 16: even a raw command that claims no known adapter remains opaque.
  rows=$((rows + 1))
  assert_raw_launch_refused_before_mutation \
    omp-sel-raw-unverified omp-s16 "someunverifiedagent --flag" "$want_raw"
  enforced=$((enforced + 1))

  [ "$rows" -eq 16 ] || fail "the omp selection policy matrix must carry 16 rows, found $rows"
  [ "$enforced" -eq "$rows" ] || fail "omp selection policy matrix: only $enforced/$rows rows enforced"
  printf 'omp selection-policy matrix: %d/%d rows enforced before any mutation\n' "$enforced" "$rows"
  pass "omp selection policy matrix: $enforced/$rows selection shapes enforce the candidate boundary before any mutation"
}

test_opaque_raw_indirection_is_refused() {
  local tools sentinel want case_name id raw target
  tools="$TMP_ROOT/raw-indirection-tools"
  sentinel="$tools/executed"
  want="opaque raw launch commands are disabled because their execution identity cannot be verified"
  mkdir -p "$tools"
  target="$tools/omp-target"
  cat > "$target" <<SH
#!/usr/bin/env bash
touch "$sentinel"
exit 97
SH
  chmod +x "$target"
  ln -s "$target" "$tools/not-omp-symlink"
  cat > "$tools/not-omp-wrapper" <<SH
#!/usr/bin/env bash
touch "$sentinel"
exec "$target" "\$@"
SH
  chmod +x "$tools/not-omp-wrapper"
  cp "$target" "$tools/renamed-agent"
  chmod +x "$tools/renamed-agent"

  for case_name in symlink wrapper renamed; do
    case "$case_name" in
      symlink) raw="$tools/not-omp-symlink --flag" ;;
      wrapper) raw="$tools/not-omp-wrapper --flag" ;;
      renamed) raw="$tools/renamed-agent --flag" ;;
    esac
    id="omp-raw-$case_name"
    rm -f "$sentinel"
    assert_raw_launch_refused_before_mutation "omp-raw-$case_name" "$id" "$raw" "$want"
    assert_absent "$sentinel" "$case_name raw indirection executed before refusal"
  done
  assert_raw_launch_refused_before_mutation \
    omp-raw-tabbed omp-raw-tabbed $'someunverifiedagent\t--flag' \
    "raw launch command must be one literal command"
  pass "opaque raw symlink, wrapper, and renamed executable commands are refused before execution"
}

# --- relaunch ---------------------------------------------------------------

test_relaunch_lifecycle_lock_precedes_watcher_guard() {
  local rec task_id=omp-relaunch-locked out status meta guard_marker lock ready release holder relaunch_wait_attempt
  rec=$(make_omp_case "$task_id" claude "$task_id")
  read_case_record "$rec"
  meta="$HOME_DIR/state/$task_id.meta"
  guard_marker="$HOME_DIR/state/.guard-watcher-stale-banner"
  lock="$HOME_DIR/state/.control-$task_id.lock"
  ready="$CASE_DIR/control-ready"
  release="$CASE_DIR/control-release"
  fm_write_meta "$meta" \
    "window=firstmate:fm-$task_id" "endpoint_task_id=$task_id" \
    "worktree=$WT_DIR" "project=$PROJ_DIR" \
    "harness=omp" "kind=ship" "mode=no-mistakes" "yolo=off"
  rm -f "$HOME_DIR/state/.last-watcher-beat" "$guard_marker"
  printf 'window=fm-decoy\nharness=claude\n' > "$HOME_DIR/state/decoy.meta"
  (
    . "$ROOT/bin/fm-wake-lib.sh"
    fm_lock_try_acquire "$lock" || exit 1
    : > "$ready"
    while [ ! -e "$release" ]; do /bin/sleep 0.01; done
    fm_lock_release "$lock"
  ) &
  holder=$!
  relaunch_wait_attempt=0
  while [ ! -e "$ready" ] && [ "$relaunch_wait_attempt" -lt 200 ]; do
    /bin/sleep 0.01
    relaunch_wait_attempt=$((relaunch_wait_attempt + 1))
  done
  [ -e "$ready" ] || { kill "$holder" 2>/dev/null || true; fail "could not stage the relaunch lifecycle lock"; }
  out=$(run_spawn_guarded "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" \
    "$task_id" --relaunch --model "$OMP_MODEL")
  status=$?
  : > "$release"
  wait "$holder" || fail "relaunch lifecycle lock holder failed"
  [ "$status" -ne 0 ] || fail "a relaunch should refuse a concurrent lifecycle owner: $out"
  assert_contains "$out" "another lifecycle action is already running" \
    "contended relaunch did not report the lifecycle owner: $out"
  assert_absent "$guard_marker" "contended relaunch mutated watcher state before lifecycle serialization"
  pass "fm-spawn relaunch: lifecycle serialization precedes watcher-state mutation"
}


test_omp_relaunch_still_requires_the_model() {
  local rec id=omp-relaunch out status meta omp_log
  rec=$(make_omp_case omp-relaunch claude "$id")
  read_case_record "$rec"
  meta="$HOME_DIR/state/$id.meta"
  omp_log="$CASE_DIR/omp-relaunch-invocations"
  : > "$omp_log"
  fm_write_meta "$meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" "worktree=$WT_DIR" "project=$PROJ_DIR" \
    "harness=omp" "kind=ship" "mode=no-mistakes" "yolo=off"
  out=$(FM_FAKE_WINDOW="fm-$id" FM_FAKE_COMMAND=zsh FM_OMP_STUB_LOG="$omp_log" \
    run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" --relaunch --model "$OMP_MODEL")
  status=$?
  [ "$status" -ne 0 ] || fail "an implicit relaunch of an omp task must be refused: $out"
  assert_contains "$out" "every omp spawn and relaunch requires an explicit --harness omp" \
    "the implicit relaunch refusal did not require caller-explicit selection: $out"
  [ ! -s "$omp_log" ] || fail "an implicit OMP relaunch reached the candidate executable probe"
  assert_absent "$HOME_DIR/state/$id.omp-ext.ts" "an implicit refused relaunch wrote the extension"

  out=$(FM_FAKE_WINDOW="fm-$id" FM_FAKE_COMMAND=zsh \
    run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" --relaunch)
  status=$?
  [ "$status" -ne 0 ] || fail "a relaunch of an omp task with no model must be refused: $out"
  assert_contains "$out" "every omp spawn and relaunch requires an explicit --harness omp" \
    "a relaunch without caller-explicit OMP selection reached the model gate: $out"

  out=$(FM_FAKE_WINDOW="fm-$id" FM_FAKE_COMMAND=zsh \
    run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" --relaunch --harness omp)
  status=$?
  [ "$status" -ne 0 ] || fail "an explicit relaunch of an omp task with no model must be refused: $out"
  assert_contains "$out" "omp requires an explicit --model" \
    "the explicit relaunch refusal did not name the launch pin: $out"
  assert_absent "$HOME_DIR/state/$id.omp-ext.ts" "a refused relaunch must not write the extension"

  # A complete tmux record passes the metadata and adapter-shape checks but may
  # not proceed past the unverified candidate gates.
  fm_write_meta "$meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" \
    "worktree=$WT_DIR" "project=$PROJ_DIR" \
    "harness=omp" "kind=ship" "mode=no-mistakes" "yolo=off"
  out=$(FM_FAKE_WINDOW="fm-$id" FM_FAKE_COMMAND=zsh \
    run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" \
    "$id" --relaunch --harness omp --model "$OMP_MODEL")
  status=$?
  [ "$status" -ne 0 ] || fail "an OMP relaunch must retain its recovery-grade endpoint gate: $out"
  assert_contains "$out" "session-free omp/17.2.9 consumer" \
    "a valid OMP record did not stop at both mandatory gates: $out"
  pass "an OMP relaunch requires explicit selection and remains dormant"
}

# --- busy-state trust table ------------------------------------------------

test_omp_semantic_source_remains_untrusted() {
  local trusted out state id=omp-untrusted
  trusted=$(fm_busy_sources_for_harness omp)
  [ -z "$trusted" ] || fail "omp must trust no semantic source before both mandatory proofs, got '$trusted'"
  ! fm_busy_source_trusted omp omp-ext || fail "omp-ext must remain untrusted before consumer and lifecycle proofs"
  ! fm_busy_source_trusted omp pi-ext || fail "pi-ext must not be trusted for omp"
  ! fm_busy_source_trusted pi omp-ext || fail "omp-ext must not be trusted for pi"
  state="$TMP_ROOT/omp-untrusted-state"
  mkdir -p "$state"
  out=$(fm_busy_classify tmux fake:w omp "$id" "$state" 'idle')
  [ "$out" = "unknown missing" ] \
    || fail "unverified OMP must classify unknown, got '$out'"
  pass "OMP semantic events remain untrusted pending both mandatory proofs"
}


test_omp_manifest_routes_agent_tools_away_from_captain_claude_tools() {
  local captain_home captain_tools manifest
  captain_home="$TMP_ROOT/captain-home"
  captain_tools="$captain_home/.claude/tools"
  mkdir -p "$captain_tools"
  printf '%s\n' 'captain-only' > "$captain_tools/agent-secrets-collect.py"
  printf '%s\n' 'captain-only' > "$captain_tools/rotate-pending-keys.sh"
  manifest=$(HOME="$captain_home" "$ROOT/bin/fm-omp-candidate-artifacts.sh" manifest \
    /firstmate/isolated-agent /firstmate/isolated-cwd /opt/omp "$OMP_MODEL" \
    /state/task.omp-ext.ts) || fail "candidate OMP manifest did not render"
  MANIFEST=$manifest CAPTAIN_TOOLS=$captain_tools node <<'NODE' \
    || fail "candidate OMP manifest inherited the captain Claude tools directory"
const manifest = JSON.parse(process.env.MANIFEST);
const expectedAgentDirectory = "/firstmate/isolated-agent";
const expectedToolSurface = "/firstmate/isolated-agent/tools";
const captainToolsDirectory = process.env.CAPTAIN_TOOLS;
const renderedToolSurface = `${manifest.environment.PI_CODING_AGENT_DIR}/tools`;
if (manifest.environment.PI_CODING_AGENT_DIR !== expectedAgentDirectory) process.exit(1);
if (renderedToolSurface !== expectedToolSurface) process.exit(1);
const rendered = JSON.stringify(manifest);
if (rendered.includes(captainToolsDirectory)) process.exit(1);
if (rendered.includes("agent-secrets-collect.py")) process.exit(1);
if (rendered.includes("rotate-pending-keys.sh")) process.exit(1);
NODE
  pass "OMP candidate manifest routes agent tools away from the captain Claude tools directory"
}

make_refusal_case() {
  local name=$1 configured=${2:-} case_dir home fakebin sentinel
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  sentinel="$case_dir/candidate-executed"
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" "$configured"
  cat > "$fakebin/omp" <<'SH'
#!/usr/bin/env bash
printf 'executed\n' >> "${FM_OMP_EXECUTION_SENTINEL:?}"
exit 97
SH
  chmod +x "$fakebin/omp"
  printf '%s|%s|%s\n' "$home" "$fakebin" "$sentinel"
}

run_spawn_refusal() {
  local name=$1 configured=$2 expected=$3 record home fakebin sentinel out status
  shift 3
  record=$(make_refusal_case "$name" "$configured")
  IFS='|' read -r home fakebin sentinel <<EOF
$record
EOF
  out=$(FM_OMP_EXECUTION_SENTINEL="$sentinel" \
    fm_test_run_spawn "$home" /not-a-pane "$fakebin" "$@" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "$name unexpectedly dispatched the candidate"
  assert_contains "$out" "$expected" "$name did not reach the expected refusal: $out"
  assert_absent "$sentinel" "$name executed the candidate"
  if find "$home/state" -maxdepth 1 -name '*.meta' -print -quit | grep -q .; then
    fail "$name published task metadata before refusing"
  fi
}

test_spawn_policy_matrix_stays_dormant_and_tmux_only() {
  run_spawn_refusal explicit-dormant '' 'session-free omp/17.2.9 consumer'     task-explicit /not-a-project --harness omp --model "$OMP_MODEL"     --backend tmux --mode no-mistakes --yolo off
  run_spawn_refusal orca-refusal '' 'requires backend=tmux'     task-orca /not-a-project --harness omp --model "$OMP_MODEL"     --backend orca --mode no-mistakes --yolo off
  run_spawn_refusal missing-model '' 'requires an explicit --model'     task-missing /not-a-project --harness omp --backend tmux     --mode no-mistakes --yolo off
  run_spawn_refusal malformed-model '' 'must be exactly'     task-malformed /not-a-project --harness omp --model model-only     --backend tmux --mode no-mistakes --yolo off
  run_spawn_refusal positional '' 'requires an explicit --harness omp'     task-positional /not-a-project omp --model "$OMP_MODEL"     --backend tmux --mode no-mistakes --yolo off
  run_spawn_refusal configured omp 'requires an explicit --harness omp'     task-configured /not-a-project --model "$OMP_MODEL"     --backend tmux --mode no-mistakes --yolo off
  run_spawn_refusal raw '' 'opaque raw launch commands are disabled'     task-raw /not-a-project 'env omp --version' --model "$OMP_MODEL"     --backend tmux --mode no-mistakes --yolo off
  run_spawn_refusal secondmate '' 'candidate crewmate/scout adapter only'     task-secondmate --secondmate --harness omp --model "$OMP_MODEL"     --backend tmux
  pass "OMP selection, model, backend, role, and dormancy gates refuse without execution"
}

# Every test function in the reviewed source snapshot must remain present here or
# have a named waiver with a non-empty reason. There are no waivers in this port.
omp_source_test_waiver_reason() {
  case "$1" in
    test_effective_crew_selection_snapshot_is_immutable)
      printf '%s' 'c5eb801b removed the frozen crew-selection snapshot and its deterministic post-snapshot mutation seam; batch children now re-resolve through the single-task entrypoint'
      ;;
    test_dispatch_presence_snapshot_cannot_disappear_into_omp)
      printf '%s' 'c5eb801b checks dispatch-profile presence directly and has no captured dispatch-presence snapshot or post-snapshot mutation seam'
      ;;
    test_relaunch_detects_a_path_swap_while_binding_the_snapshot)
      printf '%s' 'c5eb801b replaced the dual-file-descriptor immutable relaunch snapshot algorithm with locked record validation'
      ;;
    test_relaunch_rejects_unsafe_metadata_before_every_mutation)
      printf '%s' 'c5eb801b acquires the relaunch lifecycle lock before validating the locked metadata record, replacing the source test contract that refusal precedes every mutation'
      ;;
    test_no_submit_refuses_nonomp_relaunch_before_endpoint_interaction)
      printf '%s' 'c5eb801b removed the FD-bound tests/fm-spawn-no-submit.sh interface that this test exclusively targets'
      ;;
    *) return 1 ;;
  esac
}

test_source_test_name_coverage_floor() {
  local source_commit source_path current_path source_names current_names name reason missing=0
  source_commit=fc290ae762e8d85262337395adaaab0392946546
  source_path=tests/fm-omp-harness.test.sh
  current_path=${FM_OMP_COVERAGE_SUITE_PATH:-${BASH_SOURCE[0]}}
  source_names=$(/usr/bin/git -C "$ROOT" show "$source_commit:$source_path" \
    | sed -n 's/^\(test_[A-Za-z0-9_]*\)() {.*/\1/p' | LC_ALL=C sort -u) \
    || fail "could not read source test names from $source_commit:$source_path"
  if [ "${FM_OMP_COVERAGE_CURRENT_NAMES+x}" = x ]; then
    current_names=$FM_OMP_COVERAGE_CURRENT_NAMES
  else
    current_names=$(sed -n 's/^\(test_[A-Za-z0-9_]*\)() {.*/\1/p' "$current_path" | LC_ALL=C sort -u) \
      || fail "could not read restored test names from $current_path"
  fi
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    if printf '%s\n' "$current_names" | grep -qxF "$name"; then
      continue
    fi
    reason=
    if reason=$(omp_source_test_waiver_reason "$name"); then
      [ -n "$reason" ] || fail "source test waiver for $name has no reason"
      printf 'waived source test: %s - %s\n' "$name" "$reason"
      continue
    fi
    echo "missing source test without waiver: $name" >&2
    missing=1
  done <<EOF
$source_names
EOF
  [ "$missing" -eq 0 ] || fail "source test-name coverage floor failed"
  pass "every reviewed source test name is restored or explicitly waived"
}

if [ "${FM_OMP_COVERAGE_ONLY:-0}" = 1 ]; then
  test_source_test_name_coverage_floor
  exit 0
fi

test_source_test_name_coverage_floor
test_omp_token_is_not_normalized_to_pi
test_omp_is_unreachable_without_explicit_selection
test_omp_dormancy_never_resolves_or_executes_candidate
test_omp_launch_request_is_rendered
test_omp_manifest_routes_agent_tools_away_from_captain_claude_tools
test_omp_consumer_proof_gate_never_executes_candidate
test_omp_candidate_artifacts_render_requested_settings_and_handle_continuation
test_ordering_probes_are_live
test_omp_model_policy_matrix
test_omp_selection_policy_matrix
test_opaque_raw_indirection_is_refused
test_relaunch_lifecycle_lock_precedes_watcher_guard
test_omp_relaunch_still_requires_the_model
test_omp_semantic_source_remains_untrusted
test_spawn_policy_matrix_stays_dormant_and_tmux_only

echo "all fm-omp-harness tests passed"
