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

arm_ordering_probes() {
  local home=$1 id=$2
  rm -f "$home/state/.last-watcher-beat" "$home/state/.guard-watcher-stale-banner"
  printf 'window=fm-decoy\nharness=claude\n' > "$home/state/decoy.meta"
  mkdir -p "$home/state/.spawn-$id.lock"
  printf '%s\n' "$$" > "$home/state/.spawn-$id.lock/pid"
}

run_refusal() {
  local name=$1 fakebin=$2 sentinel=$3 record case_dir home out rc
  record=$(make_case "$name")
  IFS='|' read -r case_dir home <<EOF
$record
EOF
  arm_ordering_probes "$home" "$name"
  set +e
  out=$(env \
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
  assert_not_contains "$out" "another spawn is already creating" \
    "$name identity refusal reached task-lock acquisition"
  assert_absent "$sentinel" "$name fixture executed before identity refusal"
  assert_absent "$home/state/$name.meta" "$name refusal published metadata"
  assert_present "$home/state/.spawn-$name.lock" "$name refusal removed the held task lock"
  assert_absent "$home/state/.guard-watcher-stale-banner" "$name refusal ran the watcher guard"
  rm -rf "$home/state/.spawn-$name.lock"
}

test_ordering_probes_are_live_without_submission() {
  local record case_dir home fakebin sentinel out rc id=identity-order-control
  record=$(make_case "$id")
  IFS='|' read -r case_dir home <<EOF
$record
EOF
  fakebin="$case_dir/fakebin"
  sentinel="$case_dir/adapter-executed"
  mkdir -p "$fakebin"
  cat > "$fakebin/claude" <<SH
#!/usr/bin/env bash
printf 'executed\n' > '$sentinel'
exit 97
SH
  chmod +x "$fakebin/claude"
  arm_ordering_probes "$home" "$id"
  set +e
  out=$(PATH="$fakebin:/usr/bin:/bin:/usr/sbin:/sbin" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_PROJECTS_OVERRIDE="$home/projects" \
    FM_CONFIG_OVERRIDE="$home/config" \
    "$ROOT/tests/fm-spawn-no-submit.sh" "$id" "$case_dir/project" \
      --harness claude --mode no-mistakes --yolo off 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "the held task lock did not refuse the positive control: $out"
  assert_contains "$out" "another spawn is already creating task $id" \
    "the positive control did not reach task-lock acquisition"
  assert_present "$home/state/.guard-watcher-stale-banner" \
    "the positive control did not run the watcher guard"
  assert_absent "$sentinel" "the no-submit positive control executed the adapter"
  rm -rf "$home/state/.spawn-$id.lock"
  pass "identity-order probes fire through the inert no-submit boundary"
}

test_no_submit_ignores_path_backend_and_adapter() {
  local record case_dir home fakebin worktree backend_sentinel adapter_sentinel out
  local id=identity-no-submit-control
  record=$(make_case "$id")
  IFS='|' read -r case_dir home <<EOF
$record
EOF
  fakebin="$case_dir/fakebin"
  worktree="$case_dir/worktree"
  backend_sentinel="$case_dir/backend-executed"
  adapter_sentinel="$case_dir/adapter-executed"
  mkdir -p "$fakebin" "$home/data/$id"
  printf 'brief\n' > "$home/data/$id/brief.md"
  fm_git_worktree "$case_dir/project" "$worktree" "fm/$id"
  cat > "$fakebin/tmux" <<SH
#!/bin/sh
printf 'executed\n' > '$backend_sentinel'
exit 97
SH
  cat > "$fakebin/claude" <<SH
#!/bin/sh
printf 'executed\n' > '$adapter_sentinel'
exit 97
SH
  chmod +x "$fakebin/tmux" "$fakebin/claude"
  out=$(PATH="$fakebin:/usr/bin:/bin:/usr/sbin:/sbin" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_PROJECTS_OVERRIDE="$home/projects" \
    FM_CONFIG_OVERRIDE="$home/config" FM_SPAWN_NO_GUARD=1 \
    FM_SPAWN_TEST_NO_SUBMIT_WORKTREE="$worktree" FM_FAKE_PANE_PATH="$worktree" \
    "$ROOT/tests/fm-spawn-no-submit.sh" "$id" "$case_dir/project" \
      --harness claude --backend tmux --mode no-mistakes --yolo off 2>&1)
  assert_contains "$out" "no-submit=true" "the inert control did not complete"
  assert_absent "$backend_sentinel" "the no-submit seam executed a PATH-selected backend"
  assert_absent "$adapter_sentinel" "the no-submit seam executed a PATH-selected adapter"
  assert_present "$home/state/$id.meta" "the inert control did not publish fixture metadata"
  pass "no-submit binds an inert backend and never executes PATH adapters"
}

test_no_submit_refuses_unbound_backend() {
  local record case_dir home fakebin sentinel out rc id=identity-unbound-backend
  record=$(make_case "$id")
  IFS='|' read -r case_dir home <<EOF
$record
EOF
  fakebin="$case_dir/fakebin"
  sentinel="$case_dir/zellij-executed"
  mkdir -p "$fakebin"
  cat > "$fakebin/zellij" <<SH
#!/bin/sh
printf 'executed\n' > '$sentinel'
exit 97
SH
  chmod +x "$fakebin/zellij"
  set +e
  out=$(PATH="$fakebin:/usr/bin:/bin:/usr/sbin:/sbin" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_PROJECTS_OVERRIDE="$home/projects" \
    FM_CONFIG_OVERRIDE="$home/config" FM_SPAWN_NO_GUARD=1 \
    "$ROOT/tests/fm-spawn-no-submit.sh" "$id" "$case_dir/project" \
      --harness claude --backend zellij --mode no-mistakes --yolo off 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "the no-submit seam accepted an unbound backend: $out"
  assert_contains "$out" "refuses an unbound backend 'zellij'" \
    "the unbound backend refusal was not explicit"
  assert_absent "$sentinel" "the no-submit seam executed an unbound backend"
  assert_absent "$home/state/$id.meta" "the unbound backend refusal published metadata"
  pass "no-submit refuses every backend without a hermetic binding"
}

test_no_submit_refuses_untrusted_herdr_capability() {
  local record case_dir home payload sentinel out rc id=identity-untrusted-herdr
  record=$(make_case "$id")
  IFS='|' read -r case_dir home <<EOF
$record
EOF
  payload="$case_dir/herdr"
  sentinel="$case_dir/herdr-executed"
  cat > "$payload" <<SH
#!/bin/sh
printf 'executed\n' > '$sentinel'
exit 97
SH
  chmod +x "$payload"
  exec 4< "$payload"
  set +e
  out=$(FM_SPAWN_TEST_NO_SUBMIT_HERDR_FD=4 \
    FM_SPAWN_TEST_NO_SUBMIT_HERDR_PATH="$payload" HERDR_SESSION=fm-lab-untrusted \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_PROJECTS_OVERRIDE="$home/projects" \
    FM_CONFIG_OVERRIDE="$home/config" FM_SPAWN_NO_GUARD=1 \
    "$ROOT/tests/fm-spawn-no-submit.sh" "$id" "$case_dir/project" \
      --harness claude --backend herdr --mode no-mistakes --yolo off 2>&1)
  rc=$?
  set -e
  exec 4<&-
  [ "$rc" -ne 0 ] || fail "the no-submit seam accepted an unauthenticated Herdr executable: $out"
  assert_absent "$sentinel" "the no-submit seam executed an unauthenticated Herdr executable"
  assert_absent "$home/state/$id.meta" "the unauthenticated Herdr refusal published metadata"
  pass "no-submit rejects caller-bound Herdr without the test safety owner"
}

test_no_submit_seals_path_and_parses_fake_orca_internally() {
  local record case_dir home fakebin worktree responses log out tool id=identity-sealed-path
  record=$(make_case "$id")
  IFS='|' read -r case_dir home <<EOF
$record
EOF
  fakebin="$case_dir/fakebin"
  worktree="$case_dir/worktree"
  responses="$case_dir/responses"
  log="$case_dir/orca.log"
  mkdir -p "$fakebin" "$responses" "$home/data/$id"
  : > "$log"
  printf 'brief\n' > "$home/data/$id/brief.md"
  fm_git_worktree "$case_dir/project" "$worktree" "fm/$id"
  printf '{"ok":true,"result":{"repo":{"id":"verified-nonexistent-repo-sealed-path"}}}\n' \
    > "$responses/1.out"
  printf '{"ok":true,"result":{"worktree":{"id":"verified-nonexistent-worktree-sealed-path","path":"%s"},"terminal":{"handle":"verified-nonexistent-terminal-sealed-path"}}}\n' \
    "$worktree" > "$responses/2.out"
  for tool in node orca git sed awk grep date mkdir mv ln rm cat dirname basename; do
    cat > "$fakebin/$tool" <<SH
#!/bin/sh
printf 'executed\n' > '$case_dir/$tool.executed'
exit 97
SH
    chmod +x "$fakebin/$tool"
  done
  out=$(PATH="$fakebin:/usr/bin:/bin:/usr/sbin:/sbin" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_PROJECTS_OVERRIDE="$home/projects" \
    FM_CONFIG_OVERRIDE="$home/config" FM_SPAWN_NO_GUARD=1 \
    FM_ORCA_LOG="$log" FM_ORCA_RESPONSES="$responses" \
    "$ROOT/tests/fm-spawn-no-submit.sh" "$id" "$case_dir/project" \
      --harness claude --backend orca --mode no-mistakes --yolo off 2>&1)
  assert_contains "$out" "no-submit=true" "the sealed Orca control did not complete"
  for tool in node orca git sed awk grep date mkdir mv ln rm cat dirname basename; do
    assert_absent "$case_dir/$tool.executed" \
      "the no-submit seam executed the caller's PATH-selected $tool"
  done
  assert_present "$home/state/$id.meta" "the sealed Orca control did not publish fixture metadata"
  assert_not_contains "$(cat "$log")" $'orca\x1f''terminal'$'\x1f''send' \
    "the sealed Orca control reached submission"
  pass "no-submit seals PATH and parses fake Orca without Node"
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
  out=$(env BASH_ENV="$bash_env" \
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

test_ordering_probes_are_live_without_submission
test_no_submit_ignores_path_backend_and_adapter
test_no_submit_refuses_unbound_backend
test_no_submit_refuses_untrusted_herdr_capability
test_no_submit_seals_path_and_parses_fake_orca_internally
test_named_adapter_indirection_is_fail_closed
test_shell_alias_cannot_reach_submission

echo "all fm-adapter-identity tests passed"
