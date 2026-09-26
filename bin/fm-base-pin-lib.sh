#!/usr/bin/env bash
# fm-base-pin-lib.sh - the one owner of a relaunch's recorded allocation base pin.
#
# A ship or scout relaunch keeps the original allocation pin (base_sha,
# base_tree, base_cwd) instead of relabeling later worker commits as the
# starting base. Truly absent legacy bindings stay unknown. Anything else is
# refused: empty-but-present keys, a partial set, requested_base without the
# three pin fields, duplicate keys, a non-absolute or foreign base_cwd, a
# base_sha that is not an exact commit object, or a base_tree that is not that
# commit's tree.
#
# fm-control.sh calls this in relaunch preflight, before the checkpoint is
# journaled, before the progress note is written, and before the running agent
# is stopped. fm-spawn.sh calls it again before the replacement is published.
# Both pass the task id, the recorded meta file, and the current worktree.
# On success this sets SPAWN_BASE_SHA, SPAWN_BASE_TREE, SPAWN_BASE_CWD, and
# SPAWN_REQUESTED_BASE (all empty when the legacy pin is truly absent) and
# returns 0. On refusal it prints the error and returns 1. The caller exits.
# This file does not stop an agent or rewrite a brief.

fm_relaunch_load_allocation_base() {  # <id> <meta-file> <worktree>
  local id=$1 meta=$2 wt=$3
  local _base_sha_n _base_tree_n _base_cwd_n _req_base_n _n _pin_key_n
  local _wt_cwd _base_cwd_phys _obj_type _full_commit _expected_tree

  # Distinguish truly absent legacy bindings by FIELD COUNTS, not concatenated
  # values. Empty-but-present keys or requested_base-only are malformed, not
  # legacy. Validate base_sha as an exact commit object before matching its
  # tree. Canonical recorded base_cwd must equal the current worktree.
  _base_sha_n=$(grep -c -E '^base_sha=' "$meta" 2>/dev/null || true)
  _base_tree_n=$(grep -c -E '^base_tree=' "$meta" 2>/dev/null || true)
  _base_cwd_n=$(grep -c -E '^base_cwd=' "$meta" 2>/dev/null || true)
  _req_base_n=$(grep -c -E '^requested_base=' "$meta" 2>/dev/null || true)
  for _n in "$_base_sha_n" "$_base_tree_n" "$_base_cwd_n" "$_req_base_n"; do
    case "$_n" in
      0|1) ;;
      *) echo "error: relaunch of $id has duplicate base-binding keys in recorded meta; refusing to guess which pin is authoritative" >&2; return 1 ;;
    esac
  done
  SPAWN_BASE_SHA=$(grep -E '^base_sha=' "$meta" 2>/dev/null | head -n1 | cut -d= -f2-)
  SPAWN_BASE_TREE=$(grep -E '^base_tree=' "$meta" 2>/dev/null | head -n1 | cut -d= -f2-)
  SPAWN_BASE_CWD=$(grep -E '^base_cwd=' "$meta" 2>/dev/null | head -n1 | cut -d= -f2-)
  SPAWN_REQUESTED_BASE=$(grep -E '^requested_base=' "$meta" 2>/dev/null | head -n1 | cut -d= -f2-)
  _pin_key_n=$((_base_sha_n + _base_tree_n + _base_cwd_n))
  if [ "$_pin_key_n" -eq 0 ] && [ "$_req_base_n" -eq 0 ]; then
    # Truly absent legacy bindings: leave the pin unknown (do not invent from HEAD).
    SPAWN_BASE_SHA=
    SPAWN_BASE_TREE=
    SPAWN_BASE_CWD=
    SPAWN_REQUESTED_BASE=
  elif [ "$_base_sha_n" -eq 1 ] && [ "$_base_tree_n" -eq 1 ] && [ "$_base_cwd_n" -eq 1 ] \
    && [ -n "$SPAWN_BASE_SHA" ] && [ -n "$SPAWN_BASE_TREE" ] && [ -n "$SPAWN_BASE_CWD" ]; then
    case "$SPAWN_BASE_CWD" in
      /*) ;;
      *) echo "error: relaunch of $id has a non-absolute base_cwd in recorded meta; refusing" >&2; return 1 ;;
    esac
    _wt_cwd=$(cd "$wt" && pwd -P) || {
      echo "error: relaunch of $id could not resolve current worktree cwd for base_cwd check" >&2
      return 1
    }
    _base_cwd_phys=
    if [ -d "$SPAWN_BASE_CWD" ]; then
      _base_cwd_phys=$(cd "$SPAWN_BASE_CWD" && pwd -P) || _base_cwd_phys=
    fi
    if [ "$SPAWN_BASE_CWD" != "$_wt_cwd" ] && [ "$SPAWN_BASE_CWD" != "$wt" ] \
      && { [ -z "$_base_cwd_phys" ] || [ "$_base_cwd_phys" != "$_wt_cwd" ]; }; then
      echo "error: relaunch of $id recorded base_cwd='$SPAWN_BASE_CWD' does not match current worktree '$_wt_cwd'; refusing" >&2
      return 1
    fi
    # Exact commit object first; rev-parse SHA^{tree} alone accepts a tree/ref.
    _obj_type=$(git -C "$wt" cat-file -t "$SPAWN_BASE_SHA" 2>/dev/null) || {
      echo "error: relaunch of $id recorded base_sha='$SPAWN_BASE_SHA' is not a git object in worktree '$wt'; refusing" >&2
      return 1
    }
    [ "$_obj_type" = commit ] || {
      echo "error: relaunch of $id recorded base_sha='$SPAWN_BASE_SHA' is a $_obj_type, not a commit; refusing" >&2
      return 1
    }
    _full_commit=$(git -C "$wt" rev-parse --verify --quiet "$SPAWN_BASE_SHA^{commit}" 2>/dev/null) || {
      echo "error: relaunch of $id recorded base_sha='$SPAWN_BASE_SHA' could not be resolved as a commit; refusing" >&2
      return 1
    }
    [ "$_full_commit" = "$SPAWN_BASE_SHA" ] || {
      echo "error: relaunch of $id recorded base_sha='$SPAWN_BASE_SHA' is not an exact commit object SHA (resolves to '$_full_commit'); refusing" >&2
      return 1
    }
    _expected_tree=$(git -C "$wt" rev-parse --verify --quiet "$_full_commit^{tree}" 2>/dev/null) || {
      echo "error: relaunch of $id could not resolve the tree for base_sha='$SPAWN_BASE_SHA'; refusing" >&2
      return 1
    }
    [ "$_expected_tree" = "$SPAWN_BASE_TREE" ] || {
      echo "error: relaunch of $id recorded base_tree='$SPAWN_BASE_TREE' does not match base_sha='$SPAWN_BASE_SHA' (expected '$_expected_tree'); refusing" >&2
      return 1
    }
  else
    # Empty-but-present keys, partial set, or requested_base-only: malformed.
    echo "error: relaunch of $id has a malformed allocation base pin in recorded meta; refusing" >&2
    return 1
  fi
}
