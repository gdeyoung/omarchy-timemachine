import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// TimeMachine bar widget (gdeyoung.timemachine).
// Chip: status dot + "TM" + last-backup age. Left-click → detail popup
// (status cards, backup-size history, drill state, actions). Right-click
// or IPC refresh → re-probe. Data bridge: tm-probe.sh, one JSON line.
// States: running (pulse) · ok <26h · stale <72h · fail ≥72h · never.
BarWidget {
  id: root
  moduleName: "gdeyoung.timemachine"

  property var probe: ({})
  property bool popupOpen: false
  property string busy: ""       // "", "backup", "drill", "list"
  property string output: ""     // drill/list output tail shown in the popup
  property var snap: ({ status: "idle" })  // Backups-tab fetch (tm-backups.sh)
  property var snapper: ({ status: "idle" }) // local Snapshots-tab fetch (tm-snapper.sh)

  readonly property int refreshSeconds: Math.max(5, Math.min(60, Number(setting("refreshSeconds", 15)) || 15))
  // state thresholds flow to tm-probe.sh as argv (probe defaults: 26/72)
  readonly property int staleHours: Math.max(1, Math.min(168, Number(setting("staleHours", 26)) || 26))
  readonly property int failHours: Math.max(staleHours + 1, Math.min(336, Number(setting("failHours", 72)) || 72))
  readonly property int historyDays: Math.max(3, Math.min(90, Number(setting("historyDays", 14)) || 14))
  readonly property int snapshotRows: Math.max(5, Math.min(50, Number(setting("snapshotRows", 10)) || 10))

  readonly property string state: probe.state || "unknown"
  readonly property string label: probe.label || "backup host"
  readonly property color stateColor:
      state === "ok" ? "#3fb950" :
      state === "running" ? "#7aa2f7" :
      state === "stale" ? "#e5c07b" :
      state === "fail" ? "#f7768e" : "#888c94"
  readonly property color fg: bar ? bar.foreground : Color.foreground

  function fmtAge(h) {
    if (h < 1) return Math.max(1, Math.round(h * 60)) + "m"
    if (h < 48) return Math.round(h) + "h"
    return Math.round(h / 24) + "d"
  }
  readonly property string ageText: probe.age_h === undefined || probe.age_h === null
    ? "--" : fmtAge(probe.age_h)

  readonly property string tooltip:
      "Time Machine — " + (state === "ok" ? "protected" : state)
    + (probe.backup ? "\nlast  " + probe.backup
      + " · " + (probe.size_mb || 0) + " MB"
      + " · " + (probe.dur_s || 0) + "s" : "")
    + (probe.next_run ? "\nnext  " + probe.next_run : "")
    + "\nrepo  " + (probe.label || "not configured") + " (rsync, plaintext)"

  function refresh() {
    probeProc.running = true
  }
  Component.onCompleted: refresh()

  function apply(text) {
    let data
    try {
      data = JSON.parse(String(text).trim().split("\n").pop())
    } catch (e) {
      return
    }
    if (!data) return
    probe = data
    if (!busy) { /* keep busy state; probe may flip state while running */ }
  }

  // ---- actions -----------------------------------------------------------
  function backupNow() {
    busy = "backup"
    backupProc.running = true
  }
  function runDrill() {
    busy = "drill"
    output = "running restore drill…"
    drillProc.running = true
  }
  function showRepo() {
    busy = "list"
    output = "listing backups…"
    listProc.running = true
  }
  // Backups/Recovery tabs: one ssh-backed fetch per popup open (never on
  // the bar refresh path). tm-backups.sh derives host/dest at runtime —
  // endpoints never live in this file.
  function fetchSnapshots() {
    snapProc.running = true
  }
  function applySnap(text) {
    var data
    try {
      data = JSON.parse(String(text).trim().split("\n").pop())
    } catch (e) {
      snap = { status: "error", detail: "unparsable fetch" }
      return
    }
    if (data && data.status)
      snap = data.status === "ok" ? data : { status: data.status, detail: data.detail || "",
                                             scp_prefix: data.scp_prefix || "" , rows: [] }
  }

  // local Snapshots tab: one snapper-backed fetch per popup open (never on
  // the bar refresh path). Runs as the wheel user; no root, no network.
  function fetchSnapper() {
    snapperProc.running = true
  }
  function applySnapper(text) {
    var data
    try {
      data = JSON.parse(String(text).trim().split("\n").pop())
    } catch (e) {
      snapper = { status: "error" }
      return
    }
    if (data && data.status)
      snapper = data
  }

  // read-only browse of a LOCAL snapshot dir in the default file manager —
  // argv-array, no shell. Path is composed from an int id (never user text).
  function openPath(p) {
    openProc.command = [ "xdg-open", p ]
    openProc.running = true
  }
  // manual snapshot pair (wheel-allowed; verified live). Chained root→home
  // so both land before the tab refetches.
  function createSnapshots() {
    snapCreateRootProc.running = true
  }

  // ---- settings bridge (v0.4.0) -------------------------------------------
  // All writes go through bin/tm-conf.sh argv calls — QML never writes files.
  property var conf: ({ configured: false, sentinels: [] })
  property var testRes: ({ state: "idle" })   // idle|running|ok|fail (+free_gb/detail)
  property string saveState: ""               // ""|saving|saved|failed
  property string saveErr: ""
  property string installState: ""            // ""|installing|done
  property var setQueue: []                   // [[key, value], …] drained by setProc
  function fetchConf() { confProc.running = true }
  function applyConf(text) {
    var data
    try {
      data = JSON.parse(String(text).trim().split("\n").pop())
    } catch (e) { return }
    if (data && data.configured !== undefined) conf = data
  }
  function testConnection() {
    testRes = { state: "running" }
    testProc.running = true
  }
  function applyTest(text) {
    var data
    try {
      data = JSON.parse(String(text).trim().split("\n").pop())
    } catch (e) {
      testRes = { state: "fail", detail: "unparsable test result" }
      return
    }
    if (data && data.ok)
      testRes = { state: "ok", free_gb: data.free_gb, total_gb: data.total_gb,
                  backup_count: data.backup_count }
    else
      testRes = { state: "fail", detail: (data && data.detail) || "test failed" }
  }
  // Queue of changed keys → sequential `tm-conf.sh set` runs → conf refresh.
  function saveKeys(queue) {
    setQueue = queue
    saveState = "saving"
    saveErr = ""
    setNext()
  }
  function setNext() {
    if (setQueue.length === 0) {
      saveState = "saved"
      fetchConf()
      refresh()
      return
    }
    var item = setQueue[0]
    setProc.key = item[0]
    setProc.value = item[1]
    setProc.running = true
  }
  function installTimer() {
    installState = "installing"
    installProc.running = true
  }
  // Clipboard: base64 over stdin (foyer house pattern) — text never lands
  // in a process argument, sh's `read` gives wl-copy its EOF.
  function copyText(s) {
    var t = String(s === undefined || s === null ? "" : s)
    if (t === "") return
    copyProc.running = false
    copyProc.stdinData = Qt.btoa(unescape(encodeURIComponent(t))) + "\n"
    copyProc.running = true
  }
  function appendOutput(line) {
    var lines = (output + "\n" + line).split("\n").filter(function(l) { return l.length > 0 })
    output = lines.slice(-14).join("\n")
  }

  // ---- data bridge -------------------------------------------------------
  Process {
    id: probeProc
    command: [Qt.resolvedUrl("tm-probe.sh").toString().replace("file://", ""),
              String(root.staleHours), String(root.failHours)]
    stdout: StdioCollector { onStreamFinished: root.apply(text) }
  }

  Process {
    id: backupProc
    command: ["systemctl", "--user", "start",
              (root.probe.unit || "timemachine-backup") + ".service"]
    onExited: function(exitCode, exitStatus) {
      root.busy = ""
      root.appendOutput("backup triggered (exit " + exitCode + ") — service runs async; watch the dot")
      root.refresh()
    }
  }

  Process {
    id: drillProc
    command: [Qt.resolvedUrl("bin/tm-restore.sh").toString().replace("file://", ""), "--drill"]
    stdout: SplitParser { onRead: function(line) { root.appendOutput(line) } }
    onExited: function(exitCode, exitStatus) {
      root.busy = ""
      root.appendOutput(exitCode === 0 ? "drill PASS" : "drill FAIL (exit " + exitCode + ")")
      root.refresh()
    }
  }

  Process {
    id: listProc
    command: [Qt.resolvedUrl("bin/tm-restore.sh").toString().replace("file://", ""), "--list"]
    stdout: SplitParser { onRead: function(line) { root.appendOutput(line) } }
    onExited: function(exitCode, exitStatus) { root.busy = ""; root.refresh() }
  }

  Process {
    id: snapProc
    command: [Qt.resolvedUrl("tm-backups.sh").toString().replace("file://", "")]
    stdout: StdioCollector { onStreamFinished: root.applySnap(text) }
    onExited: function(exitCode, exitStatus) {
      // ssh failures exit 0 with status:unreachable inside the JSON; a hard
      // crash still leaves the tab actionable
      if (exitCode !== 0 && root.snap.status !== "unreachable")
        root.snap = { status: "error", detail: "fetch exit " + exitCode, rows: [] }
    }
  }

  Process {
    id: snapperProc
    command: [Qt.resolvedUrl("tm-snapper.sh").toString().replace("file://", "")]
    stdout: StdioCollector { onStreamFinished: root.applySnapper(text) }
    onExited: function(exitCode, exitStatus) {
      if (exitCode !== 0 && root.snapper.status !== "unavailable")
        root.snapper = { status: "error" }
    }
  }

  Process {
    id: snapCreateRootProc
    command: ["snapper", "-c", "root", "create", "-d", "manual"]
    onExited: function(exitCode, exitStatus) { snapCreateHomeProc.running = true }
  }
  Process {
    id: snapCreateHomeProc
    command: ["snapper", "-c", "home", "create", "-d", "manual"]
    onExited: function(exitCode, exitStatus) { snapperProc.running = true }
  }
  Process {
    id: openProc
    command: ["xdg-open", "/"]
  }

  // ---- settings bridge processes (v0.4.0) --------------------------------
  Process {
    id: confProc
    command: [Qt.resolvedUrl("bin/tm-conf.sh").toString().replace("file://", ""), "json"]
    stdout: StdioCollector { onStreamFinished: root.applyConf(text) }
  }

  Process {
    id: testProc
    command: [Qt.resolvedUrl("bin/tm-conf.sh").toString().replace("file://", ""), "test"]
    stdout: StdioCollector { onStreamFinished: root.applyTest(text) }
  }

  Process {
    id: setProc
    property string key: ""
    property string value: ""
    command: [Qt.resolvedUrl("bin/tm-conf.sh").toString().replace("file://", ""), "set", key, value]
    stdout: SplitParser { }
    stderr: SplitParser { onRead: function(line) { if (line) root.saveErr = line } }
    onExited: function(exitCode, exitStatus) {
      if (exitCode !== 0) {
        root.saveState = "failed"
        root.setQueue = []
        return
      }
      root.setQueue = root.setQueue.slice(1)
      root.setNext()
    }
  }

  Process {
    id: installProc
    command: [Qt.resolvedUrl("bin/tm-conf.sh").toString().replace("file://", ""), "install"]
    stdout: SplitParser { onRead: function(line) { root.appendOutput(line) } }
    onExited: function(exitCode, exitStatus) {
      root.installState = exitCode === 0 ? "done" : ""
      root.fetchConf()
      root.refresh()
    }
  }

  Process {
    id: copyProc
    command: ["sh", "-c",
      'IFS= read -r b64; printf "%s" "$b64" | base64 -d | exec wl-copy -t text/plain;charset=utf-8',
      "sh"]
    stdinEnabled: true
    property string stdinData: ""
    onStarted: if (copyProc.stdinData !== "") { copyProc.write(copyProc.stdinData); copyProc.stdinData = "" }
    stdout: SplitParser { }
  }

  Timer {
    interval: root.refreshSeconds * 1000
    running: true
    repeat: true
    onTriggered: root.refresh()
  }

  // ---- chip --------------------------------------------------------------
  implicitWidth: root.vertical ? Style.bar.statusSlot : row.implicitWidth + 16
  implicitHeight: root.vertical ? (verticalCol.implicitHeight + 12) : root.barSize

  Row {
    id: row
    visible: !root.vertical
    anchors.centerIn: parent
    spacing: 5

    Text {
      // nf-fa-history: clock + counter-clockwise arrow — "back in time"
      text: "\uF1DA"
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
      color: root.stateColor

      SequentialAnimation on opacity {
        running: root.state === "running"
        loops: Animation.Infinite
        NumberAnimation { from: 1; to: 0.25; duration: 600 }
        NumberAnimation { from: 0.25; to: 1; duration: 600 }
      }
    }
  }

  // vertical bar fallback
  Text {
    visible: root.vertical
    anchors.centerIn: parent
    text: "\uF1DA"
    font.family: Style.font.family
    font.pixelSize: Style.font.bodySmall
    color: root.stateColor
  }

  DetailPopup {
    id: detailPopup
    host: root
  }

  IpcHandler {
    target: "gdeyoung.timemachine"
    function summon(): void { if (!detailPopup.open) detailPopup.open = true }
    function toggle(): void { detailPopup.open = !detailPopup.open }
    function refresh(): void { root.refresh() }
    function tab(n: int): void {   // automation surface: open + select tab 0-5
      if (!detailPopup.open) detailPopup.open = true
      detailPopup.currentTab = Math.max(0, Math.min(5, n))
    }
    function scroll(d: int): void { detailPopup.scrollBy(d) }  // verify long pages
    function status(): string {
      return "geo " + Math.round(root.width) + "x" + Math.round(root.height)
        + " row " + Math.round(row.implicitWidth) + " vertical=" + root.vertical
        + " state=" + root.state + " age=" + root.ageText
        + " probe=" + (root.probe && root.probe.engine ? root.probe.engine : "none")
    }
  }

  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    acceptedButtons: Qt.LeftButton | Qt.RightButton
    onClicked: (mouse) => {
      if (mouse.button === Qt.LeftButton) {
        if (detailPopup.open) detailPopup.close()
        else detailPopup.open = true
      } else {
        root.refresh()
      }
    }
    onEntered: if (root.bar) root.bar.showTooltip(root, root.tooltip)
    onExited: if (root.bar) root.bar.hideTooltip(root)
  }
}
