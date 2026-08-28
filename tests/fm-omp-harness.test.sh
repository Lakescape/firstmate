#!/usr/bin/env bash
# tests/fm-omp-harness.test.sh - inert OMP review-artifact regressions.
#
# No test in this file installs, resolves, probes, or executes OMP, another
# adapter, or a provider. An observable fake named omp is placed first on PATH
# and every assertion requires it to remain unexecuted.
set -u

ROOT=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
ARTIFACT="$ROOT/bin/fm-omp-candidate-artifacts.sh"
TMP_ROOT=$(fm_test_tmproot fm-omp-harness)
trap 'rm -rf "$TMP_ROOT"' EXIT

make_probe_path() {  # <case-dir>
  local case_dir=$1 fakebin="$1/fakebin"
  mkdir -p "$fakebin"
  cat > "$fakebin/omp" <<'SH'
#!/usr/bin/env bash
printf 'executed\n' >> "${FM_OMP_EXECUTION_SENTINEL:?}"
exit 97
SH
  chmod +x "$fakebin/omp"
  printf '%s\n' "$fakebin"
}

assert_probe_inert() {  # <sentinel> <context>
  [ ! -e "$1" ] || fail "$2 executed the caller-selected OMP probe"
}

run_spawn_refusal() {  # <name> <spawn arguments...>
  local name=$1 case_dir home fakebin sentinel out rc
  shift
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  sentinel="$case_dir/omp-executed"
  fakebin=$(make_probe_path "$case_dir")
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_SPAWN_NO_GUARD=1 \
    FM_OMP_EXECUTION_SENTINEL="$sentinel" PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "$name unexpectedly dispatched OMP"
  assert_contains "$out" "omp is an inert, non-dispatchable review artifact" \
    "$name did not reach the unconditional inert-artifact refusal"
  assert_probe_inert "$sentinel" "$name"
  [ -z "$(find "$home/state" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ] \
    || fail "$name mutated task state before refusing OMP"
}

test_requested_manifest_is_static_and_accepts_no_dispatch_input() {
  local case_dir fakebin sentinel manifest out rc
  case_dir="$TMP_ROOT/manifest"
  sentinel="$case_dir/omp-executed"
  fakebin=$(make_probe_path "$case_dir")
  manifest=$(FM_OMP_EXECUTION_SENTINEL="$sentinel" PATH="$fakebin:$PATH" \
    "$BASH" "$ARTIFACT" requested-manifest) \
    || fail "the inert requested manifest did not render"
  assert_contains "$manifest" '"artifactStatus":"inert-non-dispatchable"' \
    "the manifest did not identify its inert status"
  assert_contains "$manifest" '"dispatchable":false' \
    "the manifest did not refuse dispatchability"
  assert_contains "$manifest" '"effectiveBehaviorProven":false' \
    "the manifest claimed effective consumer behavior"
  assert_contains "$manifest" '"<unresolved-omp-executable>"' \
    "the manifest replaced the review placeholder with an executable"
  assert_contains "$manifest" '"followUpRequired"' \
    "the manifest did not preserve the separately scoped runnable boundaries"
  assert_probe_inert "$sentinel" "requested-manifest"

  out=$(FM_OMP_EXECUTION_SENTINEL="$sentinel" PATH="$fakebin:$PATH" \
    "$BASH" "$ARTIFACT" requested-manifest "$fakebin/omp" 2>&1)
  rc=$?
  [ "$rc" -eq 2 ] || fail "the renderer accepted a caller executable argument: $out"
  assert_probe_inert "$sentinel" "caller executable rejection"

  out=$(FM_OMP_EXECUTION_SENTINEL="$sentinel" PATH="$fakebin:$PATH" \
    "$BASH" "$ARTIFACT" requested-manifest /dev/fd/9 2>&1)
  rc=$?
  [ "$rc" -eq 2 ] || fail "the renderer accepted a caller file-descriptor argument: $out"
  assert_probe_inert "$sentinel" "caller file-descriptor rejection"
  pass "OMP requested manifest is static and accepts no dispatch input"
}

test_every_fresh_selection_shape_refuses_without_execution() {
  local configured_home
  run_spawn_refusal explicit task-explicit /not-a-project \
    --harness omp --model provider/model --backend orca --mode no-mistakes --yolo off
  run_spawn_refusal positional task-positional /not-a-project omp \
    --mode no-mistakes --yolo off
  run_spawn_refusal raw task-raw /not-a-project 'env omp --version' \
    --mode no-mistakes --yolo off
  run_spawn_refusal batch task-batch=/not-a-project \
    --harness omp --mode no-mistakes --yolo off
  run_spawn_refusal secondmate task-secondmate --secondmate --harness omp

  configured_home="$TMP_ROOT/configured/home"
  mkdir -p "$configured_home/config"
  printf 'omp\n' > "$configured_home/config/crew-harness"
  run_spawn_refusal configured task-configured /not-a-project \
    --mode no-mistakes --yolo off
  pass "every fresh OMP selection shape refuses before executable or state access"
}

test_relaunch_selection_refuses_without_execution_or_record_change() {
  local case_dir home fakebin sentinel meta before out rc
  case_dir="$TMP_ROOT/relaunch"
  home="$case_dir/home"
  sentinel="$case_dir/omp-executed"
  fakebin=$(make_probe_path "$case_dir")
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  meta="$home/state/task-relaunch.meta"
  cat > "$meta" <<EOF
window=fake-target
endpoint_task_id=task-relaunch
worktree=$case_dir/worktree
project=$case_dir/project
harness=omp
kind=ship
mode=no-mistakes
yolo=off
model=default
effort=default
backend=tmux
EOF
  before=$(<"$meta")
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_SPAWN_NO_GUARD=1 \
    FM_OMP_EXECUTION_SENTINEL="$sentinel" PATH="$fakebin:$PATH" \
    "$SPAWN" --relaunch task-relaunch 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "an OMP relaunch unexpectedly dispatched"
  assert_contains "$out" "omp is an inert, non-dispatchable review artifact" \
    "the OMP relaunch did not reach the inert refusal"
  [ "$(<"$meta")" = "$before" ] || fail "the OMP relaunch changed its durable record"
  assert_probe_inert "$sentinel" "relaunch"
  pass "OMP relaunch refuses without executable access or metadata change"
}

test_requested_manifest_is_static_and_accepts_no_dispatch_input
test_every_fresh_selection_shape_refuses_without_execution
test_relaunch_selection_refuses_without_execution_or_record_change

printf 'all omp inert-artifact tests passed\n'
