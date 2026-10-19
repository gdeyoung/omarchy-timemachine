#!/usr/bin/env bash
# tm-snapper.sh — one JSON line for the popup's local Snapshots tab.
# Popup-open ONLY (like tm-snapshots.sh): lists LOCAL btrfs/snapper snapshots
# (system @ + home @home) as the wheel user. No root, no network, no endpoints.
#
# status: ok · unavailable (no snapper binary) · denied (no wheel/ACL access)
#         · empty (configs exist, no snapshots) · error
set -u
command -v snapper >/dev/null 2>&1 || { echo '{"status":"unavailable"}'; exit 0; }

python3 - <<'PYEOF'
import glob, json, re, subprocess, sys, time

def out(**kw):
    print(json.dumps(kw))
    sys.exit(0)

cfg_dir = "/etc/snapper/configs"
names = []
# primary: snapper's own view — respects its access model; config FILES are
# often root-only (600), which silently hid the `home` config when the
# probe read them directly (seen live: /etc/snapper/configs/home unreadable
# by wheel while `snapper -c home list` works).
try:
    r0 = subprocess.run(["snapper", "list-configs"], capture_output=True,
                        text=True, timeout=15)
    if r0.returncode == 0:
        for line in r0.stdout.splitlines():
            if "│" not in line:
                continue
            f = [x.strip() for x in line.split("│")]
            if len(f) < 2 or not f[0] or f[0] == "Config":
                continue
            if not re.match(r"^[A-Za-z0-9_-]+$", f[0]):
                continue
            names.append((f[0], f[1]))
except Exception:
    pass
# fallback: direct config-file read (only works where files are readable)
if not names:
    for p in sorted(glob.glob(cfg_dir + "/*")):
        n = p.rsplit("/", 1)[1]
        if "." in n or not re.match(r"^[A-Za-z0-9_-]+$", n):
            continue  # skip backups/edit-suffixes like root.bak-*
        try:
            head = open(p).read(4096)
        except Exception:
            continue
        m = re.search(r'^SUBVOLUME="([^"]+)"', head, re.M)
        if m:
            names.append((n, m.group(1)))

if not names:
    out(status="empty", configs=[])

configs, denied = [], 0
for n, subvol in names:
    try:
        r = subprocess.run(
            ["snapper", "-c", n, "--iso", "list", "--disable-used-space"],
            capture_output=True, text=True, timeout=15)
    except Exception:
        continue
    if r.returncode != 0:
        low = (r.stderr or "").lower()
        if "permission" in low or "denied" in low:
            denied += 1
        continue
    rows = []
    for line in r.stdout.splitlines():
        if "│" not in line or line.lstrip().startswith("#"):
            continue
        f = [x.strip() for x in line.split("│")]
        if len(f) < 7 or not f[0].isdigit():
            continue
        sid, typ, iso, user, cleanup, desc = f[0], f[1], f[3], f[4], f[5], f[6]
        if not iso or iso == "current":
            continue  # row 0 / header artifacts
        t = None
        try:
            import datetime
            t = int(datetime.datetime.fromisoformat(iso).timestamp())
        except Exception:
            pass
        rows.append({"id": int(sid), "iso": iso, "t": t,
                     "type": typ, "cleanup": cleanup,
                     "desc": desc, "user": user})
    rows.sort(key=lambda x: x["id"], reverse=True)
    configs.append({"name": n, "subvol": subvol,
                    "count": len(rows), "rows": rows})

if not configs and denied:
    out(status="denied", configs=[])
out(status="ok" if any(c["count"] for c in configs) else "empty",
    generated=int(time.time()), configs=configs)
PYEOF
