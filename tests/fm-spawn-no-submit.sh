#!/bin/sh
set -eu

PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH

resolve_file() {
  path=$1
  case "$path" in /*) ;; *) path=$(pwd -P)/$path ;; esac
  while [ -L "$path" ]; do
    directory=$(CDPATH='' cd -- "$(dirname -- "$path")" && pwd -P)
    target=$(/usr/bin/readlink "$path") || return 1
    case "$target" in /*) path=$target ;; *) path=$directory/$target ;; esac
  done
  directory=$(CDPATH='' cd -- "$(dirname -- "$path")" && pwd -P) || return 1
  printf '%s/%s\n' "$directory" "$(basename -- "$path")"
}

file_signature() {
  if [ "$(/usr/bin/uname -s 2>/dev/null)" = Darwin ]; then
    /usr/bin/stat -f '%i:%z:%HT' "$1" 2>/dev/null
  else
    /usr/bin/stat -L -c '%i:%s:%F' "$1" 2>/dev/null
  fi
}

fd_matches_path() {
  fd=$1
  path=$2
  [ -r "/dev/fd/$fd" ] && [ -f "$path" ] || return 1
  fd_signature=$(file_signature "/dev/fd/$fd") || return 1
  path_signature=$(file_signature "$path") || return 1
  [ "$fd_signature" = "$path_signature" ]
}

HELPER=$(resolve_file "$0")
SPAWN=$(resolve_file "$(dirname -- "$HELPER")/../bin/fm-spawn.sh")
ROOT=$(CDPATH='' cd -- "$(dirname -- "$SPAWN")/.." && pwd -P)
GIT_ROOT=$(/usr/bin/git -C "$ROOT" rev-parse --show-toplevel 2>/dev/null) || exit 1
[ "$GIT_ROOT" -ef "$ROOT" ] || exit 1
[ "$HELPER" -ef "$ROOT/tests/fm-spawn-no-submit.sh" ] || exit 1
if [ -n "${FM_SPAWN_TEST_NO_SUBMIT_HERDR_FD:-}" ]; then
  [ "${FM_SPAWN_TEST_NO_SUBMIT_HERDR_AUTH_FD:-}" = 6 ] || exit 1
  fd_matches_path 6 "$ROOT/tests/herdr-test-safety.sh" || exit 1
  [ "${FM_SPAWN_TEST_NO_SUBMIT_JQ_FD:-}" = 5 ] || exit 1
  [ -n "${FM_SPAWN_TEST_NO_SUBMIT_JQ_PATH:-}" ] || exit 1
  fd_matches_path 5 "$FM_SPAWN_TEST_NO_SUBMIT_JQ_PATH" || exit 1
  [ -x "$FM_SPAWN_TEST_NO_SUBMIT_JQ_PATH" ] || exit 1
fi
exec 9< "$HELPER"
export FM_SPAWN_TEST_NO_SUBMIT_FD=9
export FM_SPAWN_TEST_NO_SUBMIT_ROOT=$ROOT
export FM_ROOT_OVERRIDE=$ROOT
unset FM_SPAWN_TEST_NO_SUBMIT_HERDR_SESSION
case "${HERDR_SESSION:-}" in
  fm-lab-?*)
    case "$HERDR_SESSION" in
      *[!A-Za-z0-9._-]*) ;;
      *) export FM_SPAWN_TEST_NO_SUBMIT_HERDR_SESSION=$HERDR_SESSION ;;
    esac
    ;;
esac
exec /usr/bin/env -u BASH_ENV -u ENV /bin/bash -p "$SPAWN" "$@"
