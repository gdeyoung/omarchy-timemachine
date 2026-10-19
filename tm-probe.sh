#!/usr/bin/env bash
# tm-probe.sh — one JSON line for the Time Machine bar chip.
# Cheap and local-only (never blocks the bar): reads stamps written by
# tm-backup.sh / tm-restore.sh / tm-health.sh (state dir from
# ~/.config/timemachine.conf), plus systemctl --user for run state and next
# timer fire. Optional argv: [stale_h] [fail_h] override the default
# 26h/72h state thresholds (env TM_STALE_H / TM_FAIL_H only if argv absent).
# Endpoints/credentials are deliberately NEVER emitted.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
COMMON=""
for c in "$HERE/tm-common.sh" "$HERE/bin/tm-common.sh"; do
  [ -r "$c" ] && COMMON="$c" && break
done
if [ -n "$COMMON" ]; then . "$COMMON"; load_conf
else  # deployed beside QML without bin/ — minimal fallbacks + raw conf parse
  CONF_FILE="${TM_CONF_FILE:-$HOME/.config/timemachine.conf}"
  # shellcheck disable=SC1090
  [ -r "$CONF_FILE" ] && . "$CONF_FILE"
  TM_STATE_DIR="${TM_STATE_DIR:-$HOME/.local/state/timemachine}"
  TM_UNIT="${TM_UNIT:-timemachine-backup}"
  TM_LABEL="${TM_LABEL:-}"
  TM_DRIFT_FILE="${TM_DRIFT_FILE:-}"
  TM_HOST="${TM_HOST:-}"; TM_DEST="${TM_DEST:-}"
  configured() { [ -n "$TM_HOST" ] && [ -n "$TM_DEST" ]; }
fi
command -v python3 >/dev/null 2>&1 || { echo '{"engine":"missing"}'; exit 0; }
STALE_ARG="${1:-${TM_STALE_H:-}}"
FAIL_ARG="${2:-${TM_FAIL_H:-}}"
configured && CFG=1 || CFG=0
CFG=$CFG STATE="$TM_STATE_DIR" UNIT="$TM_UNIT" LABEL="$TM_LABEL" DRIFT="$TM_DRIFT_FILE" \
SCHED="$TM_SCHEDULE" RD="$TM_RETENTION_DAILY" RW="$TM_RETENTION_WEEKLY" RM="$TM_RETENTION_MONTHLY" \
STALE_ARG="$STALE_ARG" FAIL_ARG="$FAIL_ARG" python3 <<'PYEOF'
import datetime as dt, json, os, subprocess, sys, time

env = os.environ
STALE_H = float(env["STALE_ARG"]) if env.get("STALE_ARG") else 26.0
FAIL_H = float(env["FAIL_ARG"]) if env.get("FAIL_ARG") else 72.0
STATE = env.get("STATE", "")
UNIT = env.get("UNIT", "timemachine-backup")
SERVICE = f"{UNIT}.service"
TIMER = f"{UNIT}.timer"
LABEL = env.get("LABEL", "")


def read_json(path):
    try:
        with open(path) as f:
            return json.load(f)
    except Exception:
        return None


def svc_active(unit):
    try:
        return subprocess.run(
            ["systemctl", "--user", "is-active", "--quiet", unit],
            timeout=3).returncode == 0
    except Exception:
        return False


def next_fire():
    try:
        raw = subprocess.run(
            ["systemctl", "--user", "show", TIMER, "--value",
             "--property=NextElapseUSecRealtime"],
            capture_output=True, text=True, timeout=3).stdout.strip()
        # "Sun 2026-10-18 21:20:31 CDT" (day-of-week prefix)
        t = dt.datetime.strptime(raw.split(" ", 1)[1][:19], "%Y-%m-%d %H:%M:%S")
        now = dt.datetime.now()
        day = "today" if t.date() == now.date() else (
            "tomorrow" if (t.date() - now.date()).days == 1 else t.strftime("%a"))
        return f"{day} {t.strftime('%H:%M')}"
    except Exception:
        return None


out = {"engine": "ok", "repo": LABEL, "label": LABEL,
       "configured": env.get("CFG") == "1", "unit": UNIT}

stamp = read_json(os.path.join(STATE, "last-backup.json"))
age_h = None
if stamp and stamp.get("ts"):
    try:
        ts = dt.datetime.strptime(stamp["ts"], "%Y-%m-%dT%H:%M:%SZ")
        age_h = (time.time() - ts.replace(tzinfo=dt.timezone.utc).timestamp()) / 3600
    except Exception:
        pass

running = svc_active(SERVICE)
if running:
    state = "running"
elif env.get("CFG") != "1":
    state = "never"          # not configured → onboarding state
elif age_h is None:
    state = "never"
elif age_h < STALE_H:
    state = "ok"
elif age_h < FAIL_H:
    state = "stale"
else:
    state = "fail"

out.update({
    "state": state,
    "age_h": round(age_h, 2) if age_h is not None else None,
    "last_iso": stamp.get("ts") if stamp else None,
    "backup": (stamp.get("backup") or stamp.get("snapshot") or "")[:8] if stamp else "",
    "next_run": next_fire(),
    "timer_installed": svc_active(TIMER),
    "schedule": env.get("SCHED", "09:20,21:20"),
    "retention": {"daily": int(env.get("RD") or 14),
                  "weekly": int(env.get("RW") or 8),
                  "monthly": int(env.get("RM") or 12)},
    "thresholds": {"stale_h": STALE_H, "fail_h": FAIL_H},
})

# history for the graph: newest 28 {t, v} entries
hist = []
try:
    with open(os.path.join(STATE, "history.jsonl")) as f:
        lines = [l for l in f.read().splitlines() if l.strip()]
    for line in lines[-28:]:
        try:
            r = json.loads(line)
            hist.append({"t": r.get("t"), "v": r.get("mb", 0),
                         "d": r.get("dur_s"), "s": (r.get("snap") or "")[:8]})
        except Exception:
            continue
except Exception:
    pass
out["history"] = hist
out["backups_n"] = len(hist)
if hist:
    last = hist[-1]
    out["size_mb"] = last.get("v")
    out["dur_s"] = last.get("d")

drill = read_json(os.path.join(STATE, "drill-last.json"))
out["drill"] = drill  # {ts, pass, fail, snap} or null

# weekly sentinel verify — {ts, pass, fail, files} or null
verify = read_json(os.path.join(STATE, "verify-last.json"))
if verify:
    out["verify"] = {"ts": verify.get("ts"), "pass": verify.get("pass"),
                     "fail": verify.get("fail"), "files": verify.get("files")}

# last health run — {ts, ok} or null
health = read_json(os.path.join(STATE, "health-last.json"))
if health:
    out["health"] = {"ts": health.get("ts"), "ok": bool(health.get("ok"))}

# optional drift report (TM_DRIFT_FILE; absent → clean)
drift = {"clean": True, "new_unmanaged": 0, "size_jump": 0}
try:
    with open(env.get("DRIFT", "")) as f:
        for line in f:
            if line.startswith("NEW-UNMANAGED"):
                drift["new_unmanaged"] += 1
                drift["clean"] = False
            elif line.startswith("SIZE-JUMP"):
                drift["size_jump"] += 1
                drift["clean"] = False
except Exception:
    pass
out["drift"] = drift

print(json.dumps(out))
PYEOF
