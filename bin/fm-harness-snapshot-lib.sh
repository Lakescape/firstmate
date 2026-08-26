#!/usr/bin/env bash
# fm-harness-snapshot-lib.sh - parse the resolved harness snapshot protocol.

fm_harness_snapshot_parse() {  # <snapshot-text>
  local snapshot=${1-} line key value
  local dispatch_active= harness= model= effort=
  local dispatch_seen=0 harness_seen=0 model_seen=0 effort_seen=0

  FM_HARNESS_SNAPSHOT_DISPATCH_ACTIVE=
  FM_HARNESS_SNAPSHOT_HARNESS=
  FM_HARNESS_SNAPSHOT_MODEL=
  FM_HARNESS_SNAPSHOT_EFFORT=

  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      *=*) key=${line%%=*}; value=${line#*=} ;;
      *) return 1 ;;
    esac
    case "$key" in
      dispatch_active)
        [ "$dispatch_seen" -eq 0 ] || return 1
        dispatch_active=$value
        dispatch_seen=1
        ;;
      harness)
        [ "$harness_seen" -eq 0 ] || return 1
        harness=$value
        harness_seen=1
        ;;
      model)
        [ "$model_seen" -eq 0 ] || return 1
        model=$value
        model_seen=1
        ;;
      effort)
        [ "$effort_seen" -eq 0 ] || return 1
        effort=$value
        effort_seen=1
        ;;
      *) return 1 ;;
    esac
  done <<EOF
$snapshot
EOF

  [ "$dispatch_seen" -eq 1 ] && [ "$harness_seen" -eq 1 ] \
    && [ "$model_seen" -eq 1 ] && [ "$effort_seen" -eq 1 ] \
    && [ -n "$harness" ] || return 1
  case "$dispatch_active" in
    0|1) ;;
    *) return 1 ;;
  esac

  FM_HARNESS_SNAPSHOT_DISPATCH_ACTIVE=$dispatch_active
  FM_HARNESS_SNAPSHOT_HARNESS=$harness
  FM_HARNESS_SNAPSHOT_MODEL=$model
  FM_HARNESS_SNAPSHOT_EFFORT=$effort
}
