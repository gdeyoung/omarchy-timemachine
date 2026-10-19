#!/usr/bin/env bash
# tm-backups.sh — one JSON line for the popup's Backups + Recovery tabs.
# Popup-open ONLY (never the bar refresh path): reads the backup stamp to
# find the repo target at RUNTIME (host/dest never baked into QML), lists
# backups + mtimes over ssh, joins per-backup size/duration from the
# local history.jsonl, reports tree size + disk free. Endpoints appear in
# this script's OUTPUT (popup-local display/copy strings) but never in QML
# source or the bar probe contract.
#
# status: ok · never (no stamp yet) · empty (tree has no backups)
#         unreachable (ssh/cd failed) · error (stamp unparsable)
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
COMMON=""
for c in "$HERE/bin/tm-common.sh" "$HERE/tm-common.sh"; do
  [ -r "$c" ] && COMMON="$c" && break
done
if [ -n "$COMMON" ]; then . "$COMMON"; load_conf
else
  CONF_FILE="${TM_CONF_FILE:-$HOME/.config/timemachine.conf}"
  # shellcheck disable=SC1090
  [ -r "$CONF_FILE" ] && . "$CONF_FILE"
  TM_STATE_DIR="${TM_STATE_DIR:-$HOME/.local/state/timemachine}"
  TM_SSH_PORT="${TM_SSH_PORT:-22}"
fi
STAMP="$TM_STATE_DIR/last-backup.json"
HIST="$TM_STATE_DIR/history.jsonl"
command -v python3 >/dev/null 2>&1 || { echo '{"status":"error","detail":"python3 missing"}'; exit 0; }

python3 - "$STAMP" "$HIST" "$TM_SSH_PORT" <<'PYEOF'
import json, re, subprocess, sys

stamp_p, hist_p, port = sys.argv[1:4]

def out(**kw):
    print(json.dumps(kw))
    sys.exit(0)

try:
    stamp = json.load(open(stamp_p))
    repo = stamp.get("repo", "")
except Exception:
    out(status="never")
if not repo.startswith("rsync://"):
    out(status="error", detail="stamp repo field unparsable")
body = repo[len("rsync://"):]
host, _, dest = body.partition("/")
if not host or not dest:
    out(status="error", detail="stamp repo field unparsable")
if not dest.startswith("/"):
    dest = "/" + dest  # rsync:// URL form drops the leading slash

# per-backup size/duration from LOCAL history (no remote du per dir)
sizes = {}
try:
    with open(hist_p) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                r = json.loads(line)
                sizes[(r.get("snap") or "")] = (r.get("mb"), r.get("dur_s"))
            except Exception:
                pass
except Exception:
    pass

remote = (
    "cd '%s/backups' 2>/dev/null || exit 9; "
    "for d in *; do [ -d \"$d\" ] && echo \"S $d $(stat -c %%Y \"$d\")\"; done; "
    "echo \"L $(basename $(readlink ../latest 2>/dev/null))\"; "
    "df -B1 . | tail -1"
) % dest
try:
    r = subprocess.run(
        ["ssh", "-p", port, "-o", "ConnectTimeout=8", "-o", "BatchMode=yes", host, remote],
        capture_output=True, text=True, timeout=45)
except Exception:
    out(status="unreachable")

if r.returncode != 0:
    out(status="unreachable", detail="ssh exit " + str(r.returncode))

rows, latest, free_b, total_b = [], "", None, None
for line in r.stdout.splitlines():
    p = line.split()
    if not p:
        continue
    if p[0] == "DU" and len(p) > 1 and p[1].isdigit():
        continue
    if p[0] == "L" and len(p) == 2 and re.match(r"^\d{8}-\d{4}$", p[1]):
        latest = p[1]
        continue
    if p[0] == "S" and len(p) == 3 and re.match(r"^\d{8}-\d{4}$", p[1]):
        try:
            m = sizes.get(p[1]) or (None, None)
            # age derives from the ID (creation stamp) — the dir's own mtime
            # is rsync-preserved from $HOME and is NOT the backup time
            import time as _t
            t = int(_t.mktime(_t.strptime(p[1], "%Y%m%d-%H%M")))
            rows.append({"id": p[1], "t": t,
                         "mb": m[0], "dur_s": m[1]})
        except ValueError:
            pass
        continue
    if len(p) >= 4 and p[1].isdigit() and p[3].isdigit():
        total_b, free_b = int(p[1]), int(p[3])

rows.sort(key=lambda x: x["id"], reverse=True)
prefix = host + ":" + dest + "/backups/"
if not rows:
    out(status="empty", scp_prefix=prefix)
out(status="ok", rows=rows, latest=latest,
    tree_gb=stamp.get("tree_gb"),
    free_gb=round((free_b or 0) / 2**30, 1),
    total_gb=round((total_b or 0) / 2**30, 1),
    scp_prefix=prefix)
PYEOF
