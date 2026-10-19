// Pins the gdeyoung.timemachine wiring: chip states, probe bridge, popup
// sections, action delegation, IPC surface, manifest schema, and the probe
// script's live JSON contract. Run: node --test tests/
import test from "node:test"
import assert from "node:assert/strict"
import { readFileSync, existsSync, mkdirSync, rmSync, writeFileSync,
  chmodSync, readdirSync, readlinkSync, symlinkSync } from "node:fs"
import { execFileSync } from "node:child_process"
import { fileURLToPath } from "node:url"
import { dirname, join } from "node:path"
import { tmpdir } from "node:os"

const root = join(dirname(fileURLToPath(import.meta.url)), "..")
const read = (f) => readFileSync(join(root, f), "utf8")

const bw = read("BarWidget.qml")
const dp = read("DetailPopup.qml")
const manifest = JSON.parse(read("manifest.json"))

test("widget extends the house BarWidget base and names its module", () => {
  assert.match(bw, /BarWidget \{/)
  assert.match(bw, /moduleName: "gdeyoung\.timemachine"/)
})

test("chip state machine maps to house status colors", () => {
  for (const [st, color] of [["ok", "#3fb950"], ["running", "#7aa2f7"],
    ["stale", "#e5c07b"], ["fail", "#f7768e"]]) {
    assert.ok(bw.includes(`state === "${st}"`), `state ${st} handled`)
    assert.ok(bw.includes(color), `color ${color} present`)
  }
})

test("chip is the nf-fa-history glyph colored by state (no age text on the bar)", () => {
  assert.match(bw, /text: "\\uF1DA"/)          // clock + ccw arrow
  assert.match(bw, /color: root\.stateColor/)  // green/amber/red severity
  assert.ok(!/text: root\.ageText\s*\n?\s*font/.test(bw)) // age lives in tooltip only
})

test("probe bridge resolves tm-probe.sh beside the QML", () => {
  assert.match(bw, /Qt\.resolvedUrl\("tm-probe\.sh"\)/)
  assert.ok(existsSync(join(root, "tm-probe.sh")))
})

test("actions delegate to systemd unit (probe-driven) and bundled tm-restore.sh", () => {
  assert.match(bw, /systemctl", "--user", "start",/)
  assert.match(bw, /root\.probe\.unit \|\| "timemachine-backup"/)
  assert.match(bw, /bin\/tm-restore\.sh/)
  assert.match(bw, /"--drill"/)
  assert.match(bw, /"--list"/)
  assert.match(bw, /function backupNow\(\)/)
  assert.match(bw, /function runDrill\(\)/)
  assert.match(bw, /SplitParser \{ onRead: function\(line\)/) // house signal name (not onStdout)
})

test("click + tooltip + popup wiring follows the house idiom", () => {
  assert.match(bw, /bar\.showTooltip\(root, root\.tooltip\)/)
  assert.match(bw, /detailPopup\.open = true/)
  assert.match(bw, /DetailPopup \{/)
})

test("IPC surface: summon/toggle/refresh/tab", () => {
  assert.match(bw, /target: "gdeyoung\.timemachine"/)
  assert.match(bw, /function summon\(\): void/)
  assert.match(bw, /function toggle\(\): void/)
  assert.match(bw, /function tab\(n: int\): void/)
})

test("popup uses PopupCard with fitted sizing and the six data tabs", () => {
  assert.match(dp, /PopupCard \{/)
  assert.match(dp, /fittedContentWidth\(Style\.space\(520\)\)/)   // v0.5: 680 → 520 (six tabs one line)
  assert.match(dp, /fittedContentHeight\(col\.implicitHeight\)/)
  assert.match(dp, /SizeBars \{/)
  assert.match(dp, /RUN DRILL/)       // actions live in the popup
  assert.match(dp, /BACK UP NOW/)
  assert.match(dp, /SNAPSHOTS/)
  assert.match(dp, /retention " \+ ret\.daily/) // footer states policy (dynamic, null-guarded)
})

test("popup buttons delegate to the host widget, never spawn their own logic", () => {
  assert.match(dp, /w\.backupNow\(\)/)
  assert.match(dp, /w\.runDrill\(\)/)
  assert.match(dp, /w\.showRepo\(\)/)
})

test("v0.5 tab structure: tab bar, six pages, shared components", () => {
  assert.match(dp, /component TabPill/)
  assert.match(dp, /component DayGroup/)     // collapsible day picker (backups + snapshots)
  assert.match(dp, /component TypeBadge/)    // snapshot type word+hue (WCAG 1.4.1)
  assert.match(dp, /component HealthRow/)
  assert.match(dp, /component CommandRow/)
  assert.match(dp, /component StatePill/)
  for (const label of ["STATUS", "BACKUPS", "SNAPSHOTS", "HEALTH", "RECOVERY", "SETTINGS"]) {
    assert.ok(dp.includes(`label: "${label}"`), `${label} tab present`)
  }
  // keyboard tab mechanics + in-memory reset on open
  assert.match(dp, /Key_1.*Key_2.*Key_3.*Key_4.*Key_5.*Key_6/s)
  assert.match(dp, /Key_Left.*currentTab \+ 5.*% 6/s)
  assert.match(dp, /popup\.currentTab = 0/)      // reset in onOpenChanged
  assert.match(dp, /Key_Escape.*open = false/s)
})

test("backups tab states + snapshots tab states + recovery card spelled out", () => {
  for (const s of ["reading \" + w.label", "unreachable", "RETRY",
    "no backups on \" + w.label + \" yet", "showing first", "latest",
    "BROWSE", "RECOVER", "COPY PATH"]) {
    assert.ok(dp.includes(s), `"${s}" present`)
  }
  // v0.5 local-snapshots tab: its own states + section headers + controls
  for (const s of ["reading local snapshots", "snapper not installed",
    "no local snapshots yet", "SYSTEM @", "HOME @HOME",
    "SNAPSHOT NOW", "recover-from-snapshot", "localSnapPath"]) {
    assert.ok(dp.includes(s), `"${s}" present`)
  }
  // day-picker toggle must reassign a FRESH object — same-reference
  // reassignment never emits changed (var-property identity compare) and
  // carets go dead (owner-reported 2026-10-20)
  assert.match(dp, /for \(var k in src\) d\[k\] = src\[k\]/)
  assert.match(dp, /recovering from /)                 // preselect banner
  assert.match(dp, /Files are plaintext on \" \+ w\.label/) // reassurance headline (label-driven)
  assert.match(dp, /restore = merge \(ask first\)/)
  assert.match(dp, /merge, never overwrite — ask before restoring/)
})

test("popup delegates copy/fetch to the host; capacity title keeps showRepo", () => {
  assert.match(dp, /w\.copyText\(/)
  assert.match(dp, /host\.fetchSnapshots\(\)/)
  assert.match(dp, /fetchSnapshots\(\)/)   // called on popup open
})

test("host owns both fetches + argv-safe clipboard (foyer pattern)", () => {
  assert.match(bw, /function fetchSnapshots\(\)/)
  assert.match(bw, /function fetchSnapper\(\)/)   // v0.5: local snapshots feed
  assert.match(bw, /function openPath\(/)         // v0.5.1: xdg-open snapshot browse
  assert.match(bw, /"xdg-open", p/)
  assert.match(bw, /function createSnapshots\(\)/) // v0.5.1: manual pair (wheel)
  assert.match(bw, /"snapper", "-c", "root", "create"/)
  assert.match(bw, /function copyText\(/)
  assert.match(bw, /tm-backups\.sh/)               // v0.5: renamed lister
  assert.match(bw, /tm-snapper\.sh/)               // v0.5: local snapshot probe
  assert.match(bw, /base64 -d \| exec wl-copy/)
  assert.match(bw, /stdinEnabled: true/)
  assert.ok(!/wl-copy[^\n]*["'][^"]*scp/.test(bw), "no paths ride argv")
})

test("backups bridge script emits a parseable status line (live)", () => {
  const out = execFileSync(join(root, "tm-backups.sh"), { timeout: 60000 })
  const j = JSON.parse(out.toString().trim())
  assert.ok(["ok", "empty", "never", "unreachable", "error"].includes(j.status))
  if (j.status === "ok") {
    assert.ok(Array.isArray(j.rows) && j.rows.length > 0)
    assert.match(j.rows[0].id, /^\d{8}-\d{4}$/)
    assert.ok(typeof j.rows[0].t === "number")   // age from ID, not dir mtime
    assert.ok(j.latest && j.scp_prefix.includes(":/"))
    assert.ok(j.scp_prefix.includes("/backups/"), "remote tree is backups/ (v0.5 rename)")
  }
})

test("legacy tm-snapshots.sh shim still answers (one-release compat)", () => {
  const out = execFileSync(join(root, "tm-snapshots.sh"), { timeout: 60000 })
  assert.ok(JSON.parse(out.toString().trim()).status, "shim execs tm-backups.sh")
})

test("v0.5 terminology: engine addresses the remote tree as backups/ only", () => {
  for (const f of ["bin/tm-backup.sh", "bin/tm-restore.sh", "bin/tm-health.sh",
                   "bin/tm-conf.sh", "tm-backups.sh", "bin/timemachine.conf.example"]) {
    const t = read(f)
    assert.ok(!t.includes("TM_DEST/snapshots"), `${f} free of snapshots/ paths`)
    assert.ok(!t.includes("DEST + \"/snapshots"), `${f} free of snapshots/ paths`)
  }
  const rb = read("bin/tm-restore.sh")
  assert.match(rb, /--backup/)   // new primary mode
  assert.match(rb, /--snapshot/) // legacy alias accepted one release
})

test("snapper bridge script emits a parseable local-snapshot line (live)", () => {
  const out = execFileSync(join(root, "tm-snapper.sh"), { timeout: 30000 })
  const j = JSON.parse(out.toString().trim())
  assert.ok(["ok", "empty", "denied", "unavailable"].includes(j.status))
  if (j.status === "ok") {
    assert.ok(Array.isArray(j.configs) && j.configs.length > 0)
    for (const c of j.configs) {
      assert.ok(["root", "home"].includes(c.name), `config ${c.name} known`)
      assert.ok(typeof c.count === "number")
      for (const r of c.rows.slice(0, 3)) {
        assert.ok(Number.isInteger(r.id))
        assert.match(r.iso, /^\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}/)
        assert.ok(["single", "pre", "post"].includes(r.type))
      }
    }
    assert.ok(!JSON.stringify(j).includes("192.168"), "no LAN endpoints leak")
  }
})

test("public-prep hygiene: no LAN endpoints baked into any QML source", () => {
  for (const f of ["BarWidget.qml", "DetailPopup.qml", "SizeBars.qml"]) {
    assert.ok(!read(f).includes("192.168"), `${f} free of LAN endpoints`)
  }
})

test("manifest: id/version/entrypoint/kind and bounded refresh setting", () => {
  assert.equal(manifest.id, "gdeyoung.timemachine")
  assert.ok(/^\d+\.\d+\.\d+$/.test(manifest.version))
  assert.equal(manifest.entryPoints.barWidget, "BarWidget.qml")
  assert.ok(manifest.kinds.includes("bar-widget"))
  const rs = manifest.barWidget.schema.find((s) => s.key === "refreshSeconds")
  assert.equal(rs.min, 5)
  assert.equal(rs.max, 60)
  assert.equal(manifest.barWidget.defaults.refreshSeconds, 15)
})

test("settings: threshold + view settings exposed with sane bounds and defaults", () => {
  const want = { staleHours: 26, failHours: 72, historyDays: 14, snapshotRows: 10 }
  for (const [key, def] of Object.entries(want)) {
    const s = manifest.barWidget.schema.find((x) => x.key === key)
    assert.ok(s, `${key} in schema`)
    assert.equal(s.type, "integer")
    assert.equal(s.defaultValue, def)
    assert.ok(s.min < def && def <= s.max, `${key} bounds sane`)
    assert.equal(manifest.barWidget.defaults[key], def)
  }
  assert.match(bw, /staleHours: Math\.max\(1/)
  assert.match(bw, /failHours: Math\.max\(staleHours \+ 1/) // fail always > stale
  // thresholds flow to the probe as argv (probe contract: argv[7]=stale argv[8]=fail)
  assert.match(bw, /String\(root\.staleHours\), String\(root\.failHours\)/)
})

test("probe script emits a parseable JSON status line (live contract)", () => {
  const out = execFileSync(join(root, "tm-probe.sh"), { timeout: 10000 })
  const j = JSON.parse(out.toString().trim())
  assert.equal(j.engine, "ok")
  assert.ok(["ok", "stale", "fail", "never", "running"].includes(j.state))
  assert.ok(Array.isArray(j.history))
  assert.ok(typeof j.label === "string" && typeof j.repo === "string")
  assert.ok(j.thresholds && j.thresholds.stale_h === 26 && j.thresholds.fail_h === 72)
  assert.ok("drift" in j && typeof j.drift.clean === "boolean")
  if ("verify" in j) assert.ok(j.verify.ts && j.verify.pass + j.verify.fail === j.verify.files)
  if ("health" in j) assert.ok("ok" in j.health && "ts" in j.health)
  assert.ok(!JSON.stringify(j).includes("192.168"), "no LAN endpoints leak")
  assert.ok(!JSON.stringify(j).includes("sftp:"), "no repo URL leaks")
})

test("v0.4.0 engine: conf bridge round-trip + validation (scratch conf)", () => {
  const scratch = `${tmpdir()}/tm-conf-test-${process.pid}`
  mkdirSync(scratch, { recursive: true })
  const env = { ...process.env, TM_CONF_FILE: `${scratch}/timemachine.conf` }
  const run = (args) => execFileSync(join(root, "bin/tm-conf.sh"), args, { env, timeout: 15000 })
  run(["set", "TM_HOST", "root@192.0.2.99"])
  run(["set", "TM_DEST", "/mnt/pool/tm"])
  run(["set", "TM_SCHEDULE", "10:00,22:30"])
  const j = JSON.parse(run(["json"]).toString())
  assert.equal(j.configured, true)
  assert.equal(j.host, "root@192.0.2.99")
  assert.equal(j.dest, "/mnt/pool/tm")
  assert.equal(j.schedule, "10:00,22:30")
  assert.deepEqual(j.retention, { daily: 14, weekly: 8, monthly: 12 })
  assert.equal(j.timer_installed, false)
  for (const [k, v] of [["TM_SSH_PORT", "abc"], ["TM_SCHEDULE", "9:20"], ["TM_BOGUS", "x"]]) {
    let refused = false
    try { run(["set", k, v]) } catch { refused = true }
    assert.ok(refused, `set ${k}=${v} must be rejected`)
  }
  rmSync(scratch, { recursive: true, force: true })
})

test("v0.4.0 engine: unconfigured conf → configured:false, empty label", () => {
  const scratch = `${tmpdir()}/tm-empty-${process.pid}`
  mkdirSync(scratch, { recursive: true })
  const env = { ...process.env, TM_CONF_FILE: `${scratch}/nope.conf` }
  const j = JSON.parse(execFileSync(join(root, "bin/tm-conf.sh"), ["json"], { env, timeout: 15000 }).toString())
  assert.equal(j.configured, false)
  assert.equal(j.host, "")
  const probe = JSON.parse(execFileSync(join(root, "tm-probe.sh"), [], { env, timeout: 15000 }).toString())
  assert.equal(probe.state, "never")
  assert.equal(probe.configured, false)
  rmSync(scratch, { recursive: true, force: true })
})

test("v0.5.3 engine hardening: rsync transfer passes --no-D right after -aH", () => {
  const t = read("bin/tm-backup.sh")
  assert.ok(t.includes("rsync -aH --no-D --stats"), "specials/devices are skipped, never copied as nodes")
  // -a implies -D; --no-D only wins if it follows -aH on the same invocation
  assert.ok(t.indexOf("-aH --no-D") < t.indexOf("--stats"))
})

test("v0.5.3 unit template: TimeoutStartSec=6h, never the too-tight 2h", () => {
  const t = read("bin/tm-conf.sh")
  assert.ok(t.includes("TimeoutStartSec=6h"), "FUSE-bound link-dest receiver needs stat-storm headroom")
  assert.ok(!t.includes("TimeoutStartSec=2h"), "2h provably SIGTERMs mid-transfer and orphans the slot")
})

test("public-prep hygiene: no fleet literals anywhere in the repo", () => {
  const files = execFileSync("git", ["ls-files"]).toString().trim().split("\n")
    .filter(f => f !== "tests/pin.test.mjs")  // this file holds the assertions themselves
  assert.ok(files.length >= 10, "tracked-file enumeration worked")
  for (const f of files) {
    const t = read(f)
    assert.ok(!t.includes("192.168."), `${f} free of LAN endpoints`)
    assert.ok(!t.includes("watertower"), `${f} free of fleet hostnames`)
    assert.ok(!t.includes("sammypro5"), `${f} free of fleet identifiers`)
  }
})

test("engine scripts parse (bash -n) and probe emits schedule/retention/unit", () => {
  for (const f of ["bin/tm-common.sh", "bin/tm-conf.sh", "bin/tm-backup.sh",
                   "bin/tm-restore.sh", "bin/tm-health.sh"]) {
    execFileSync("bash", ["-n", join(root, f)], { timeout: 10000 })
  }
  const j = JSON.parse(execFileSync(join(root, "tm-probe.sh"), [], { timeout: 15000 }).toString())
  assert.ok(j.schedule && /\d{2}:\d{2}/.test(j.schedule))
  assert.ok(j.retention && j.retention.daily > 0)
  assert.ok(typeof j.unit === "string" && j.unit.length > 0)
  assert.ok(typeof j.timer_installed === "boolean")
})

test("settings surface: last tab, onboarding, arm/confirm, bridge-only writes", () => {
  assert.match(dp, /label: "SETTINGS"/)
  assert.match(dp, /Key_6/)
  assert.match(dp, /% 6/)
  for (const s of ["SAVE & TEST CONNECTION", "TEST CONNECTION", "INSTALL TIMER",
    "CONFIRM INSTALL?", "REINSTALL TIMER", "SAVE", "open the dashboard →",
    "not set up", "SET UP BACKUPS", "+ ADD SENTINEL", "Whole-home backups"]) {
    assert.ok(dp.includes(s), `"${s}" present`)
  }
  // onboarding replaces tabs when unconfigured
  assert.match(dp, /readonly property bool onboarding: !w\.conf\.configured/)
  assert.match(dp, /visible: popup\.onboarding/)
  assert.match(dp, /visible: !popup\.onboarding/)
  // draft validation spelled per spec §3
  for (const s of ["host must be user@host or host", "remote path must be absolute",
    "port must be 1–65535", "HH:MM list — e.g. 09:20,21:20", "must be ≥ 1 hour",
    "1=Mon … 7=Sun"]) {
    assert.ok(dp.includes(s), `validation "${s}"`)
  }
})

test("v0.4.0 write-path hygiene: settings writes are argv Process calls, never sh -c", () => {
  assert.match(bw, /function saveKeys\(/)
  assert.match(bw, /function installTimer\(/)
  assert.match(bw, /"set", key, value/)
  assert.match(bw, /"install"\]/)
  assert.match(bw, /function fetchConf\(\)/)
  // host owns the processes; popup only calls host functions
  assert.match(dp, /w\.saveKeys\(/)
  assert.match(dp, /w\.testConnection\(\)/)
  assert.match(dp, /w\.installTimer\(\)/)
  assert.ok(!dp.includes("TextArea"))
  // the only sh -c in the host is the foyer clipboard pattern (fixed string,
  // data on stdin) — settings processes must not use it
  assert.equal((bw.match(/command: \["sh", "-c",/g) || []).length, 1)
  assert.ok(bw.includes("base64 -d | exec wl-copy"))
})

// v0.4.1 — rsync exit-code discipline (marketplace review finding): only a
// cleanly completed snapshot may advance latest / retention / success stamp.
// rc 24 (source files vanished mid-scan) stays tolerated; rc 23 (partial
// transfer due to error) must discard the partial and fail the run.
function engineFixture(rsyncRc, vanished) {
  const scratch = `${tmpdir()}/tm-rc${rsyncRc}-${process.pid}`
  const home = `${scratch}/home`, dest = `${scratch}/dest`
  const state = `${scratch}/state`, bin = `${scratch}/bin`
  for (const d of [home, dest, state, bin]) mkdirSync(d, { recursive: true })
  writeFileSync(`${home}/a.txt`, "fixture\n")
  writeFileSync(`${scratch}/excludes.txt`, "")
  writeFileSync(`${scratch}/timemachine.conf`, [
    "TM_HOST=user@fakehost",
    `TM_DEST=${dest}`,
    `TM_STATE_DIR=${state}`,
    `TM_EXCLUDES=${scratch}/excludes.txt`,
    "TM_VERIFY_DOW=7",
  ].join("\n") + "\n")
  // PATH stubs: ssh executes the "remote" command locally against scratch;
  // rsync materializes the transfer target and exits the scripted code.
  writeFileSync(`${bin}/ssh`, [
    "#!/usr/bin/env bash",
    "while [ $# -gt 1 ]; do case \"$1\" in -p|-o) shift 2 ;; *) break ;; esac; done",
    "shift  # host",
    "eval \"$*\"",
  ].join("\n") + "\n")
  const stderrLine = vanished ? "rsync stub: simulated vanished-source notice" : ""
  writeFileSync(`${bin}/rsync`, [
    "#!/usr/bin/env bash",
    "tgt=\"${@: -1}\"; mkdir -p \"${tgt#*:}\"; printf x > \"${tgt#*:}/a.txt\"",
    "printf 'Number of files: 3 (reg: 2)\\nTotal file size: 1,234\\n'",
    `[ -n "${stderrLine}" ] && printf '%s\\n' "${stderrLine}" >&2`,
    `exit ${rsyncRc}`,
  ].join("\n") + "\n")
  for (const f of ["ssh", "rsync"]) chmodSync(`${bin}/${f}`, 0o755)
  const opts = {
    env: { ...process.env, PATH: `${bin}:${process.env.PATH}`, HOME: home,
           TM_CONF_FILE: `${scratch}/timemachine.conf` },
    timeout: 30000,
  }
  return { scratch, home, dest, state, opts }
}

test("v0.4.1 source pin: only rc 24 tolerated; rc 23 must discard the partial", () => {
  const s = read("bin/tm-backup.sh")
  assert.match(s, /\[ "\$RC" != 0 \] && \[ "\$RC" != 24 \]/)
  assert.ok(!s.includes('"$RC" != 23'), "rc 23 must never be tolerated")
  // v0.5.2: the failure path removes the run's own staging dir only — it
  // never rm's a published snapshot name
  assert.match(s, /rm -rf '\$TM_DEST\/backups\/\$STG'/)
  assert.ok(!s.includes("rm -rf '$TM_DEST/backups/$SNAP'"),
    "failure path must never remove the published name")
})

test("v0.5.2 source pin: stage into a unique dir, publish by rename, refuse existing destinations", () => {
  const s = read("bin/tm-backup.sh")
  // pre-flight refusal before any transfer
  assert.match(s, /test -e '\$TM_DEST\/backups\/\$SNAP'/)
  assert.match(s, /SKIP: backup \$SNAP already completed and published/)
  assert.match(s, /FATAL: backups\/\$SNAP already exists but latest is/)
  // transfer targets a unique hidden staging dir, never the final name
  assert.match(s, /STG="\.staging\.\$SNAP\.\$\$"/)
  assert.match(s, /backups\/\$STG\/"/)
  assert.ok(!s.includes('backups/$SNAP/"'),
    "rsync must never target the published name directly")
  // publish = rename before latest moves
  assert.match(s, /mv -T '\$STG' '\$SNAP'/)
  assert.match(s, /ln -sfn 'backups\/\$SNAP' latest\.tmp/)
  // abandoned staging sweep is age-gated and can never race a live run
  assert.match(s, /-name '\.staging\.\*' -mtime \+1/)
})

test("v0.4.1 QML hygiene: no anchors on items a Layout manages (Qt UB warning)", () => {
  // Anchors on a DIRECT child of a *Layout are undefined behavior — use
  // Layout.alignment. Anchors under a plain Item/Button parent are legal, so
  // walk each anchors line up exactly two opener levels: item → parent.
  const lines = dp.split("\n")
  const opener = /^\s*(?:component\s+\w+\s*:\s*)?([A-Za-z0-9_.]+)\s*\{$/
  const ind = (l) => l.match(/^\s*/)[0].length
  const openerAbove = (from, shallowerThan) => {
    for (let i = from - 1; i >= 0; i--) {
      const m = lines[i].match(opener)
      if (m && ind(lines[i]) < shallowerThan) return { type: m[1], idx: i }
    }
    return null
  }
  lines.forEach((l, i) => {
    if (!/^\s*anchors\./.test(l)) return
    const item = openerAbove(i, ind(l))
    assert.ok(item, `line ${i + 1}: anchored item's declaration found`)
    const parent = openerAbove(item.idx, ind(lines[item.idx]))
    assert.ok(parent, `line ${i + 1}: parent declaration found`)
    assert.ok(!/Layout$/.test(parent.type),
      `line ${i + 1}: anchors on ${item.type} managed by ${parent.type} — use Layout.alignment`)
  })
})

test("v0.4.1 engine: rsync rc 23 discards the partial — no latest, no stamp, no history", () => {
  const t = engineFixture(23)
  let err = null
  try { execFileSync(join(root, "bin/tm-backup.sh"), t.opts) } catch (e) { err = e }
  assert.ok(err, "rc 23 run must fail")
  assert.equal(err.status, 23)
  assert.match(String(err.stdout), /FATAL: rsync exited 23/)
  assert.match(String(err.stdout), /discarded/)
  assert.ok(!existsSync(`${t.dest}/latest`), "latest must not advance")
  assert.deepEqual(readdirSync(`${t.dest}/backups`), [], "partial backup removed")
  assert.ok(!existsSync(`${t.state}/last-backup.json`), "no success stamp")
  assert.ok(!existsSync(`${t.state}/history.jsonl`), "no healthy history row")
  rmSync(t.scratch, { recursive: true, force: true })
})

test("v0.4.1 engine: rsync rc 24 (vanished sources) tolerated — snapshot completes", () => {
  const t = engineFixture(24, true)
  const out = execFileSync(join(root, "bin/tm-backup.sh"), t.opts).toString()
  assert.match(out, /WARN: rsync: rsync stub: simulated vanished-source notice/)
  assert.match(out, /OK — backup /)
  assert.ok(existsSync(`${t.dest}/latest`), "latest advanced")
  assert.ok(existsSync(`${t.state}/last-backup.json`), "success stamp written")
  rmSync(t.scratch, { recursive: true, force: true })
})

test("v0.5.2 engine: same-minute rerun refuses the published destination — no transfer, tree untouched", () => {
  // marketplace maintainer finding @2105f4e: rsync used to write directly
  // into an already published same-minute snapshot, so a mid-transfer error
  // could corrupt a completed backup while latest/stamps still reported
  // healthy. The run must now refuse the existing destination BEFORE any
  // transfer: SKIP (exit 0) when it is the published latest, and the
  // completed tree must stay byte-identical — rsync never starts.
  for (let attempt = 0; attempt < 3; attempt++) {
    const t = engineFixture(23)   // rsync WOULD fail rc 23 — it must never run
    const now = new Date()
    const p2 = (n) => String(n).padStart(2, "0")
    const snap = `${now.getFullYear()}${p2(now.getMonth() + 1)}${p2(now.getDate())}`
      + `-${p2(now.getHours())}${p2(now.getMinutes())}`
    mkdirSync(`${t.dest}/backups/${snap}`, { recursive: true })
    writeFileSync(`${t.dest}/backups/${snap}/completed.txt`, "done\n")
    symlinkSync(`backups/${snap}`, `${t.dest}/latest`)
    let out = ""
    try { out = execFileSync(join(root, "bin/tm-backup.sh"), t.opts).toString() }
    catch (e) { out = String(e.stdout || "") + String(e.stderr || "") }
    if (!out.includes(snap)) {   // minute flipped mid-run — clean and retry
      rmSync(t.scratch, { recursive: true, force: true })
      continue
    }
    assert.match(out, new RegExp(`SKIP: backup ${snap} already completed and published`))
    assert.ok(!existsSync(`${t.dest}/backups/${snap}/a.txt`),
      "rsync never wrote into the completed backup")
    assert.equal(readFileSync(`${t.dest}/backups/${snap}/completed.txt`, "utf8"), "done\n",
      "completed backup byte-identical")
    assert.equal(readlinkSync(`${t.dest}/latest`), `backups/${snap}`,
      "latest still points at the completed backup")
    assert.deepEqual(readdirSync(`${t.dest}/backups`), [snap], "no staging leftovers")
    rmSync(t.scratch, { recursive: true, force: true })
    return
  }
  assert.fail("minute boundary flipped three times — rerun the suite")
})

test("v0.5.2 engine: existing non-published dir is refused loudly, never written into", () => {
  // the other existing-destination case: a leftover partial from a killed
  // run. The rerun must fail fast with the quarantine hint instead of
  // transferring into (or deleting) the existing tree.
  for (let attempt = 0; attempt < 3; attempt++) {
    const t = engineFixture(23)
    const now = new Date()
    const p2 = (n) => String(n).padStart(2, "0")
    const snap = `${now.getFullYear()}${p2(now.getMonth() + 1)}${p2(now.getDate())}`
      + `-${p2(now.getHours())}${p2(now.getMinutes())}`
    mkdirSync(`${t.dest}/backups/${snap}`, { recursive: true })
    writeFileSync(`${t.dest}/backups/${snap}/orphan.txt`, "partial\n")
    mkdirSync(`${t.dest}/backups/20260101-0000`, { recursive: true })
    symlinkSync(`backups/20260101-0000`, `${t.dest}/latest`)
    let err = null
    try { execFileSync(join(root, "bin/tm-backup.sh"), t.opts) } catch (e) { err = e }
    const out = String(err ? err.stdout : "")
    if (!out.includes(snap)) {   // minute flipped mid-run — clean and retry
      rmSync(t.scratch, { recursive: true, force: true })
      continue
    }
    assert.ok(err, "refusal must exit non-zero")
    assert.equal(err.status, 1)
    assert.match(out, new RegExp(`FATAL: backups/${snap} already exists but latest is '20260101-0000'`))
    assert.equal(readFileSync(`${t.dest}/backups/${snap}/orphan.txt`, "utf8"), "partial\n",
      "existing tree untouched")
    assert.ok(!existsSync(`${t.dest}/backups/${snap}/a.txt`), "rsync never ran")
    rmSync(t.scratch, { recursive: true, force: true })
    return
  }
  assert.fail("minute boundary flipped three times — rerun the suite")
})

test("v0.4.1 engine: clean run (rc 0) still advances latest + stamps success", () => {
  const t = engineFixture(0)
  const out = execFileSync(join(root, "bin/tm-backup.sh"), t.opts).toString()
  assert.match(out, /OK — backup /)
  assert.ok(existsSync(`${t.dest}/latest`), "latest advanced")
  assert.ok(existsSync(`${t.state}/last-backup.json`), "success stamp written")
  assert.ok(existsSync(`${t.state}/history.jsonl`), "history row written")
  const snap = readFileSync(`${t.state}/last-backup.json`, "utf8")
  assert.match(snap, /"backup":"\d{8}-\d{4}"/)
  rmSync(t.scratch, { recursive: true, force: true })
})
