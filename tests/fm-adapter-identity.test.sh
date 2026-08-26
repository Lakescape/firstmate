#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-adapter-identity)

make_case() {
  local name=$1 case_dir="$TMP_ROOT/$1" home="$TMP_ROOT/$1/home"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects" "$case_dir/project"
  printf '%s\n' claude > "$home/config/crew-harness"
  printf '%s\n' "$case_dir|$home"
}

run_refusal() {
  local name=$1 fakebin=$2 sentinel=$3 record case_dir home out rc
  record=$(make_case "$name")
  IFS='|' read -r case_dir home <<EOF
$record
EOF
  set +e
  out=$(env -u FM_ADAPTER_IDENTITY_TEST_BYPASS \
    PATH="$fakebin:/usr/bin:/bin:/usr/sbin:/sbin" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_PROJECTS_OVERRIDE="$home/projects" \
    FM_CONFIG_OVERRIDE="$home/config" \
    "$SPAWN" "$name" "$case_dir/project" --harness claude \
      --mode no-mistakes --yolo off 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "$name executable identity was accepted: $out"
  assert_contains "$out" "no portable immutable executable-identity binding" \
    "$name refusal did not name the missing identity boundary"
  assert_absent "$sentinel" "$name fixture executed before identity refusal"
  assert_absent "$home/state/$name.meta" "$name refusal published metadata"
  assert_absent "$home/state/.spawn-$name.lock" "$name refusal acquired the task lock"
  assert_absent "$home/state/.guard-watcher-stale-banner" "$name refusal ran the watcher guard"
}

test_named_adapter_indirection_is_fail_closed() {
  local fixtures="$TMP_ROOT/fixtures" payload="$TMP_ROOT/omp-payload" fakebin sentinel
  mkdir -p "$fixtures"
  cat > "$payload" <<'SH'
#!/usr/bin/env bash
printf 'executed\n' > "${FM_ADAPTER_SENTINEL:?}"
exit 97
SH
  chmod +x "$payload"

  fakebin="$fixtures/path-first"
  sentinel="$fixtures/path-first.executed"
  mkdir -p "$fakebin"
  cat > "$fakebin/claude" <<SH
#!/usr/bin/env bash
FM_ADAPTER_SENTINEL='$sentinel' exec '$payload' "\$@"
SH
  chmod +x "$fakebin/claude"
  run_refusal path-first-wrapper "$fakebin" "$sentinel"

  fakebin="$fixtures/symlink"
  sentinel="$fixtures/symlink.executed"
  mkdir -p "$fakebin"
  ln -s "$payload" "$fakebin/claude"
  FM_ADAPTER_SENTINEL="$sentinel" run_refusal symlink-adapter "$fakebin" "$sentinel"

  fakebin="$fixtures/renamed"
  sentinel="$fixtures/renamed.executed"
  mkdir -p "$fakebin"
  cp "$payload" "$fakebin/claude"
  chmod +x "$fakebin/claude"
  FM_ADAPTER_SENTINEL="$sentinel" run_refusal renamed-executable "$fakebin" "$sentinel"

  fakebin="$fixtures/alternate"
  sentinel="$fixtures/alternate.executed"
  mkdir -p "$fakebin"
  cat > "$fakebin/not-omp" <<SH
#!/usr/bin/env bash
FM_ADAPTER_SENTINEL='$sentinel' exec '$payload' "\$@"
SH
  cat > "$fakebin/claude" <<SH
#!/usr/bin/env bash
exec '$fakebin/not-omp' "\$@"
SH
  chmod +x "$fakebin/not-omp" "$fakebin/claude"
  run_refusal alternate-wrapper-chain "$fakebin" "$sentinel"

  fakebin="$fixtures/native-name"
  sentinel="$fixtures/native-name.executed"
  mkdir -p "$fakebin"
  cp /usr/bin/true "$fakebin/claude"
  chmod +x "$fakebin/claude"
  run_refusal unproven-native-name "$fakebin" "$sentinel"

  pass "named adapters refuse PATH, symlink, wrapper, renamed, and name-only identities before mutation"
}

test_shell_alias_cannot_reach_submission() {
  local record case_dir home fakebin sentinel bash_env out rc
  record=$(make_case shell-alias)
  IFS='|' read -r case_dir home <<EOF
$record
EOF
  fakebin="$case_dir/fakebin"
  sentinel="$case_dir/alias.executed"
  bash_env="$case_dir/bash-env"
  mkdir -p "$fakebin"
  cat > "$bash_env" <<SH
claude() { printf 'executed\\n' > '$sentinel'; }
export -f claude
SH
  set +e
  out=$(env -u FM_ADAPTER_IDENTITY_TEST_BYPASS BASH_ENV="$bash_env" \
    PATH="$fakebin:/usr/bin:/bin:/usr/sbin:/sbin" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_PROJECTS_OVERRIDE="$home/projects" \
    FM_CONFIG_OVERRIDE="$home/config" \
    "$SPAWN" shell-alias "$case_dir/project" --harness claude \
      --mode no-mistakes --yolo off 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "shell alias identity was accepted: $out"
  assert_contains "$out" "no portable immutable executable-identity binding" \
    "shell alias refusal did not name the missing identity boundary"
  assert_absent "$sentinel" "shell alias executed before identity refusal"
  assert_absent "$home/state/shell-alias.meta" "shell alias refusal published metadata"
  pass "shell aliases cannot cross the named-adapter execution boundary"
}

test_named_adapter_indirection_is_fail_closed
test_shell_alias_cannot_reach_submission

echo "all fm-adapter-identity tests passed"
