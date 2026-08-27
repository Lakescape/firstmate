#!/bin/bash
set -u

LOG="${FM_ORCA_LOG:?}"
RESP="${FM_ORCA_RESPONSES:?}"
COUNT_FILE="$RESP/.count"
current=0
if [ -f "$COUNT_FILE" ]; then
  IFS= read -r current < "$COUNT_FILE" || current=0
fi
next=$((current + 1))
{
  printf 'orca'
  for arg in "$@"; do printf '\x1f%s' "$arg"; done
  printf '\n'
} >> "$LOG"
if [ -n "${FM_ORCA_COLLISION_META:-}" ] \
   && [ "${1:-} ${2:-}" = "${FM_ORCA_COLLISION_ON:-worktree rm}" ]; then
  collision_temporary="${FM_ORCA_COLLISION_META}.collision.$$"
  if [ -n "${FM_ORCA_COLLISION_SOURCE:-}" ]; then
    if [ "${FM_ORCA_COLLISION_MODE:-replace}" = in-place ]; then
      /bin/cat "$FM_ORCA_COLLISION_SOURCE" > "$FM_ORCA_COLLISION_META"
    else
      /bin/cp "$FM_ORCA_COLLISION_SOURCE" "$collision_temporary"
    fi
  elif [ "${FM_ORCA_COLLISION_MODE:-replace}" = in-place ]; then
    printf 'sentinel=original\n' > "$FM_ORCA_COLLISION_META"
  else
    printf 'sentinel=original\n' > "$collision_temporary"
  fi
  if [ "${FM_ORCA_COLLISION_MODE:-replace}" != in-place ]; then
    /bin/mv "$collision_temporary" "$FM_ORCA_COLLISION_META"
  fi
fi
if [ "${1:-}" = status ] && [ "${FM_ORCA_STATUS_RESPONSE:-ready}" != sequence ]; then
  printf '{"ok":true,"result":{"runtime":{"reachable":true,"state":"ready"}}}\n'
  exit 0
fi
n=$next
printf '%s\n' "$n" > "$COUNT_FILE"
[ -f "$RESP/$n.out" ] && /bin/cat "$RESP/$n.out"
if [ -f "$RESP/$n.exit" ]; then
  exit "$(/bin/cat "$RESP/$n.exit")"
fi
exit 0
