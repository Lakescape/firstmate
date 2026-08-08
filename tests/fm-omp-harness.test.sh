#!/usr/bin/env bash
# tests/fm-omp-harness.test.sh - adapter tests for the CANDIDATE omp (Oh My Pi)
# crewmate/scout harness wired by bin/fm-spawn.sh, bin/fm-harness.sh,
# bin/fm-busy-lib.sh, and bin/backends/tmux.sh.
#
# Every case here runs the REAL fm-spawn against a fake tmux pane and a STUB
# `omp` executable on PATH. The installed Oh My Pi asset is never executed, no
# provider call, model discovery, prompt, or TUI/RPC session happens, and no
# live omp process is ever created. The stub answers `--version` only, which is
# the single identity probe the adapter performs.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

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

# The one release the adapter is pinned to; drift from this must refuse.
OMP_PINNED_VERSION="omp/17.2.9"

# Every omp launch requires an explicit, fully qualified provider/model. This is
# a STRUCTURAL fixture string only: no provider is contacted, no model catalog is
# queried, and the stub executable still refuses to open any session.
OMP_MODEL="anthropic/claude-sonnet-4-5"

make_omp_fakebin() {  # <dir> [omp-version|absent] -> echoes fakebin dir
  local dir=$1 version=${2:-$OMP_PINNED_VERSION} fakebin
  fakebin=$(fm_fakebin "$dir")
  # The tmux stub records send-keys payloads so a test can read back the exact
  # launch command the adapter would deliver to a pane, without a real pane.
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
if [ "${1:-}" = send-keys ] && [ -n "${FM_TMUX_LOG:-}" ]; then
  printf '%s\n' "${!#}" >> "$FM_TMUX_LOG"
fi
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window|send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  # `absent` deliberately installs no omp at all, so PATH resolution must fail.
  if [ "$version" != absent ]; then
    # The stub records every argv it is given, so a test can prove the adapter
    # probes ONLY --version and never opens a session.
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
  printf '%s\n' "$version"
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

# The absence case must prove the adapter's own refusal, so its PATH is the
# fakebin plus the base system directories ONLY. Inheriting the caller's PATH
# would let the REAL installed omp resolve (it lives under $HOME/.local), and
# the test would then silently prove nothing while also violating the
# stubs-only rule for deterministic verification.
OMP_ABSENT_PATH="/usr/bin:/bin:/usr/sbin:/sbin"

run_spawn() {  # <home> <wt> <fakebin> <spawn-args...>
  local home=$1 wt=$2 fakebin=$3 path
  shift 3
  path="$fakebin:${FM_TEST_BASE_PATH:-$PATH}"
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    GROK_HOME="$home/grok-home" PATH="$path" \
    FM_OMP_STUB_LOG="${FM_OMP_STUB_LOG:-}" FM_TMUX_LOG="${FM_TMUX_LOG:-}" \
    "$SPAWN" "$@" 2>&1
}

# --- selection -------------------------------------------------------------

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
    FM_OMP_HARNESS=1 "$ROOT/bin/fm-harness.sh")
  [ "$out" = omp ] || fail "FM_OMP_HARNESS=1 must detect 'omp', got '$out'"

  # An UNcleared foreign marker still wins, proving adding omp changed no
  # pre-existing marker precedence.
  out=$(env -u PI_CODING_AGENT -u GROK_AGENT -u FM_PI_HARNESS \
    CLAUDECODE=1 FM_OMP_HARNESS=1 "$ROOT/bin/fm-harness.sh")
  [ "$out" = claude ] || fail "existing marker precedence changed, got '$out'"

  # Liveness classifies the exact process name only, never a substring.
  out=$(fm_backend_tmux_classify_process_name /usr/local/bin/omp)
  [ "$out" = agent ] || fail "exact process name omp must classify agent, got '$out'"
  out=$(fm_backend_tmux_classify_process_name /bin/compinit)
  [ "$out" != agent ] || fail "compinit must not classify as an omp agent"
  out=$(fm_backend_tmux_classify_process_name /usr/bin/composer)
  [ "$out" != agent ] || fail "composer must not classify as an omp agent"
  pass "omp is recognized as its own token, never normalized to pi, and matched exactly for liveness"
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

# --- version pin -----------------------------------------------------------

test_omp_accepts_only_the_exact_pinned_version() {
  local rec id=omp-version out stub_log
  rec=$(make_omp_case omp-version claude "$id")
  read_case_record "$rec"
  stub_log="$CASE_DIR/omp-argv"
  : > "$stub_log"
  out=$(FM_OMP_STUB_LOG="$stub_log" run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" \
    "$id" "$PROJ_DIR" --harness omp --model "$OMP_MODEL" --mode no-mistakes --yolo off)
  expect_code 0 $? "omp spawn on the pinned version should succeed: $out"
  assert_contains "$out" "spawned $id harness=omp kind=ship" "omp spawn did not report harness=omp"
  # The ONLY invocation of the executable is the identity probe. Anything else
  # would mean the adapter opened a session during deterministic verification.
  [ "$(cat "$stub_log")" = "omp"$'\x1f'"--version" ] \
    || fail "adapter must invoke omp exactly once, with --version only, got: $(cat "$stub_log")"
  pass "omp launches on the exact pinned version and probes the binary only with --version"
}

test_omp_refuses_a_missing_binary() {
  local rec id=omp-absent out status
  rec=$(make_omp_case omp-absent claude "$id" absent)
  read_case_record "$rec"
  # Guard the guard: if the isolated PATH could still see an omp, this case
  # would pass for the wrong reason.
  ! PATH="$FAKEBIN_DIR:$OMP_ABSENT_PATH" command -v omp >/dev/null 2>&1 \
    || fail "the absence fixture must not be able to resolve any omp executable"
  out=$(FM_TEST_BASE_PATH="$OMP_ABSENT_PATH" run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" \
    "$id" "$PROJ_DIR" --harness omp --model "$OMP_MODEL" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "omp spawn must fail when the executable is absent: $out"
  assert_contains "$out" "omp executable not found on PATH" "absence refusal did not name the missing executable"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused omp spawn must not publish task metadata"
  pass "omp refuses to launch when no omp executable is on PATH"
}

test_omp_refuses_version_drift() {
  local rec id=omp-drift out status
  rec=$(make_omp_case omp-drift claude "$id" "omp/17.3.0")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" \
    "$id" "$PROJ_DIR" --harness omp --model "$OMP_MODEL" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "omp spawn must fail on version drift: $out"
  assert_contains "$out" "omp version drift" "drift refusal did not name the drift"
  assert_contains "$out" "$OMP_PINNED_VERSION" "drift refusal did not name the pinned version"
  assert_absent "$HOME_DIR/state/$id.meta" "a drifted omp spawn must not publish task metadata"
  pass "omp refuses a build whose reported version is not the pinned release"
}

test_omp_refuses_a_substituted_binary() {
  local rec id=omp-substitute out status
  # A different agent answering to the name `omp` is a substitution, not a pin.
  rec=$(make_omp_case omp-substitute claude "$id" "pi/0.82.0")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" \
    "$id" "$PROJ_DIR" --harness omp --model "$OMP_MODEL" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "omp spawn must fail on a substituted binary: $out"
  assert_contains "$out" "omp version drift" "substitution refusal did not refuse"
  pass "omp refuses a substituted executable that reports another agent's version"
}

# --- launch shape ----------------------------------------------------------

test_omp_launch_argv_is_contained() {
  local rec id=omp-argv out launch tmux_log tools
  rec=$(make_omp_case omp-argv claude "$id")
  read_case_record "$rec"
  tmux_log="$CASE_DIR/tmux-sends"
  : > "$tmux_log"
  out=$(FM_TMUX_LOG="$tmux_log" run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" \
    "$id" "$PROJ_DIR" --harness omp --model "$OMP_MODEL" --mode no-mistakes --yolo off)
  expect_code 0 $? "omp spawn should succeed: $out"
  launch=$(grep -F -- '--approval-mode' "$tmux_log" | tail -1)
  [ -n "$launch" ] || fail "no omp launch command was delivered to the pane"

  # One contiguous assertion pins the whole head of the command line: the
  # foreign markers are cleared, the firstmate-owned marker replaces them, the
  # resolved absolute binary follows, and the FIRST argument after it is a flag
  # rather than one of omp's subcommands (auth, token, usage, setup, update,
  # plugin, marketplace, acp), which is what keeps those surfaces unreachable.
  assert_contains "$launch" \
    "env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u FM_PI_HARNESS FM_OMP_HARNESS=1 '$FAKEBIN_DIR/omp' --approval-mode yolo --no-title --no-extensions --no-skills --tools read,write,edit,ls,grep,find,bash --model '$OMP_MODEL' -e '$HOME_DIR/state/$id.omp-ext.ts'" \
    "omp launch argv is not the contained shape"

  # The allowlist is exact, so a later widening has to be deliberate.
  tools=$(printf '%s\n' "$launch" | sed -n 's/.*--tools \([^ ]*\).*/\1/p')
  [ "$tools" = "read,write,edit,ls,grep,find,bash" ] \
    || fail "omp tool allowlist drifted, got '$tools'"
  case ",$tools," in
    *,task,*) fail "omp allowlist must exclude the task subagent tool" ;;
    *,browser,*) fail "omp allowlist must exclude the browser tool" ;;
    *,computer,*) fail "omp allowlist must exclude the computer tool" ;;
    *,web_search,*) fail "omp allowlist must exclude web search" ;;
    *,mcp,*) fail "omp allowlist must exclude MCP tooling" ;;
  esac

  # Exactly one extension is loaded, and it is the firstmate-owned state file.
  # grep -c counts LINES, so the occurrences are counted explicitly.
  local ext_flags
  ext_flags=$(printf '%s\n' "$launch" | grep -o -- ' -e ' | wc -l | tr -d '[:space:]')
  [ "$ext_flags" = 1 ] || fail "omp launch must load exactly one extension, found $ext_flags"
  assert_present "$HOME_DIR/state/$id.omp-ext.ts" "omp spawn did not write the state-owned extension"

  # A positional brief, and no effort axis reaching the launch. The model axis is
  # asserted in full by its own case below.
  assert_contains "$launch" "encode launch-brief" "omp launch missing the positional brief"
  assert_not_contains "$launch" "--thinking" "omp launch must not select an effort level"
  assert_not_contains "$launch" "--reasoning-effort" "omp launch must not select an effort level"
  pass "omp launch argv is contained: markers cleared, surface reduced, one extension, no delegation or network tooling"
}

test_omp_records_exact_task_metadata() {
  local rec id=omp-meta out meta
  rec=$(make_omp_case omp-meta claude "$id")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" \
    "$id" "$PROJ_DIR" --harness omp --model "$OMP_MODEL" --mode no-mistakes --yolo off)
  expect_code 0 $? "omp spawn should succeed: $out"
  meta="$HOME_DIR/state/$id.meta"
  assert_present "$meta" "omp spawn did not publish task metadata"
  assert_grep "harness=omp" "$meta" "meta must record harness=omp"
  assert_grep "kind=ship" "$meta" "meta must record the crewmate kind"
  assert_no_grep "traceparent=" "$meta" "omp must not enable trace propagation"
  assert_no_grep "home=" "$meta" "a crewmate must not record secondmate home state"
  assert_absent "$HOME_DIR/config/secondmate-harness" "omp must not write secondmate configuration"
  pass "omp records harness=omp with no trace context and no secondmate configuration"
}

test_omp_accepts_a_scout_launch() {
  local rec id=omp-scout out
  rec=$(make_omp_case omp-scout claude "$id")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR" --scout --harness omp --model "$OMP_MODEL")
  expect_code 0 $? "omp scout spawn should succeed: $out"
  assert_contains "$out" "spawned $id harness=omp kind=scout" "omp must be accepted for a scout launch"
  assert_present "$HOME_DIR/state/$id.omp-ext.ts" "an omp scout must still get its busy-state extension"
  pass "omp is accepted for crewmate and scout launches"
}

# --- launch model pin ------------------------------------------------------

# One omp spawn that must be refused, plus the proof that the refusal landed
# before any mutation: no task metadata, no busy contract, no extension, nothing
# sent to a pane, and the pinned executable never even probed for its version.
# The caller supplies the fixture, so a whole table of rejected values shares one
# worktree - a refused spawn creates nothing to isolate.
assert_omp_launch_refused() {  # <task-id> <expected-message> [extra spawn args...]
  local id=$1 want=$2 out status stub_log tmux_log
  shift 2
  stub_log="$CASE_DIR/omp-argv-$id"
  tmux_log="$CASE_DIR/tmux-sends-$id"
  : > "$stub_log"
  : > "$tmux_log"
  mkdir -p "$HOME_DIR/data/$id"
  printf 'brief for %s\n' "$id" > "$HOME_DIR/data/$id/brief.md"
  out=$(FM_OMP_STUB_LOG="$stub_log" FM_TMUX_LOG="$tmux_log" \
    run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" \
    "$id" "$PROJ_DIR" --harness omp "$@" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "$id: the spawn must be refused: $out"
  assert_contains "$out" "$want" "$id: refusal did not name the launch pin: $out"
  assert_absent "$HOME_DIR/state/$id.meta" "$id: refused spawn published task metadata"
  assert_absent "$HOME_DIR/state/$id.omp-ext.ts" "$id: refused spawn wrote the extension"
  assert_absent "$HOME_DIR/state/$id.busy-gen" "$id: refused spawn armed a busy contract"
  [ ! -s "$tmux_log" ] || fail "$id: refused spawn sent a command to a pane: $(cat "$tmux_log")"
  [ ! -s "$stub_log" ] || fail "$id: refused spawn invoked the pinned executable: $(cat "$stub_log")"
}

test_omp_refuses_an_absent_or_sentinel_model() {
  local rec want="omp requires an explicit --model <provider>/<model>"
  rec=$(make_omp_case omp-model-absent claude omp-none)
  read_case_record "$rec"
  # No --model at all: omp would otherwise resolve the provider from its own
  # configured default, which is exactly what this pin removes.
  assert_omp_launch_refused omp-none "$want"
  # "default" is firstmate's own no-model sentinel, never a provider identifier.
  assert_omp_launch_refused omp-sentinel "$want" --model default
  pass "omp refuses a launch with no model, and refuses the no-model sentinel, before any mutation"
}

test_omp_refuses_an_unqualified_malformed_or_ambiguous_model() {
  local rec bad i=0 want="omp --model must be exactly '<provider>/<model>'"
  rec=$(make_omp_case omp-model-bad claude omp-bad-0)
  read_case_record "$rec"
  # Unqualified bare names are what omp would fuzzy-match across providers, and
  # everything after them is a malformed or ambiguous structure: empty segments,
  # extra path segments, whitespace, wildcards, and shell metacharacters. No
  # catalog is consulted for any of them - the refusal is purely structural.
  # shellcheck disable=SC2016  # the metacharacter cases must stay LITERAL: they are rejected input, not expansions
  for bad in \
    opus \
    claude-sonnet-4-5 \
    'anthropic/' \
    '/claude-sonnet-4-5' \
    'anthropic//claude-sonnet-4-5' \
    'anthropic/claude/sonnet' \
    'anthropic claude' \
    'anthropic/claude sonnet' \
    'anthropic/claude*' \
    '*/claude-sonnet-4-5' \
    'anthropic/claude?' \
    'anthropic/claude;id' \
    'anthropic/$(id)' \
    'anthropic/`id`' \
    'anthropic/claude|tee' \
    '-anthropic/claude' \
    'anthropic/-claude' \
    '.anthropic/claude' \
    'anthropic:claude' \
    'anthropic/claude/' \
    ; do
    i=$((i + 1))
    assert_omp_launch_refused "omp-bad-$i" "$want" --model "$bad"
  done
  pass "omp refuses every unqualified, malformed, or ambiguous model before any mutation ($i shapes)"
}

test_omp_model_refusal_precedes_the_per_task_spawn_lock() {
  local rec id=omp-lock out status lock
  rec=$(make_omp_case omp-model-lock claude "$id")
  read_case_record "$rec"
  # A per-task spawn lock held by a live process. fm-spawn refuses a second spawn
  # on it, so WHICH refusal comes back proves the ordering of the two checks.
  lock="$HOME_DIR/state/.spawn-$id.lock"
  mkdir -p "$lock"
  printf '%s\n' "$$" > "$lock/pid"

  # Control: a fully qualified model gets far enough to hit the held lock, so the
  # fixture is proven to be blocking rather than vacuous.
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" \
    "$id" "$PROJ_DIR" --harness omp --model "$OMP_MODEL" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "a held per-task spawn lock must refuse the spawn: $out"
  assert_contains "$out" "another spawn is already creating task $id" \
    "the held-lock fixture is not actually blocking acquisition: $out"

  # The pin: with no model, the model refusal is what comes back, so it landed
  # before the lock was ever reached.
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" \
    "$id" "$PROJ_DIR" --harness omp --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "a missing omp model must refuse the spawn: $out"
  assert_contains "$out" "omp requires an explicit --model" \
    "the model refusal must precede the per-task spawn lock: $out"
  assert_not_contains "$out" "another spawn is already creating" \
    "the model refusal must precede the per-task spawn lock: $out"
  rm -rf "$lock"
  pass "an omp launch with no model is refused before the per-task spawn lock is acquired"
}

test_omp_launch_carries_exactly_one_qualified_model_flag() {
  local rec id=omp-model-argv out launch tmux_log stub_log flags value
  rec=$(make_omp_case omp-model-argv claude "$id")
  read_case_record "$rec"
  tmux_log="$CASE_DIR/tmux-sends"
  stub_log="$CASE_DIR/omp-argv"
  : > "$tmux_log"
  : > "$stub_log"
  out=$(FM_TMUX_LOG="$tmux_log" FM_OMP_STUB_LOG="$stub_log" \
    run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" \
    "$id" "$PROJ_DIR" --harness omp --model "$OMP_MODEL" --mode no-mistakes --yolo off)
  expect_code 0 $? "omp spawn with a qualified model should succeed: $out"
  launch=$(grep -F -- '--approval-mode' "$tmux_log" | tail -1)
  [ -n "$launch" ] || fail "no omp launch command was delivered to the pane"

  # Exactly one --model, carrying the exact identifier that was supplied.
  flags=$(printf '%s\n' "$launch" | grep -o -- '--model' | wc -l | tr -d '[:space:]')
  [ "$flags" = 1 ] || fail "omp launch must carry exactly one --model flag, found $flags"
  value=$(printf '%s\n' "$launch" | sed -n "s/.*--model '\\([^']*\\)'.*/\\1/p")
  [ "$value" = "$OMP_MODEL" ] \
    || fail "omp --model must carry the exact supplied identifier, got '$value'"

  # omp's legacy provider flag and every fuzzy, cycling, or fallback selector
  # stay off the launch: one qualified identifier is the whole selection.
  assert_not_contains "$launch" "--provider" "omp launch must not pass a provider flag"
  assert_not_contains "$launch" "--fallback" "omp launch must not pass a fallback selector"
  assert_not_contains "$launch" "--cycle" "omp launch must not pass a model cycler"

  # The pinned executable is still probed ONLY for its identity, so no model
  # catalog, provider list, or account query happens on the spawn path.
  [ "$(cat "$stub_log")" = "omp"$'\x1f'"--version" ] \
    || fail "adapter must invoke omp exactly once, with --version only, got: $(cat "$stub_log")"

  # The recorded model is the supplied one, and no configuration was written.
  assert_grep "model=$OMP_MODEL" "$HOME_DIR/state/$id.meta" "meta must record the exact launch model"
  [ "$(cat "$HOME_DIR/config/crew-harness")" = claude ] \
    || fail "an omp launch must not rewrite config/crew-harness"
  assert_absent "$HOME_DIR/config/crew-dispatch.json" "an omp launch must not write a dispatch profile"
  assert_absent "$HOME_DIR/config/secondmate-harness" "an omp launch must not write secondmate configuration"
  pass "an omp launch carries exactly one --model with the exact supplied provider/model, no provider flag, and writes no configuration"
}

test_omp_resolved_from_config_still_requires_an_explicit_model() {
  local rec id=omp-cfg out status launch tmux_log
  # config/crew-harness selects omp, so this launch passes no --harness at all.
  # The model must still come from this spawn's own flag: a harness config file
  # is not a provider decision, and omp's own default is never consulted.
  rec=$(make_omp_case omp-model-config omp "$id")
  read_case_record "$rec"
  tmux_log="$CASE_DIR/tmux-sends"
  : > "$tmux_log"
  out=$(FM_TMUX_LOG="$tmux_log" run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" \
    "$id" "$PROJ_DIR" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "a config-resolved omp launch with no model must be refused: $out"
  assert_contains "$out" "omp requires an explicit --model" \
    "config-resolved refusal did not name the launch pin: $out"
  assert_absent "$HOME_DIR/state/$id.meta" "refused config-resolved omp spawn published task metadata"
  assert_absent "$HOME_DIR/state/$id.omp-ext.ts" "refused config-resolved omp spawn wrote the extension"
  [ ! -s "$tmux_log" ] || fail "refused config-resolved omp spawn sent a command to a pane"

  # The same config-resolved launch proceeds once the flag supplies the model.
  out=$(FM_TMUX_LOG="$tmux_log" run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" \
    "$id" "$PROJ_DIR" --model "$OMP_MODEL" --mode no-mistakes --yolo off)
  expect_code 0 $? "a config-resolved omp launch with an explicit model should succeed: $out"
  launch=$(grep -F -- '--approval-mode' "$tmux_log" | tail -1)
  assert_contains "$launch" "--model '$OMP_MODEL'" \
    "the config-resolved omp launch did not carry the explicit model"
  pass "an omp launch resolved from config/crew-harness still requires the model on its own flag"
}

test_a_non_omp_harness_launch_gains_no_model_or_provider_flag() {
  local rec id=omp-other out launch tmux_log
  # The launch pin is omp-only: a claude launch that requested no model must
  # carry no model or provider flag at all, exactly as before.
  rec=$(make_omp_case omp-model-nonomp claude "$id")
  read_case_record "$rec"
  tmux_log="$CASE_DIR/tmux-sends"
  : > "$tmux_log"
  out=$(FM_TMUX_LOG="$tmux_log" run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" \
    "$id" "$PROJ_DIR" --mode no-mistakes --yolo off)
  expect_code 0 $? "default claude spawn should succeed: $out"
  launch=$(grep -F -- 'dangerously-skip-permissions' "$tmux_log" | tail -1)
  [ -n "$launch" ] || fail "no claude launch command was delivered to the pane"
  assert_not_contains "$launch" "--model" \
    "a non-omp launch that requested no model must carry no model flag"
  assert_not_contains "$launch" "--provider" "a non-omp launch must never carry a provider flag"
  pass "a non-omp harness launch is unchanged: no model or provider flag when none was requested"
}

# --- secondmate refusal ----------------------------------------------------

test_omp_refuses_a_secondmate_before_any_mutation() {
  local rec id=omp-secondmate out status sub_home
  rec=$(make_omp_case omp-secondmate claude "$id")
  read_case_record "$rec"
  sub_home="$CASE_DIR/secondmate-home"
  mkdir -p "$sub_home"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$sub_home" --harness omp --model "$OMP_MODEL" --secondmate)
  status=$?
  [ "$status" -ne 0 ] || fail "omp must be refused for a secondmate: $out"
  assert_contains "$out" "omp is a candidate crewmate/scout adapter only" \
    "secondmate refusal did not name the crewmate/scout restriction"

  # The refusal must land before ANY endpoint, worktree, state, or config
  # mutation, so nothing about the run is left half-created.
  assert_absent "$HOME_DIR/state/$id.meta" "refused omp secondmate wrote task metadata"
  assert_absent "$HOME_DIR/state/$id.omp-ext.ts" "refused omp secondmate wrote the extension"
  assert_absent "$HOME_DIR/state/$id.busy-gen" "refused omp secondmate armed a busy contract"
  assert_absent "$sub_home/config" "refused omp secondmate mutated the secondmate home config"
  assert_absent "$sub_home/state" "refused omp secondmate mutated the secondmate home state"
  assert_absent "$HOME_DIR/data/secondmates.md" "refused omp secondmate touched the registry"
  pass "omp refuses every secondmate launch before endpoint, worktree, state, or config mutation"
}

# --- busy-state trust table ------------------------------------------------

test_omp_trusts_only_its_own_semantic_source() {
  local trusted
  trusted=$(fm_busy_sources_for_harness omp)
  case " $trusted " in
    *" omp-ext "*) : ;;
    *) fail "omp must trust its own omp-ext source, got '$trusted'" ;;
  esac
  case " $trusted " in
    *" pi-ext "*) fail "omp must not inherit the Pi extension source" ;;
  esac
  fm_busy_source_trusted omp omp-ext || fail "omp-ext must be trusted for omp"
  ! fm_busy_source_trusted omp pi-ext || fail "pi-ext must not be trusted for omp"
  ! fm_busy_source_trusted pi omp-ext || fail "omp-ext must not be trusted for pi"
  pass "omp trusts exactly its own omp-ext semantic source"
}

test_omp_token_is_not_normalized_to_pi
test_omp_is_unreachable_without_explicit_selection
test_omp_accepts_only_the_exact_pinned_version
test_omp_refuses_a_missing_binary
test_omp_refuses_version_drift
test_omp_refuses_a_substituted_binary
test_omp_launch_argv_is_contained
test_omp_records_exact_task_metadata
test_omp_accepts_a_scout_launch
test_omp_refuses_an_absent_or_sentinel_model
test_omp_refuses_an_unqualified_malformed_or_ambiguous_model
test_omp_model_refusal_precedes_the_per_task_spawn_lock
test_omp_launch_carries_exactly_one_qualified_model_flag
test_omp_resolved_from_config_still_requires_an_explicit_model
test_a_non_omp_harness_launch_gains_no_model_or_provider_flag
test_omp_refuses_a_secondmate_before_any_mutation
test_omp_trusts_only_its_own_semantic_source

echo "all fm-omp-harness tests passed"
