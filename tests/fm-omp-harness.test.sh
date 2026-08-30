#!/usr/bin/env bash
# tests/fm-omp-harness.test.sh - removed-adapter safety regression.
#
# The OMP adapter no longer exists. This test drives fm-spawn's public harness
# selection interface and proves an explicit OMP name takes the generic unknown
# harness path without executing a caller-selected command or mutating state.
set -u

ROOT=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-omp-harness)
trap 'rm -rf "$TMP_ROOT"' EXIT

case_dir="$TMP_ROOT/unknown-harness"
home="$case_dir/home"
sentinel="$case_dir/omp-executed"
mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects" "$case_dir/fakebin"
cat > "$case_dir/fakebin/omp" <<'SH'
#!/usr/bin/env bash
printf 'executed\n' >> "${FM_OMP_EXECUTION_SENTINEL:?}"
exit 97
SH
chmod +x "$case_dir/fakebin/omp"

set +e
out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
  FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
  FM_PROJECTS_OVERRIDE="$home/projects" FM_SPAWN_NO_GUARD=1 \
  FM_OMP_EXECUTION_SENTINEL="$sentinel" PATH="$case_dir/fakebin:$PATH" \
  "$SPAWN" task-unknown /not-a-project --harness omp \
  --mode no-mistakes --yolo off 2>&1)
rc=$?
set -e

[ "$rc" -ne 0 ] || fail "explicit --harness omp unexpectedly launched"
assert_contains "$out" "error: unknown harness 'omp'" \
  "explicit --harness omp did not use the generic unknown-harness refusal"
[ ! -e "$sentinel" ] || fail "generic unknown-harness refusal executed OMP"
[ -z "$(find "$home/state" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ] \
  || fail "generic unknown-harness refusal mutated task state"
pass "removed OMP adapter: explicit --harness omp uses generic unknown-harness refusal"

printf 'OMP adapter deletion safety test passed\n'
