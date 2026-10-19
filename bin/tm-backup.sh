#!/usr/bin/env bash
# tm-backup.sh — Time Machine engine: whole-home → rsync hardlink backups.
#
# Creates backups/<YYYYMMDD-HHMM>/ (complete browsable $HOME copy,
# hardlinked against the previous backup → space ≈ delta) — the transfer is
# staged into a hidden unique dir and renamed into place only on completion —
# then atomically moves `latest`, prunes by retention, verifies sentinels
# weekly, and stamps state for the bar chip.
#
# Config: ~/.config/timemachine.conf (see tm-common.sh for keys/defaults).
# Stamps written to $TM_STATE_DIR:
#   last-backup.json {ts, repo, backup, tree_gb}
#   history.jsonl    {t, mb, dur_s, snap}          (capped at 100)
#   verify-last.json {ts, pass, fail, files}       (on verify day)
#
# Unencrypted by design: backups are plain files browsable over ssh/smb.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/tm-common.sh"
load_conf
SSH="$(ssh_cmd)"

configured || { echo "FATAL: TM_HOST/TM_DEST not set — configure first (tm-conf.sh init)"; exit 1; }
command -v rsync >/dev/null || { echo "FATAL: rsync not on PATH"; exit 1; }
command -v ssh   >/dev/null || { echo "FATAL: ssh not on PATH"; exit 1; }
[ -r "$TM_EXCLUDES" ] || { echo "FATAL: excludes missing ($TM_EXCLUDES — tm-conf.sh init)"; exit 1; }
STAGE="$(stamp_dir)"

# 0. pre-hook (quiesce hot state, commit catalogs — user supplied). A failing
#    pre-hook aborts: better no backup than a known-bad one.
if [ -n "$TM_PRE_HOOK" ]; then
  sh -c "$TM_PRE_HOOK" || { echo "FATAL: TM_PRE_HOOK failed — aborting"; exit 1; }
fi

# 1. backup — hardlink against the previous one
SNAP="$(date +%Y%m%d-%H%M)"
PREV="$($SSH "$TM_HOST" "readlink '$TM_DEST/latest' 2>/dev/null | xargs -r basename" 2>/dev/null || true)"
$SSH "$TM_HOST" "mkdir -p '$TM_DEST/backups'"

# Refuse an existing snapshot destination (marketplace finding @2105f4e): a
# rerun in the same minute as a completed backup must never write into the
# published tree — rsync deltas would corrupt it while latest/stamps still
# report healthy. An existing minute dir is either the published latest
# (nothing to do) or a leftover from a killed run (fail loudly).
if $SSH "$TM_HOST" "test -e '$TM_DEST/backups/$SNAP'"; then
  if [ "$PREV" = "$SNAP" ]; then
    echo "SKIP: backup $SNAP already completed and published this minute — nothing to do (rerun after the minute rolls over to capture new changes)"
    exit 0
  fi
  echo "FATAL: backups/$SNAP already exists but latest is '${PREV:-none}' — refusing to write into an existing tree (leftover from a killed run? quarantine it: mv '$TM_DEST/backups/$SNAP' '$TM_DEST/quarantine-$SNAP' on the host)"
  exit 1
fi
# sweep staging dirs abandoned by killed runs; a live run's staging dir is
# minutes old, so a +1 day age gate can never race an active transfer
$SSH "$TM_HOST" "find '$TM_DEST/backups' -maxdepth 1 -name '.staging.*' -mtime +1 -exec rm -rf -- {} +" 2>/dev/null || true

# Stage the transfer in a fresh, unique dir and publish it by rename only on
# success (maintainer-requested remedy). Hidden (.staging.*) so listers and
# retention never see an incomplete tree.
STG=".staging.$SNAP.$$"

LINKARGS=()
[ -n "${PREV:-}" ] && LINKARGS=(--link-dest="$TM_DEST/backups/$PREV")

T0=$(date +%s)
STATS="$(mktemp)"
# Exit codes: 24 = source files vanished mid-scan (sockets, transient
# partials) — tolerated; the backup is still a complete scan. 23 = partial
# transfer due to ERROR — the backup is incomplete: discard it and leave
# latest, retention and the success stamp untouched (a failed transfer must
# never be presented as a healthy backup while older complete copies pruned).
set +e
rsync -aH --no-D --stats --exclude-from="$TM_EXCLUDES" "${LINKARGS[@]}" \
      -e "ssh -p $TM_SSH_PORT -o ConnectTimeout=15 -o BatchMode=yes" \
      "$HOME/" "$TM_HOST:$TM_DEST/backups/$STG/" >"$STATS" 2>"$STAGE/rsync.err"
RC=$?
set -e
grep -Ev 'skipping non-regular' "$STAGE/rsync.err" | grep -v '^$' | while read -r l; do
  echo "WARN: rsync: $l"
done || true
if [ "$RC" != 0 ] && [ "$RC" != 24 ]; then
  echo "FATAL: rsync exited $RC — staged transfer discarded (nothing published; latest/retention/stamp untouched). See $STAGE/rsync.err"
  # the staging dir is uniquely ours ($$) and was never published — remove it
  $SSH "$TM_HOST" "rm -rf '$TM_DEST/backups/$STG'" \
    || echo "WARN: could not remove staging dir backups/$STG on $TM_HOST — remove manually"
  rm -f "$STATS"
  exit "$RC"
fi
DUR=$(( $(date +%s) - T0 ))

# 2. publish: rename the completed staging dir into its final name first,
#    then atomically point `latest` at it — a published name only ever holds
#    a complete tree, and latest only moves after the rename
if ! $SSH "$TM_HOST" "cd '$TM_DEST/backups' && mv -T '$STG' '$SNAP'"; then
  echo "FATAL: could not publish backups/$SNAP (destination appeared mid-run?) — staged tree kept at backups/$STG for inspection"
  rm -f "$STATS"
  exit 1
fi
$SSH "$TM_HOST" "cd '$TM_DEST' && ln -sfn 'backups/$SNAP' latest.tmp && mv -Tf latest.tmp latest"

# 3. history for the bar chip
python3 - "$STATS" "$STAGE/history.jsonl" "$SNAP" "$DUR" <<'PYEOF'
import json, re, sys, time
stats, hist, snap, dur = sys.argv[1:5]
txt = open(stats).read()
m = re.search(r"Total file size:\s*([\d,]+)", txt)
mb = round(int(m.group(1).replace(",", "")) / 2**20) if m else 0
with open(hist, "a") as f:
    f.write(json.dumps({"t": time.time(), "mb": mb,
                        "dur_s": int(dur), "snap": snap}) + "\n")
lines = open(hist).readlines()
if len(lines) > 100:
    open(hist, "w").writelines(lines[-100:])
PYEOF
rm -f "$STATS"

# 4. retention: N daily / weekly / monthly buckets, newest per bucket kept
SNAPS="$($SSH "$TM_HOST" "ls -1 '$TM_DEST/backups'" 2>/dev/null || true)"
DEL="$(printf '%s\n' "$SNAPS" | TM_RD="$TM_RETENTION_DAILY" TM_RW="$TM_RETENTION_WEEKLY" TM_RM="$TM_RETENTION_MONTHLY" python3 -c '
import sys, os, datetime
names = [l.strip() for l in sys.stdin if l.strip()]
def parse(n):
    try: return datetime.datetime.strptime(n, "%Y%m%d-%H%M")
    except ValueError: return None
pairs = [(n, parse(n)) for n in names]
pairs = [(n, d) for n, d in pairs if d]
keep = {max(pairs, key=lambda x: x[1])[0]}
for keyfn, cnt in [(lambda d: d.date(), int(os.environ["TM_RD"])),
                   (lambda d: d.isocalendar()[:2], int(os.environ["TM_RW"])),
                   (lambda d: (d.year, d.month), int(os.environ["TM_RM"]))]:
    buckets = {}
    for n, d in pairs: buckets.setdefault(keyfn(d), []).append((n, d))
    for b, items in sorted(buckets.items(), reverse=True)[:cnt]:
        keep.add(max(items, key=lambda x: x[1])[0])
for n, d in pairs:
    if n not in keep: print(n)
')"
for d in $DEL; do
  case "$d" in
    [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9])
      $SSH "$TM_HOST" "rm -rf '$TM_DEST/backups/$d'" ;;
    *) echo "REFUSING malformed backup name: $d" ;;
  esac
done

# 5. weekly sentinel verify — persisted BEFORE any exit so failures are
#    inspectable. Sentinels: colon-separated $HOME-relative paths.
if [ "$(date +%u)" = "$TM_VERIFY_DOW" ] && [ -n "$TM_SENTINELS" ]; then
  vpass=0; vfail=0
  NS=0
  IFS=':'
  for s in $TM_SENTINELS; do
    unset IFS
    [ -n "$s" ] || continue
    NS=$((NS+1))
    l=$(sha256sum "$HOME/$s" 2>/dev/null | cut -d' ' -f1)
    r=$(timeout 60 $SSH "$TM_HOST" "sha256sum '$TM_DEST/latest/$s' 2>/dev/null" | cut -d' ' -f1)
    if [ "$l" != "$r" ] || [ -z "$l" ]; then
      echo "VERIFY FAIL: $s (local=${l:0:12} remote=${r:0:12})"; vfail=$((vfail+1))
    else
      vpass=$((vpass+1))
    fi
    IFS=':'
  done
  unset IFS
  cat > "$STAGE/verify-last.json" <<EOF
{"ts":"$(date -u +%FT%TZ)","pass":$vpass,"fail":$vfail,"files":$NS}
EOF
  [ "$vfail" = 0 ] && echo "verify: $NS sentinels OK" || exit 1
fi

# 6. stamp (age for healthcheck) + tree size for the popup capacity card
# timeout: du on a large tree over ssh MUST be bounded — an unbounded call
# hung the 20261024-0154 run post-publish (stamp never written; unit wedged
# into suspend). Fallback keeps the JSON valid.
TREE_GB=$(timeout 240 $SSH "$TM_HOST" "du -sb '$TM_DEST/backups' 2>/dev/null | cut -f1" 2>/dev/null \
          | awk '{printf "%.1f", $1/1073741824}')
TREE_GB="${TREE_GB:-0}"
cat > "$STAGE/last-backup.json" <<EOF
{"ts":"$(date -u +%FT%TZ)","repo":"rsync://$TM_HOST$TM_DEST","backup":"$SNAP","tree_gb":$TREE_GB}
EOF

# 7. post-hook (reports, cleanup). Failure warns but does not fail the backup.
if [ -n "$TM_POST_HOOK" ]; then
  sh -c "$TM_POST_HOOK" || echo "WARN: TM_POST_HOOK failed (backup is complete)"
fi

echo "OK — backup $SNAP @ $(date -u +%FT%TZ) (${DUR}s)"
