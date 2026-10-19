#!/usr/bin/env bash
# tm-common.sh — shared config loader for the Time Machine engine scripts.
# Sourced by tm-backup.sh / tm-restore.sh / tm-health.sh / tm-conf.sh.
#
# Single source of truth: ~/.config/timemachine.conf (key=value, bash-sourceable).
# Precedence: environment variable > conf file > default. Env overrides exist
# for testing and one-off runs; the conf file is what the popup Settings tab
# writes via tm-conf.sh.

CONF_FILE="${TM_CONF_FILE:-$HOME/.config/timemachine.conf}"

load_conf() {
  # shellcheck disable=SC1090
  [ -r "$CONF_FILE" ] && . "$CONF_FILE"
  TM_HOST="${TM_HOST:-}"
  TM_DEST="${TM_DEST:-}"
  TM_SSH_PORT="${TM_SSH_PORT:-22}"
  TM_LABEL="${TM_LABEL:-$(printf '%s' "${TM_HOST#*@}" | cut -d. -f1)}"
  TM_STATE_DIR="${TM_STATE_DIR:-$HOME/.local/state/timemachine}"
  TM_EXCLUDES="${TM_EXCLUDES:-$HOME/.config/timemachine-excludes.txt}"
  TM_RETENTION_DAILY="${TM_RETENTION_DAILY:-14}"
  TM_RETENTION_WEEKLY="${TM_RETENTION_WEEKLY:-8}"
  TM_RETENTION_MONTHLY="${TM_RETENTION_MONTHLY:-12}"
  TM_VERIFY_DOW="${TM_VERIFY_DOW:-7}"        # 1=Mon … 7=Sun
  TM_SENTINELS="${TM_SENTINELS:-}"           # colon-separated, $HOME-relative
  TM_DRIFT_FILE="${TM_DRIFT_FILE:-}"         # optional drift report (NEW-UNMANAGED/SIZE-JUMP lines)
  TM_PRE_HOOK="${TM_PRE_HOOK:-}"             # sh -c, runs before rsync
  TM_POST_HOOK="${TM_POST_HOOK:-}"           # sh -c, runs after stamps
  TM_SCHEDULE="${TM_SCHEDULE:-09:20,21:20}"  # comma list → OnCalendar lines
  TM_UNIT="${TM_UNIT:-timemachine-backup}"
  TM_MAX_AGE_H="${TM_MAX_AGE_H:-30}"
  TM_NOTIFY_CMD="${TM_NOTIFY_CMD:-}"         # sh -c on health failure
}

ssh_cmd() {  # port-aware ssh with sane timeouts; caller appends args
  printf 'ssh -p %s -o ConnectTimeout=15 -o BatchMode=yes' "$TM_SSH_PORT"
}

configured() { [ -n "$TM_HOST" ] && [ -n "$TM_DEST" ]; }

stamp_dir() { mkdir -p "$TM_STATE_DIR"; printf '%s' "$TM_STATE_DIR"; }
