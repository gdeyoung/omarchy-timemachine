#!/usr/bin/env bash
# tm-conf.sh — configuration bridge for the Time Machine plugin.
# The QML settings surface NEVER writes files directly: everything goes
# through this script. Read-only: get / json / test. Mutating: init / set /
# install / uninstall (uninstall requires --yes).
#
#   tm-conf.sh init                 write starter conf + excludes file
#   tm-conf.sh get KEY              print one value
#   tm-conf.sh set KEY VAL          validate + persist one key
#   tm-conf.sh json                 full config as one JSON line (for QML)
#   tm-conf.sh test                 ssh reachability probe → JSON line
#   tm-conf.sh install              write+enable systemd unit/timer
#   tm-conf.sh uninstall --yes      disable + remove unit/timer (data untouched)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/tm-common.sh"
load_conf

KEYS="TM_HOST TM_DEST TM_SSH_PORT TM_LABEL TM_STATE_DIR TM_EXCLUDES \
TM_RETENTION_DAILY TM_RETENTION_WEEKLY TM_RETENTION_MONTHLY TM_VERIFY_DOW \
TM_SENTINELS TM_DRIFT_FILE TM_PRE_HOOK TM_POST_HOOK TM_SCHEDULE TM_UNIT TM_MAX_AGE_H TM_NOTIFY_CMD"

valid_key() { case " $KEYS " in *" $1 "*) return 0;; *) return 1;; esac; }

ensure_conf_file() {
  touch "$CONF_FILE"
  chmod 600 "$CONF_FILE"   # may hold an ssh target; keep it user-only
}

cmd_init() {
  ensure_conf_file
  if [ ! -r "$TM_EXCLUDES" ]; then
    mkdir -p "$(dirname "$TM_EXCLUDES")"
    cat > "$TM_EXCLUDES" <<'EOF'
# timemachine rsync excludes — one pattern per line (rsync syntax).
# Leading / anchors to $HOME. Dirs need a trailing slash to match dirs only.
.cache/
.config/google-chrome/
.local/share/Trash/
.local/share/Steam/
.docker/
# NOTE: excluding .ssh means recovery needs your keys from elsewhere —
# consider keeping it backed up and relying on remote hardlink dedup instead.
EOF
  fi
  echo "initialized: $CONF_FILE (excludes starter: $TM_EXCLUDES)"
}

cmd_set() {
  local key="$1" val="$2"
  valid_key "$key" || { echo "unknown key: $key (valid: $KEYS)" >&2; exit 2; }
  case "$key" in
    TM_SSH_PORT|TM_RETENTION_*|TM_VERIFY_DOW|TM_MAX_AGE_H)
      [[ "$val" =~ ^[0-9]+$ ]] || { echo "$key must be numeric" >&2; exit 2; } ;;
    TM_SCHEDULE)
      [[ "$val" =~ ^([01][0-9]|2[0-3]):[0-5][0-9](,([01][0-9]|2[0-3]):[0-5][0-9])*$ ]] \
        || { echo "TM_SCHEDULE must be HH:MM[,HH:MM…]" >&2; exit 2; } ;;
  esac
  ensure_conf_file
  if grep -q "^${key}=" "$CONF_FILE" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${val}|" "$CONF_FILE"
  else
    printf '%s=%s\n' "$key" "$val" >> "$CONF_FILE"
  fi
  echo "set ${key}"
}

cmd_json() {
  configured && CFG=1 || CFG=0
  local timer_active=false next=""
  if systemctl --user is-active "$TM_UNIT.timer" >/dev/null 2>&1; then
    timer_active=true
    next="$(systemctl --user list-timers "$TM_UNIT.timer" --no-legend 2>/dev/null | awk '{print $1" "$2}' | head -1)"
  fi
  [ "$timer_active" = true ] && TFLAG=1 || TFLAG=0
  CFG=$CFG TFLAG=$TFLAG NEXT="$next" python3 - "$CONF_FILE" <<'PYEOF'
import os, sys, json
conf = os.path.expanduser(sys.argv[1])
vals = {}
if os.path.isfile(conf):
    for line in open(conf):
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, v = line.split("=", 1)
            vals[k] = v
def val(k, d):
    v = vals.get(k, d)
    if isinstance(v, str) and len(v) >= 2 and v[0] == v[-1] and v[0] in "'\"":
        v = v[1:-1]  # conf may quote values with spaces
    return os.path.expanduser(v)
sent = [s for s in val("TM_SENTINELS", "").split(":") if s]
print(json.dumps({
  "configured": os.environ["CFG"] == "1",
  "host": val("TM_HOST", ""),
  "dest": val("TM_DEST", ""),
  "port": int(val("TM_SSH_PORT", "22") or 22),
  "label": val("TM_LABEL", "") or (val("TM_HOST", "").split("@")[-1].split(".")[0] or ""),
  "state_dir": val("TM_STATE_DIR", "~/.local/state/timemachine"),
  "excludes": val("TM_EXCLUDES", "~/.config/timemachine-excludes.txt"),
  "retention": {"daily": int(val("TM_RETENTION_DAILY", "14") or 14),
                "weekly": int(val("TM_RETENTION_WEEKLY", "8") or 8),
                "monthly": int(val("TM_RETENTION_MONTHLY", "12") or 12)},
  "schedule": val("TM_SCHEDULE", "09:20,21:20"),
  "unit": val("TM_UNIT", "timemachine-backup"),
  "max_age_h": int(val("TM_MAX_AGE_H", "30") or 30),
  "sentinels": sent,
  "drift_file": val("TM_DRIFT_FILE", ""),
  "notify": val("TM_NOTIFY_CMD", ""),
  "pre_hook": vals.get("TM_PRE_HOOK", ""),
  "post_hook": vals.get("TM_POST_HOOK", ""),
  "timer_installed": os.environ["TFLAG"] == "1",
  "timer_next": os.environ.get("NEXT", "")
}))
PYEOF
}

cmd_test() {
  configured || { echo '{"ok":false,"detail":"not configured"}'; exit 0; }
  SSH="$(ssh_cmd)"
  OUT=$($SSH "$TM_HOST" "mkdir -p '$TM_DEST/backups' && df -B1 '$TM_DEST' | tail -1 && ls -1 '$TM_DEST/backups' 2>/dev/null | wc -l" 2>&1) || {
    DETAIL="$(printf '%s' "$OUT" | tail -1)"
    case "$DETAIL" in
      *"Permission denied"*|*"denied"*) D="auth failed — ssh key not accepted for $TM_HOST";;
      *"No route"*|*"timed out"*|*"refused"*|*"unreachable"*) D="unreachable — $TM_HOST:$TM_SSH_PORT";;
      *) D="ssh failed: ${DETAIL:0:120}";;
    esac
    echo "{\"ok\":false,\"detail\":\"$D\"}"; exit 0
  }
  LINE=$(printf '%s' "$OUT" | grep -m1 ' /')
  N=$(printf '%s' "$OUT" | tail -1)
  python3 - "$LINE" "$N" <<'PYEOF'
import sys, json
f = sys.argv[1].split()
n = int(sys.argv[2] or 0)
gb = lambda b: round(int(b) / 2**30, 1)
print(json.dumps({"ok": True, "detail": "reachable",
                  "free_gb": gb(f[3]), "total_gb": gb(f[1]), "backup_count": n}))
PYEOF
}

write_units() {  # $1 = target dir
  local dir="$1" bin="$HERE/tm-backup.sh"
  mkdir -p "$dir"
  cat > "$dir/$TM_UNIT.service" <<EOF
[Unit]
Description=Time Machine backup (whole-home rsync backups)

[Service]
Type=oneshot
Environment=PATH=%h/.local/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=$bin
Nice=10
IOSchedulingClass=idle
TimeoutStartSec=6h
EOF
  : > "$dir/$TM_UNIT.timer"
  {
    echo "[Unit]"
    echo "Description=Time Machine backup schedule"
    echo ""
    echo "[Timer]"
    IFS=','; for slot in $TM_SCHEDULE; do
      echo "OnCalendar=*-*-* ${slot}:00"
    done
    unset IFS
    echo "Persistent=true"
    echo "RandomizedDelaySec=300"
    echo ""
    echo "[Install]"
    echo "WantedBy=timers.target"
  } > "$dir/$TM_UNIT.timer"
}

cmd_install() {
  write_units "$HOME/.config/systemd/user"
  systemctl --user daemon-reload
  systemctl --user enable --now "$TM_UNIT.timer"
  echo "installed: $TM_UNIT.timer ($(echo "$TM_SCHEDULE" | tr ',' ' '))"
}

cmd_uninstall() {
  [ "${1:-}" = "--yes" ] || { echo "refusing: pass --yes (data on the backup host is NOT touched)" >&2; exit 2; }
  systemctl --user disable --now "$TM_UNIT.timer" 2>/dev/null || true
  rm -f "$HOME/.config/systemd/user/$TM_UNIT.service" "$HOME/.config/systemd/user/$TM_UNIT.timer"
  systemctl --user daemon-reload
  echo "removed timer (backups on $TM_HOST untouched)"
}

case "${1:-}" in
  init) cmd_init ;;
  get)  load_conf; eval "printf '%s\n' \"\${${2:-}}\"" ;;
  set)  shift; cmd_set "$@" ;;
  json) cmd_json ;;
  test) cmd_test ;;
  install) cmd_install ;;
  uninstall) shift; cmd_uninstall "$@" ;;
  *)    sed -n '2,12p' "$0"; exit 2 ;;
esac
