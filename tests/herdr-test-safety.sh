#!/usr/bin/env bash
# Compatibility source for real-Herdr tests.
# The production owner of the isolation, refuse-default, teardown, and
# fleet-state tripwire contract is bin/fm-herdr-lab.sh.
set -u

HERDR_TEST_SAFETY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
. "$HERDR_TEST_SAFETY_DIR/bin/fm-herdr-lab.sh"

herdr_test_resolve_file() {
  local path=$1 directory target
  case "$path" in /*) ;; *) path=$(pwd -P)/$path ;; esac
  while [ -L "$path" ]; do
    directory=$(CDPATH='' cd -- "$(dirname -- "$path")" && pwd -P) || return 1
    target=$(/usr/bin/readlink "$path") || return 1
    case "$target" in /*) path=$target ;; *) path=$directory/$target ;; esac
  done
  directory=$(CDPATH='' cd -- "$(dirname -- "$path")" && pwd -P) || return 1
  printf '%s/%s\n' "$directory" "$(basename -- "$path")"
}

exec 6< "$HERDR_TEST_SAFETY_DIR/tests/herdr-test-safety.sh"
export FM_SPAWN_TEST_NO_SUBMIT_HERDR_AUTH_FD=6

HERDR_TEST_BINARY=$(command -v herdr 2>/dev/null || true)
HERDR_TEST_JQ=$(command -v jq 2>/dev/null || true)
if [ -n "$HERDR_TEST_BINARY" ] && [ -n "$HERDR_TEST_JQ" ]; then
  HERDR_TEST_BINARY=$(herdr_test_resolve_file "$HERDR_TEST_BINARY") || HERDR_TEST_BINARY=
  HERDR_TEST_JQ=$(herdr_test_resolve_file "$HERDR_TEST_JQ") || HERDR_TEST_JQ=
fi
if [ -n "$HERDR_TEST_BINARY" ] && [ -n "$HERDR_TEST_JQ" ]; then
  exec 4< "$HERDR_TEST_BINARY"
  exec 5< "$HERDR_TEST_JQ"
  export FM_SPAWN_TEST_NO_SUBMIT_HERDR_FD=4
  export FM_SPAWN_TEST_NO_SUBMIT_HERDR_PATH=$HERDR_TEST_BINARY
  export FM_SPAWN_TEST_NO_SUBMIT_JQ_FD=5
  export FM_SPAWN_TEST_NO_SUBMIT_JQ_PATH=$HERDR_TEST_JQ
fi

# herdr_forget_inherited_pane: drop the Herdr PANE identity this test process
# inherited from whatever terminal it was started in.
#
# Herdr injects HERDR_ENV, HERDR_PANE_ID, HERDR_TAB_ID, HERDR_WORKSPACE_ID,
# HERDR_SOCKET_PATH, and HERDR_SESSION into every process it manages a pane for
# (verified 0.7.5 - docs/verification/runtime-backends.md), and a test run from
# inside a Herdr pane inherits all of them. Spawn now treats that pane as the
# authoritative parent to place workers next to, so a leaked identity from the
# developer's own session would follow the test into its isolated lab session
# and be refused there as a cross-session parent - a result that depends on
# where the suite was launched from, not on what it asserts.
#
# Call this before exporting the lab HERDR_SESSION in any suite whose subject is
# the per-home container path. A suite that means to exercise a launcher-bound
# spawn sets HERDR_PANE_ID itself, to a pane it created in its own lab session.
herdr_forget_inherited_pane() {
  unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION
}

herdr_refuse_if_default() { # <session>
  fm_herdr_lab_refuse_if_default "$1"
}

herdr_safe_stop_and_delete() { # <session>
  fm_herdr_lab_teardown "$1"
}
