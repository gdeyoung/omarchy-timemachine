#!/usr/bin/env bash
# tm-health.sh — Time Machine healthcheck: stamp age + tree reachability.
# Healthy = one quiet line + a green health-last.json stamp. Failure prints
# detail, stamps red, and runs TM_NOTIFY_CMD (if set) — silence means green.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/tm-common.sh"
load_conf
SSH="$(ssh_cmd)"
STAMP="$TM_STATE_DIR/last-backup.json"
HSTAMP="$TM_STATE_DIR/health-last.json"

mkdir -p "$TM_STATE_DIR"

stamp_health() {  # $1 = "true"/"false", $2 = detail line
  printf '{"ts":"%s","ok":%s,"detail":%s}\n' "$(date -u +%FT%TZ)" "$1" \
    "$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$2" 2>/dev/null || echo '""')" \
    > "$HSTAMP" 2>/dev/null || true
}

fail() { echo "TIME MACHINE HEALTH: $*"; stamp_health false "$*"
  [ -n "$TM_NOTIFY_CMD" ] && sh -c "$TM_NOTIFY_CMD" >/dev/null 2>&1
  exit 1; }

[ -r "$STAMP" ] || fail "no stamp file — tm-backup.sh has never completed"
ts=$(python3 -c 'import json;print(json.load(open("'$STAMP'"))["ts"])' 2>/dev/null)
age_h=$(python3 -c "from datetime import datetime,timezone;print(round((datetime.now(timezone.utc)-datetime.fromisoformat('$ts')).total_seconds()/3600,1))" 2>/dev/null)
[ -n "$age_h" ] || fail "stamp unreadable: $STAMP"
awk -v a="$age_h" -v m="$TM_MAX_AGE_H" 'BEGIN{exit !(a>m)}' && fail "last backup ${age_h}h old (stamp $ts)"

# backup tree reachable + non-empty (skip probe if offline — stamp age gates)
if command -v ssh >/dev/null; then
  n=$(timeout 60 $SSH "$TM_HOST" "ls -1 '$TM_DEST/backups' 2>/dev/null | wc -l" 2>/dev/null)
  if [ -n "$n" ] && [ "$n" -gt 0 ] 2>/dev/null; then
    stamp_health true "last backup ${age_h}h ago, $n backups on $TM_LABEL"
    echo "TIME MACHINE HEALTH: OK — last backup ${age_h}h ago, $n backups on $TM_LABEL"
    exit 0
  fi
  fail "backup tree unreachable or empty ($TM_HOST:$TM_DEST)"
fi
stamp_health true "stamp ${age_h}h old; ssh probe skipped"
echo "TIME MACHINE HEALTH: OK (stamp ${age_h}h old; ssh probe skipped)"
