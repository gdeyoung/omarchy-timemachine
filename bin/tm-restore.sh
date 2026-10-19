#!/usr/bin/env bash
# tm-restore.sh — Time Machine engine: stage data OUT of the backup tree.
#
# THIS SCRIPT NEVER WRITES INTO LIVE STATE. It restores into a staging
# directory; the operator merges (never blind-copy over live config/keys).
#
# Backups are plain files — in a pinch browse them directly on the backup
# host over ssh/smb in any file manager. No keys, no tooling.
#
# Usage:
#   tm-restore.sh --list                    backup table
#   tm-restore.sh --latest [--target DIR]   stage newest backup
#   tm-restore.sh --backup ID [--target DIR]
#   tm-restore.sh --files PATTERN           stage matching paths from newest
#   tm-restore.sh --drill                   pull + verify sentinels, PASS/FAIL
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/tm-common.sh"
load_conf
SSH="$(ssh_cmd)"
RSYNC_SSH="ssh -p $TM_SSH_PORT -o ConnectTimeout=15 -o BatchMode=yes"

configured || { echo "FATAL: TM_HOST/TM_DEST not set"; exit 1; }

MODE="${1:---list}"
TARGET="${TM_TARGET:-$HOME/.local/state/timemachine-restore-$(date +%Y%m%d-%H%M%S)}"
LABEL="$TM_LABEL"

newest() { $SSH "$TM_HOST" "basename \"\$(readlink '$TM_DEST/latest')\" 2>/dev/null" 2>/dev/null; }

case "$MODE" in
  --list)
    echo "latest -> $($SSH "$TM_HOST" "readlink '$TM_DEST/latest'" 2>/dev/null)"
    $SSH "$TM_HOST" "ls -1 '$TM_DEST/backups' | sort" 2>/dev/null
    ;;
  --latest|--backup|--snapshot)
    SNAP=$([ "$MODE" = --backup ] || [ "$MODE" = --snapshot ] && echo "$2" || newest)
    [ -n "${SNAP:-}" ] || { echo "no backups on $LABEL"; exit 1; }
    [ "${3:-}" = "--target" ] && TARGET="$4"
    echo "staging backup $SNAP → $TARGET (contents = home root)"
    mkdir -p "$TARGET"
    rsync -aH -e "$RSYNC_SSH" "$TM_HOST:$TM_DEST/backups/$SNAP/" "$TARGET/"
    echo "staged. Merge carefully — never blind-overwrite live keys/config." ;;
  --files)
    PAT="${2:?pattern required}"
    SNAP=$(newest); [ -n "$SNAP" ] || { echo "no backups"; exit 1; }
    mkdir -p "$TARGET"
    rsync -a -m -e "$RSYNC_SSH" --include='*/' --include="$PAT" --exclude='*' \
          "$TM_HOST:$TM_DEST/latest/" "$TARGET/"
    echo "staged under $TARGET (pattern: $PAT)" ;;
  --drill)
    SNAP=$(newest); [ -n "$SNAP" ] || { echo "DRILL FAIL: no backups on $LABEL"; exit 1; }
    mkdir -p "$TARGET"
    pass=0; fail=0
    pull() { rsync -a -q -e "$RSYNC_SSH" "$TM_HOST:$TM_DEST/latest/$1" "$TARGET/$1" 2>/dev/null; }
    chk() { if [ -e "$TARGET/$1" ]; then echo "  ✓ $1"; pass=$((pass+1)); else echo "  ✗ MISSING: $1"; fail=$((fail+1)); fi; }
    [ -n "$TM_SENTINELS" ] || { echo "DRILL FAIL: TM_SENTINELS not configured"; exit 1; }
    IFS=':'
    for s in $TM_SENTINELS; do
      unset IFS
      [ -n "$s" ] || continue
      mkdir -p "$TARGET/$(dirname "$s")"; pull "$s"; chk "$s"
      IFS=':'
    done
    unset IFS
    echo "DRILL: $pass pass, $fail fail (backup $SNAP → $TARGET)"
    python3 - "$pass" "$fail" "$SNAP" "$TM_STATE_DIR" <<'PYEOF'
import json, sys, datetime, os
state = os.path.expanduser(sys.argv[4])
os.makedirs(state, exist_ok=True)
json.dump({"ts": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
           "pass": int(sys.argv[1]), "fail": int(sys.argv[2]), "snap": sys.argv[3]},
          open(os.path.join(state, "drill-last.json"), "w"))
PYEOF
    rm -rf "$TARGET"   # drill scratch is disposable once sentinels verified
    [ "$fail" = 0 ] || exit 1
    ;;
  *)
    echo "unknown mode: $MODE (see header)"; exit 2 ;;
esac
