import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// DetailPopup — the TimeMachine panel, v0.5.0 tabbed layout (spec:
// design/v050-terminology-daypicker-spec.md). Six tabs: Status / Backups /
// Snapshots / Health / Recovery / Settings. "Backups" = off-box rsync trees;
// "Snapshots" = local btrfs/snapper. Tab + selection + expanded-day state is
// in-memory (reset on every open); no config lives here. Non-destructive by
// design: browsing, copying and drilling only — restore itself stays with
// the agent (merge-never-overwrite discipline — see the plugin README).
PopupCard {
  id: popup

  required property var host
  readonly property var w: host

  anchorItem: host
  bar: host.bar
  owner: host
  // host drives `open` imperatively (outside-click close owns the binding)
  onOpenChanged: {
    host.popupOpen = open
    if (open) {
      host.refresh()
      host.fetchSnapshots()
      host.fetchSnapper()
      host.fetchConf()
      popup.currentTab = 0        // in-memory only: every open starts clean
      popup.recoverSnapshot = ""
      popup.recoverLocal = null
      popup.expandedDays = ({})   // day picker resets; today re-expands by default
      popup.armInstall = false
      popup.pendingTest = false
      flick.forceActiveFocus()
    }
  }

  contentWidth: popup.fittedContentWidth(Style.space(520))
  contentHeight: popup.fittedContentHeight(col.implicitHeight)

  function scrollBy(dy) {
    flick.contentY = Math.max(0, Math.min(flick.contentHeight - flick.height,
                                          flick.contentY + dy))
  }

  // ---- palette: chrome from tokens, severity literals pinned by tests ----
  readonly property color fg: host && host.bar ? host.bar.foreground : Color.foreground
  readonly property color muted: Color.muted
  readonly property color cardBg: Style.normalFillFor(popup.fg, Color.accent, Color.urgent)
  readonly property color ok: "#3fb950"
  readonly property color warn: "#e5c07b"
  readonly property color bad: "#f7768e"
  readonly property color info: "#7aa2f7"

  // ---- data (probe contract is read-only) --------------------------------
  readonly property var probe: w.probe || ({})
  readonly property string state: w.state
  readonly property color stateColor: w.stateColor
  readonly property var hist: Array.isArray(probe.history) ? probe.history : []
  readonly property var sizes: hist.map(function(h) { return h.v || 0 })
  readonly property real sizeMax: sizes.length ? Math.max.apply(null, sizes) : 0
  readonly property real sizeAvg: sizes.length
    ? sizes.reduce(function(a, b) { return a + b }, 0) / sizes.length : 0
  readonly property var drill: probe.drill || null
  readonly property var verify: probe.verify || null
  readonly property var health: probe.health || null
  readonly property var drift: probe.drift || null
  readonly property var snap: w.snap || ({ status: "idle" })
  readonly property var snapRows: Array.isArray(snap.rows) ? snap.rows : []
  readonly property var snapper: w.snapper || ({ status: "idle" })

  // ---- in-memory UI state -------------------------------------------------
  property int currentTab: 0   // 0 status · 1 backups · 2 snapshots · 3 health · 4 recovery · 5 settings
  property string recoverSnapshot: ""
  property var recoverLocal: null   // {subvol, id} — snapshot preselected from the Snapshots tab
  property var expandedDays: ({})   // dayKey → true/false; unset = today-only default

  // ---- v0.4.0 settings draft (in-memory; reloaded whenever host conf changes)
  readonly property bool onboarding: !w.conf.configured
  property var draft: ({})
  property var sentinels: []
  property bool armInstall: false
  property bool pendingTest: false

  function loadDraft() {
    var c = w.conf
    draft = {
      TM_HOST: c.host || "",
      TM_DEST: c.dest || "",
      TM_SSH_PORT: String(c.port || 22),
      TM_LABEL: c.label || "",
      TM_SCHEDULE: c.schedule || "",
      TM_RETENTION_DAILY: String(c.retention ? c.retention.daily : 14),
      TM_RETENTION_WEEKLY: String(c.retention ? c.retention.weekly : 8),
      TM_RETENTION_MONTHLY: String(c.retention ? c.retention.monthly : 12),
      TM_MAX_AGE_H: String(c.max_age_h || 30),
      TM_VERIFY_DOW: String(c.verify_dow || 7),
      TM_NOTIFY_CMD: c.notify || ""
    }
    sentinels = (c.sentinels || []).slice(0)
  }
  function dv(k) { return draft[k] === undefined ? "" : String(draft[k]) }
  function setDraft(k, v) {
    if (draft[k] === v) return
    // fresh object — same reference-identity trap as toggleDay (see there)
    var d = {}
    for (var key in draft) d[key] = draft[key]
    d[k] = v
    draft = d
  }
  function setSentinel(i, v) {
    var a = sentinels.slice(0)
    a[i] = v
    sentinels = a
  }
  function addSentinel() {
    var a = sentinels.slice(0)
    a.push("")
    sentinels = a
  }
  function removeSentinel(i) {
    var a = sentinels.slice(0)
    a.splice(i, 1)
    sentinels = a
  }

  function fieldError(k) {
    var v = dv(k)
    if (k === "TM_HOST") {
      if (!v) return ""
      if (!/^[^@\s]+(@[^@\s]+)?$/.test(v)) return "host must be user@host or host"
    } else if (k === "TM_DEST") {
      if (v && v.charAt(0) !== "/") return "remote path must be absolute (/…)"
    } else if (k === "TM_SSH_PORT") {
      var p = parseInt(v, 10)
      if (!p || p < 1 || p > 65535) return "port must be 1–65535"
    } else if (k === "TM_SCHEDULE") {
      if (!v) return "schedule can't be empty"
      if (!/^([01]\d|2[0-3]):[0-5]\d(,([01]\d|2[0-3]):[0-5]\d)*$/.test(v))
        return "HH:MM list — e.g. 09:20,21:20"
    } else if (k === "TM_RETENTION_DAILY" || k === "TM_RETENTION_WEEKLY"
               || k === "TM_RETENTION_MONTHLY") {
      var r = parseInt(v, 10)
      if (isNaN(r) || r < 0) return "must be a number ≥ 0"
    } else if (k === "TM_MAX_AGE_H") {
      var h = parseInt(v, 10)
      if (!h || h < 1) return "must be ≥ 1 hour"
    } else if (k === "TM_VERIFY_DOW") {
      var wd = parseInt(v, 10)
      if (!wd || wd < 1 || wd > 7) return "1=Mon … 7=Sun"
    }
    return ""
  }
  readonly property var errorKeys: ["TM_HOST", "TM_DEST", "TM_SSH_PORT", "TM_SCHEDULE",
    "TM_RETENTION_DAILY", "TM_RETENTION_WEEKLY", "TM_RETENTION_MONTHLY",
    "TM_MAX_AGE_H", "TM_VERIFY_DOW"]
  readonly property bool hasErrors: {
    var bad = false
    for (var i = 0; i < errorKeys.length; i++)
      if (fieldError(errorKeys[i])) { bad = true; break }
    return bad
  }
  readonly property bool dirty: {
    var c = w.conf
    if (!draft || !draft.TM_HOST && draft.TM_HOST !== "") return false
    var d = false
    if (dv("TM_HOST") !== (c.host || "")) d = true
    if (dv("TM_DEST") !== (c.dest || "")) d = true
    if (dv("TM_SSH_PORT") !== String(c.port || 22)) d = true
    if (dv("TM_LABEL") !== (c.label || "")) d = true
    if (dv("TM_SCHEDULE") !== (c.schedule || "")) d = true
    if (dv("TM_RETENTION_DAILY") !== String(c.retention ? c.retention.daily : 14)) d = true
    if (dv("TM_RETENTION_WEEKLY") !== String(c.retention ? c.retention.weekly : 8)) d = true
    if (dv("TM_RETENTION_MONTHLY") !== String(c.retention ? c.retention.monthly : 12)) d = true
    if (dv("TM_MAX_AGE_H") !== String(c.max_age_h || 30)) d = true
    if (dv("TM_VERIFY_DOW") !== String(c.verify_dow || 7)) d = true
    if (dv("TM_NOTIFY_CMD") !== (c.notify || "")) d = true
    if (sentinels.join(":") !== (c.sentinels || []).join(":")) d = true
    return d
  }
  readonly property bool scheduleDirty: dv("TM_SCHEDULE") !== (w.conf.schedule || "")
  function changedQueue() {
    var c = w.conf
    var q = []
    if (dv("TM_HOST") !== (c.host || "")) q.push(["TM_HOST", dv("TM_HOST")])
    if (dv("TM_DEST") !== (c.dest || "")) q.push(["TM_DEST", dv("TM_DEST")])
    if (dv("TM_SSH_PORT") !== String(c.port || 22)) q.push(["TM_SSH_PORT", dv("TM_SSH_PORT")])
    if (dv("TM_LABEL") !== (c.label || "")) q.push(["TM_LABEL", dv("TM_LABEL")])
    if (dv("TM_SCHEDULE") !== (c.schedule || "")) q.push(["TM_SCHEDULE", dv("TM_SCHEDULE")])
    if (dv("TM_RETENTION_DAILY") !== String(c.retention ? c.retention.daily : 14))
      q.push(["TM_RETENTION_DAILY", dv("TM_RETENTION_DAILY")])
    if (dv("TM_RETENTION_WEEKLY") !== String(c.retention ? c.retention.weekly : 8))
      q.push(["TM_RETENTION_WEEKLY", dv("TM_RETENTION_WEEKLY")])
    if (dv("TM_RETENTION_MONTHLY") !== String(c.retention ? c.retention.monthly : 12))
      q.push(["TM_RETENTION_MONTHLY", dv("TM_RETENTION_MONTHLY")])
    if (dv("TM_MAX_AGE_H") !== String(c.max_age_h || 30)) q.push(["TM_MAX_AGE_H", dv("TM_MAX_AGE_H")])
    if (dv("TM_VERIFY_DOW") !== String(c.verify_dow || 7)) q.push(["TM_VERIFY_DOW", dv("TM_VERIFY_DOW")])
    if (dv("TM_NOTIFY_CMD") !== (c.notify || "")) q.push(["TM_NOTIFY_CMD", dv("TM_NOTIFY_CMD")])
    if (sentinels.join(":") !== (c.sentinels || []).join(":"))
      q.push(["TM_SENTINELS", sentinels.join(":")])
    return q
  }
  // bridge detail lines already carry host:port — decorate by failure class
  function testLine() {
    var t = w.testRes
    if (t.state === "running") return { text: "◌ testing…", hue: popup.muted }
    if (t.state === "ok")
      return { text: "● reachable · " + t.free_gb + " GB free of " + t.total_gb + " GB"
             + (t.backup_count !== undefined && t.backup_count > 0
                  ? " · " + t.backup_count + " backups" : ""), hue: popup.ok }
    if (t.state === "fail") {
      var d = t.detail || ""
      if (d === "not configured") return { text: "● save host and path first", hue: popup.muted }
      if (d.indexOf("unreachable") === 0)
        return { text: "● " + d + " — check it's on and awake", hue: popup.warn }
      if (d.indexOf("auth") === 0)
        return { text: "● " + d + " — run ssh-copy-id, then retry", hue: popup.bad }
      return { text: "● " + d, hue: popup.bad }
    }
    return { text: "not tested yet", hue: popup.muted }
  }

  // non-visual logic must live inside an Item (PopupCard's default property
  // is contentItem and only accepts visuals)
  Item {
    id: popupLogic
    Timer { id: armTimer; interval: 5000; onTriggered: popup.armInstall = false }
    Timer {
      id: savedTimer; interval: 2400
      onTriggered: w.saveState = ""
    }
    Connections {
      target: w
      function onConfChanged() { popup.loadDraft() }
      function onSaveStateChanged() {
        if (w.saveState === "saved") {
          savedTimer.restart()
          if (popup.pendingTest) { popup.pendingTest = false; w.testConnection() }
        }
      }
    }
  }

  function stateWord() {
    if (state === "ok") return "PROTECTED"
    if (state === "running") return "BACKING UP"
    if (state === "stale") return "STALE"
    if (state === "fail") return "FAILED"
    if (state === "never") return "NO BACKUP"
    return "UNKNOWN"
  }

  // one-line verdict pre-digesting verify/drill/freshness (NN/g recognition
  // over recall — the user never computes health from raw stats)
  function verdictLine() {
    var v = verify ? (verify.pass + "/" + verify.files) : null
    var d = drill ? (drill.pass + "/" + (drill.pass + drill.fail)) : null
    var parts = []
    if (state === "running")
      return probe.age_h !== null && probe.age_h !== undefined
        ? "backup running — last complete " + w.ageText + " ago · watch the dot"
        : "first backup running"
    if (state === "never") return "no backups yet — BACK UP NOW starts the first one"
    if (state === "stale")
      return "last backup " + w.ageText + " ago · threshold "
        + Math.round((probe.thresholds ? probe.thresholds.stale_h : 26)) + "h"
        + (probe.next_run ? " · next " + probe.next_run : "")
    if (state === "fail")
      return "last backup " + w.ageText + " ago · check " + w.label + " reachability"
        + (probe.next_run ? " · next " + probe.next_run : "")
    if (v && d) return "sentinel verify " + v + " · drill " + d + " · backups current"
    if (d) return "verify Sun · drill " + d + " · backups current"
    if (v) return "sentinel verify " + v + " · backups current"
    return "backups current — drill and verify pending"
  }

  function fmtTs(iso) {
    if (!iso) return "—"
    var d = new Date(iso)
    return isNaN(d.getTime()) ? iso
      : d.toLocaleDateString(Qt.locale(), "MM/dd") + " " + d.toLocaleTimeString(Qt.locale(), "HH:mm")
  }
  function fmtAgo(t) {
    if (!t) return "—"
    var s = Math.max(0, Math.floor(Date.now() / 1000 - t))
    if (s < 3600) return Math.max(1, Math.round(s / 60)) + "m ago"
    if (s < 86400) return Math.round(s / 3600) + "h ago"
    return Math.round(s / 86400) + "d ago"
  }
  function fmtIdDate(id) {
    // 20261019-0924 → 2026-10-19 09:24 (id IS the creation stamp).
    // Snapshot rows carry INTEGER snapper ids and still evaluate this
    // binding (hidden ≠ unevaluated) — coerce, then shape-check.
    var s = (id === null || id === undefined) ? "" : String(id)
    if (s.length < 13) return s || "—"
    return s.substring(0, 4) + "-" + s.substring(4, 6) + "-" + s.substring(6, 8)
      + " " + s.substring(9, 11) + ":" + s.substring(11, 13)
  }
  // snapper snapshot path: <subvol>/.snapshots/<id>/snapshot
  // ("/" maps to /.snapshots/…, "/home" → /home/.snapshots/…) — verified live.
  function localSnapPath(subvol, id) {
    var sub = subvol === "/" ? "" : subvol
    return sub + "/.snapshots/" + id + "/snapshot"
  }
  function fmtSize(mb) {
    if (mb === null || mb === undefined) return "—"
    return (mb / 1024).toFixed(1) + " GB"
  }
  function bucketOf(t) {
    var days = t ? (Date.now() / 1000 - t) / 86400 : 999
    if (days <= 14) return "daily"
    if (days <= 56) return "weekly"
    return "monthly"
  }
  function bucketLetter(b) { return b === "daily" ? "D" : b === "weekly" ? "W" : "M" }
  function bucketColor(b) {
    return b === "daily" ? popup.ok : b === "weekly" ? popup.info : popup.warn
  }

  // ---- day-picker helpers (V4-safe: keys built by assignment, never
  // computed-key literals; dayKey = local "YYYY-MM-DD") ----------------------
  function dayKeyFromDate(d) {
    return d.getFullYear() + "-" + ("0" + (d.getMonth() + 1)).slice(-2)
      + "-" + ("0" + d.getDate()).slice(-2)
  }
  function todayKey() { return dayKeyFromDate(new Date()) }
  function yesterdayKey() {
    var d = new Date()
    d.setDate(d.getDate() - 1)
    return dayKeyFromDate(d)
  }
  function dayKeyOf(row) {
    // epoch preferred; fall back to parsing backup id or snapper iso string
    if (row && typeof row.t === "number" && row.t > 0)
      return dayKeyFromDate(new Date(row.t * 1000))
    if (row && typeof row.id === "string" && /^\d{8}-\d{4}$/.test(row.id))
      return row.id.substring(0, 4) + "-" + row.id.substring(4, 6) + "-" + row.id.substring(6, 8)
    if (row && typeof row.iso === "string" && row.iso.length >= 10)
      return row.iso.substring(0, 10)
    return "—"
  }
  function isExpanded(key) {
    if (popup.expandedDays[key] === true) return true
    if (popup.expandedDays[key] === false) return false
    return key === popup.todayKey()   // default: today open, rest collapsed
  }
  function toggleDay(key) {
    // REAL copy, not a reference: reassigning the same object back is a
    // no-op for QML var-property change detection (identity compare) and
    // no signal ever fires — carets went dead exactly this way.
    var d = {}, src = popup.expandedDays
    for (var k in src) d[k] = src[k]
    d[key] = !popup.isExpanded(key)   // assignment, not a computed-key literal
    popup.expandedDays = d
  }
  function dayLabelOf(key) {
    if (key === popup.todayKey()) return "Today"
    if (key === popup.yesterdayKey()) return "Yesterday"
    var p = key.split("-")
    if (p.length !== 3) return key
    var d = new Date(Number(p[0]), Number(p[1]) - 1, Number(p[2]))
    return d.toLocaleDateString(Qt.locale(), "dddd")
  }
  function daySubOf(key) {
    var p = key.split("-")
    if (p.length !== 3) return ""
    var d = new Date(Number(p[0]), Number(p[1]) - 1, Number(p[2]))
    return d.toLocaleDateString(Qt.locale(), "ddd MM/dd")
  }
  // group backups (w.snap.rows) into newest-day-first day buckets
  function backupDayGroups() {
    var groups = [], index = {}
    for (var i = 0; i < popup.snapRows.length; i++) {
      var r = popup.snapRows[i]
      var k = popup.dayKeyOf(r)
      if (!index[k]) {
        index[k] = { key: k, newestT: r.t, rows: [] }
        groups.push(index[k])
      }
      index[k].rows.push(r)
    }
    groups.sort(function(a, b) { return a.key < b.key ? 1 : -1 })
    for (var j = 0; j < groups.length; j++) {
      var g = groups[j]
      g.label = popup.dayLabelOf(g.key)
      g.sub = popup.daySubOf(g.key)
      g.noun = g.rows.length === 1 ? "backup" : "backups"
      g.bucket = popup.bucketOf(g.rows[0].t)
    }
    return groups
  }
  // group one snapper config's rows into day buckets (newest-first)
  function snapDayGroups(rows) {
    var groups = [], index = {}
    for (var i = 0; i < rows.length; i++) {
      var r = rows[i]
      var k = popup.dayKeyOf(r)
      if (!index[k]) {
        index[k] = { key: k, rows: [] }
        groups.push(index[k])
      }
      index[k].rows.push(r)
    }
    groups.sort(function(a, b) { return a.key < b.key ? 1 : -1 })
    for (var j = 0; j < groups.length; j++) {
      var g = groups[j]
      g.label = popup.dayLabelOf(g.key)
      g.sub = popup.daySubOf(g.key)
      g.noun = g.rows.length === 1 ? "snapshot" : "snapshots"
    }
    return groups
  }
  function snapTotal() {
    var n = 0, c = popup.snapper.configs || []
    for (var i = 0; i < c.length; i++) n += (c[i].count || 0)
    return n
  }
  function snapNewestT() {
    var best = 0, c = popup.snapper.configs || []
    for (var i = 0; i < c.length; i++) {
      var rows = c[i].rows || []
      if (rows.length && typeof rows[0].t === "number" && rows[0].t > best)
        best = rows[0].t
    }
    return best
  }

  // ---- shared v0.4.0 components (settings surfaces) ------------------------
  component SettingsCard: Rectangle {
    id: scard
    property string title: ""
    default property alias body: scardCol.data
    Layout.fillWidth: true
    implicitHeight: scardTitle.implicitHeight + scardCol.implicitHeight + Style.space(24)
    radius: Style.space(6)
    color: popup.cardBg
    Text {
      id: scardTitle
      anchors { top: parent.top; left: parent.left; margins: Style.space(10) }
      text: scard.title
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      font.letterSpacing: 1
      color: popup.muted
    }
    Column {
      id: scardCol
      anchors { top: scardTitle.bottom; left: parent.left; right: parent.right
                bottom: parent.bottom; margins: Style.space(10); topMargin: Style.space(4) }
      spacing: Style.space(6)
    }
  }

  component FieldSlot: Item {
    id: slot
    property string key: ""
    property string placeholder: ""
    property bool numeric: false
    property bool fill: true
    property int fixedWidth: 0
    Layout.fillWidth: slot.fill
    Layout.preferredWidth: slot.fixedWidth > 0 ? Style.space(slot.fixedWidth) : -1
    implicitHeight: slotField.implicitHeight + Style.space(10)
    Rectangle {
      anchors.fill: parent
      radius: Style.space(6)
      color: Style.normalFillFor(popup.fg, Color.accent, Color.urgent)
      border.width: 1
      border.color: slotField.activeFocus ? Style.selectedBorderFor(popup.fg)
        : popup.fieldError(slot.key) ? popup.bad
        : Style.normalBorderFor(popup.fg)
      Behavior on border.color { ColorAnimation { duration: 120 } }
    }
    TextField {
      id: slotField
      anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter
                margins: Style.space(6) }
      text: popup.dv(slot.key)
      placeholderText: slot.placeholder
      foreground: popup.fg
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
      verticalPadding: Style.space(2)
      background: null
      inputMethodHints: slot.numeric ? Qt.ImhDigitsOnly : Qt.ImhNone
      onTextChanged: if (slotField.text !== popup.dv(slot.key))
        popup.setDraft(slot.key, slotField.text)
    }
  }

  component FieldRow: Column {
    id: frow
    property string key: ""
    property string label: ""
    property string placeholder: ""
    property bool numeric: false
    property bool fill: true
    property int fixedWidth: 0
    property string helper: ""
    width: parent ? parent.width : 0
    spacing: 2
    RowLayout {
      width: parent.width
      spacing: Style.space(8)
      Text {
        Layout.preferredWidth: Style.space(96)
        text: frow.label
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        color: popup.muted
      }
      FieldSlot {
        key: frow.key; placeholder: frow.placeholder; numeric: frow.numeric
        fill: frow.fill; fixedWidth: frow.fixedWidth
      }
    }
    Text {
      visible: text.length > 0
      property string err: popup.fieldError(frow.key)
      text: err !== "" ? err : (frow.helper !== "" ? frow.helper : "")
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      font.bold: err !== ""
      color: err !== "" ? popup.bad : popup.muted
    }
  }

  component InstallButton: Rectangle {
    id: ibtn
    signal activated()
    property bool enabledOk: true
    property string idleLabel: "INSTALL TIMER"
    radius: Style.space(6)
    implicitWidth: ibtnText.implicitWidth + Style.space(16)
    implicitHeight: Style.space(28)
    color: popup.armInstall ? Qt.alpha(popup.warn, 0.14)
      : (ibtnMa.containsMouse && ibtn.enabledOk ? Style.hoverFillFor(popup.fg) : popup.cardBg)
    border.width: 1
    border.color: popup.armInstall ? popup.warn
      : ibtn.enabledOk ? Style.normalBorderFor(popup.fg) : Qt.alpha(popup.muted, 0.4)
    opacity: ibtn.enabledOk ? 1 : 0.5
    Behavior on color { ColorAnimation { duration: 120 } }
    Text {
      id: ibtnText
      anchors.centerIn: parent
      text: w.installState === "installing" ? "◌ installing…"
        : popup.armInstall ? "CONFIRM INSTALL?"
        : w.conf.timer_installed && !popup.onboarding ? "REINSTALL TIMER" : ibtn.idleLabel
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      font.bold: true
      color: popup.armInstall ? popup.warn : popup.fg
    }
    MouseArea {
      id: ibtnMa
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: {
        if (!ibtn.enabledOk && !popup.armInstall) return
        if (popup.armInstall) { popup.armInstall = false; ibtn.activated() }
        else { popup.armInstall = true; armTimer.restart() }
      }
    }
  }

  component TestResultRow: Row {
    id: trr
    spacing: Style.space(4)
    Text {
      anchors.verticalCenter: parent.verticalCenter
      text: popup.testLine().text
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
      font.bold: popup.testLine().hue === popup.ok
      color: popup.testLine().hue
    }
  }

  // ---- shared components ---------------------------------------------------
  component StatCard: Rectangle {
    id: card
    property string label
    property string value
    property string sub: ""
    property color vcolor: popup.fg
    Layout.fillWidth: true
    implicitHeight: Style.space(52)
    radius: Style.space(6)
    color: popup.cardBg

    Column {
      anchors.centerIn: parent
      spacing: 2
      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        text: card.label
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        color: popup.muted
      }
      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        text: card.value
        font.family: Style.font.family
        font.pixelSize: Style.font.body
        font.bold: true
        color: card.vcolor
      }
      Text {
        visible: card.sub.length > 0
        anchors.horizontalCenter: parent.horizontalCenter
        text: card.sub
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        color: popup.muted
      }
    }
  }

  // stadium pill: colored dot + bold word (color never the only carrier)
  component StatePill: Rectangle {
    id: pill
    property string word: ""
    property color hue: popup.fg
    property bool pulse: false
    height: Style.space(20)
    width: row.implicitWidth + Style.space(14)
    radius: height / 2
    color: Qt.alpha(pill.hue, 0.14)

    Row {
      id: row
      anchors.centerIn: parent
      spacing: Style.space(5)
      Rectangle {
        anchors.verticalCenter: parent.verticalCenter
        width: 7; height: 7; radius: 4
        color: pill.hue
        SequentialAnimation on opacity {
          running: pill.pulse
          loops: Animation.Infinite
          NumberAnimation { from: 1; to: 0.3; duration: 600 }
          NumberAnimation { from: 0.3; to: 1; duration: 600 }
        }
      }
      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: pill.word
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        font.bold: true
        color: pill.hue
      }
    }
  }

  // small bordered action pill (COPY / RECOVER / RETRY / CLEAR / BROWSE)
  component ActionPill: CursorSurface {
    id: apill
    signal activated()
    property string label
    property color hue: popup.fg
    bordered: true
    hasCursor: apillArea.containsMouse
    implicitWidth: apillText.implicitWidth + Style.space(12)
    implicitHeight: Style.space(20)
    Text {
      id: apillText
      anchors.centerIn: parent
      text: apill.label
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      font.bold: true
      color: apill.hue
    }
    MouseArea {
      id: apillArea
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: apill.activated()
    }
  }

  // collapsible day section — one learned gesture for both time-travel
  // layers (whole-row header target = Fitts; caret is the icon, not the
  // target). kind: "backup" | "snapshot" picks the row delegate.
  component DayGroup: Rectangle {
    id: dgroup
    required property var modelData
    required property int index
    property string kind: "backup"
    Layout.fillWidth: true
    implicitHeight: dgCol.implicitHeight
    radius: Style.space(6)
    color: popup.cardBg

    Column {
      id: dgCol
      anchors { left: parent.left; right: parent.right; top: parent.top }
      spacing: Style.space(4)

      // header: whole row toggles (420x32 target)
      Rectangle {
        width: parent.width
        height: Style.space(32)
        radius: Style.space(6)
        color: dgMa.containsMouse ? Style.hoverFillFor(popup.fg) : "transparent"
        Behavior on color { ColorAnimation { duration: 120 } }

        Row {
          anchors.fill: parent
          anchors.leftMargin: Style.space(8)
          anchors.rightMargin: Style.space(8)
          spacing: Style.space(8)

          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: "▸"
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
            color: popup.fg
            rotation: popup.isExpanded(dgroup.modelData.key) ? 90 : 0
            Behavior on rotation { NumberAnimation { duration: 120 } }
          }
          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: dgroup.modelData.label
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
            font.bold: true
            color: popup.fg
          }
          Text {
            visible: dgroup.modelData.label === "Today" || dgroup.modelData.label === "Yesterday"
            anchors.verticalCenter: parent.verticalCenter
            text: dgroup.modelData.sub
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            color: popup.muted
          }
          Item { Layout.fillWidth: true; height: 1 }
          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: dgroup.modelData.rows.length + " " + dgroup.modelData.noun
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            color: popup.muted
          }
          Text {
            visible: dgroup.kind === "backup"
            anchors.verticalCenter: parent.verticalCenter
            text: popup.bucketLetter(dgroup.modelData.bucket)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            font.bold: true
            color: popup.bucketColor(dgroup.modelData.bucket)
          }
        }

        MouseArea {
          id: dgMa
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: popup.toggleDay(dgroup.modelData.key)
        }
      }

      // rows: fade in place — never animate height (popup refits).
      // Wrapped in an Item: the 1px guide needs vertical anchors, which are
      // illegal inside a Column — the positioner then refuses to lay out and
      // every row vanishes (journal: "Column will not function").
      Item {
        id: dgRowsWrap
        visible: popup.isExpanded(dgroup.modelData.key)
        anchors { left: parent.left; right: parent.right; leftMargin: Style.space(10) }
        implicitHeight: dgRows.implicitHeight

        // 1px guide binds rows to their day (Gestalt common region)
        Rectangle {
          anchors { top: parent.top; bottom: parent.bottom; left: parent.left }
          width: 1
          color: Qt.alpha(popup.fg, 0.08)
        }

        Column {
          id: dgRows
          anchors { left: parent.left; right: parent.right; top: parent.top }
          spacing: Style.space(4)
          opacity: dgRowsWrap.visible ? 1 : 0
          Behavior on opacity { NumberAnimation { duration: 140 } }

        Repeater {
          model: dgroup.modelData.rows.length > w.snapshotRows
            ? dgroup.modelData.rows.slice(0, w.snapshotRows)
            : dgroup.modelData.rows
          delegate: Rectangle {
            id: drow
            required property var modelData
            required property int index
            width: parent ? parent.width : 0
            height: dgroup.kind === "backup" ? Style.space(44) : Style.space(32)
            radius: Style.space(6)
            color: "transparent"

            Row {
              anchors.fill: parent
              anchors.leftMargin: Style.space(6)
              anchors.rightMargin: Style.space(6)
              spacing: Style.space(6)

              Column {
                visible: dgroup.kind === "backup"
                anchors.verticalCenter: parent.verticalCenter
                spacing: 2
                Row {
                  spacing: Style.space(6)
                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: drow.modelData.id
                    font.family: Style.font.family
                    font.pixelSize: Style.font.bodySmall
                    font.bold: true
                    color: popup.fg
                  }
                  Rectangle {
                    visible: drow.modelData.id === popup.snap.latest
                    anchors.verticalCenter: parent.verticalCenter
                    width: drowLatest.implicitWidth + Style.space(10)
                    height: Style.space(16)
                    radius: height / 2
                    color: Style.selectedFillFor(popup.fg, Color.accent)
                    Text {
                      id: drowLatest
                      anchors.centerIn: parent
                      text: "latest"
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption
                      font.bold: true
                      color: popup.fg
                    }
                  }
                }
                Text {
                  text: popup.fmtAgo(drow.modelData.t) + " · " + popup.fmtIdDate(drow.modelData.id)
                    + " · " + popup.fmtSize(drow.modelData.mb)
                    + (drow.modelData.dur_s ? " · " + drow.modelData.dur_s + "s" : "")
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  color: popup.muted
                }
              }

              Row {
                visible: dgroup.kind === "snapshot"
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(6)
                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  text: (drow.modelData.iso && drow.modelData.iso.length >= 16)
                    ? drow.modelData.iso.substring(11, 16) : "—"
                  font.family: Style.font.family
                  font.pixelSize: Style.font.bodySmall
                  font.bold: true
                  color: popup.fg
                }
                TypeBadge {
                  word: drow.modelData.desc === "snap-pac" ? "snap-pac"
                    : drow.modelData.desc === "manual" ? "manual"
                    : drow.modelData.type === "pre" ? "pre"
                    : drow.modelData.type === "post" ? "post" : "timeline"
                  hue: drow.modelData.desc === "snap-pac" || drow.modelData.desc === "manual"
                    ? Color.accent
                    : drow.modelData.type === "pre" ? popup.warn
                    : drow.modelData.type === "post" ? popup.ok : popup.info
                }
                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  width: dgroup.width - Style.space(320)
                  text: drow.modelData.desc === "timeline" || drow.modelData.desc === "snap-pac"
                    ? "" : (drow.modelData.desc || "")
                  elide: Text.ElideRight
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  color: popup.muted
                }
              }

              Item { Layout.fillWidth: true; height: 1 }

              Row {
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(4)
                ActionPill {
                  visible: dgroup.kind === "backup"
                  label: "BROWSE"
                  onActivated: w.copyText(
                    "sshfs " + (popup.snap.scp_prefix || "<host>:/…/timemachine/backups/")
                    + drow.modelData.id + " ~/tm")
                }
                ActionPill {
                  visible: dgroup.kind === "backup"
                  label: "RECOVER"
                  hue: popup.ok
                  onActivated: {
                    popup.recoverSnapshot = drow.modelData.id
                    popup.currentTab = 4
                  }
                }
                ActionPill {
                  visible: dgroup.kind === "snapshot"
                  label: "BROWSE"
                  onActivated: host.openPath(
                    popup.localSnapPath(dgroup.subvol, drow.modelData.id))
                }
                ActionPill {
                  visible: dgroup.kind === "snapshot"
                  label: "RECOVER"
                  hue: popup.ok
                  onActivated: {
                    popup.recoverLocal = { subvol: dgroup.subvol, id: drow.modelData.id }
                    popup.currentTab = 4
                  }
                }
                ActionPill {
                  label: "COPY PATH"
                  onActivated: dgroup.kind === "backup"
                    ? w.copyText((popup.snap.scp_prefix || "<host>:/…/timemachine/backups/")
                                 + drow.modelData.id)
                    : w.copyText(popup.localSnapPath(dgroup.subvol, drow.modelData.id))
                }
              }
            }
          }
        }

        Text {
          visible: dgroup.modelData.rows.length > w.snapshotRows
          text: "showing first " + w.snapshotRows + " of "
            + dgroup.modelData.rows.length + " this day"
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          color: popup.muted
        }
        }
      }
    }

    // snapshot path composition lives on the popup (localSnapPath) —
    // shared with the RECOVERY tab's command card
    property string subvol: ""
  }

  // word + hue, dual-coded (WCAG 1.4.1 — color is never the only carrier)
  component TypeBadge: Rectangle {
    id: tbadge
    property string word: ""
    property color hue: popup.fg
    width: tbadgeText.implicitWidth + Style.space(10)
    height: Style.space(16)
    radius: height / 2
    color: Qt.alpha(tbadge.hue, 0.14)
    Text {
      id: tbadgeText
      anchors.centerIn: parent
      text: tbadge.word
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      font.bold: true
      color: tbadge.hue
    }
  }

  // ---- panel body -----------------------------------------------------------
  Flickable {
    id: flick
    anchors.fill: parent
    contentHeight: col.implicitHeight
    boundsBehavior: Flickable.StopAtBounds
    clip: true

    Keys.onPressed: function(ev) {
      if (ev.key === Qt.Key_Escape) { popup.armInstall = false; popup.open = false }
      else if (popup.onboarding) return   // no tabs to switch while setting up
      else if (ev.key === Qt.Key_1) popup.currentTab = 0
      else if (ev.key === Qt.Key_2) popup.currentTab = 1
      else if (ev.key === Qt.Key_3) popup.currentTab = 2
      else if (ev.key === Qt.Key_4) popup.currentTab = 3
      else if (ev.key === Qt.Key_5) popup.currentTab = 4
      else if (ev.key === Qt.Key_6) popup.currentTab = 5
      else if (ev.key === Qt.Key_Left) popup.currentTab = (popup.currentTab + 5) % 6
      else if (ev.key === Qt.Key_Right) popup.currentTab = (popup.currentTab + 1) % 6
      else return
      ev.accepted = true
    }

    ColumnLayout {
      id: col
      width: flick.width
      spacing: Style.space(10)

      // ---- header (persistent) --------------------------------------------
      RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(8)

        Text {
          text: "\uF1DA"
          font.family: Style.font.family
          font.pixelSize: Style.font.body
          color: popup.stateColor

          SequentialAnimation on opacity {
            running: popup.state === "running"
            loops: Animation.Infinite
            NumberAnimation { from: 1; to: 0.25; duration: 600 }
            NumberAnimation { from: 0.25; to: 1; duration: 600 }
          }
        }

        Text {
          text: "TIME MACHINE"
          font.family: Style.font.family
          font.pixelSize: Style.font.body
          font.bold: true
          color: popup.fg
        }

        Item { Layout.fillWidth: true }

        Text {
          text: popup.onboarding ? "not set up"
            : probe.next_run ? "next " + probe.next_run : "timer unknown"
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          color: popup.muted
        }
      }

      // ---- tab bar (persistent; state in-memory; hidden during onboarding) --
      Rectangle {
        visible: !popup.onboarding
        Layout.fillWidth: true
        implicitHeight: tabFlow.implicitHeight + Style.space(4)
        radius: Style.space(8)
        color: popup.cardBg

        // Flow, not Row: six full-word pills exceed 420 px at some theme
        // scales — they wrap to a second line instead of clipping (same
        // fallback idiom the spec uses for the STATUS cards).
        Flow {
          id: tabFlow
          anchors { left: parent.left; right: parent.right; top: parent.top }
          anchors.margins: Style.space(2)
          spacing: Style.space(4)

          component TabPill: CursorSurface {
            id: tpill
            property int idx: 0
            property string digit: "1"
            property string label: "STATUS"
            current: popup.currentTab === tpill.idx
            hasCursor: tpillArea.containsMouse
            implicitWidth: tpillRow.implicitWidth + Style.space(16)
            implicitHeight: Style.space(28)
            radius: Style.space(6)

            Behavior on color { ColorAnimation { duration: 120 } }

            property bool dot: false
            Row {
              id: tpillRow
              anchors.centerIn: parent
              spacing: Style.space(4)
              Rectangle {
                visible: tpill.dot && popup.dirty
                anchors.verticalCenter: parent.verticalCenter
                width: 6; height: 6; radius: 3
                color: Color.accent
              }
              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: tpill.digit
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                color: popup.muted
              }
              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: tpill.label
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                font.bold: true
                color: popup.currentTab === tpill.idx ? popup.fg : popup.muted
              }
            }
            MouseArea {
              id: tpillArea
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: popup.currentTab = tpill.idx
            }
          }

          TabPill { idx: 0; digit: "1"; label: "STATUS" }
          TabPill { idx: 1; digit: "2"; label: "BACKUPS" }
          TabPill { idx: 2; digit: "3"; label: "SNAPSHOTS" }
          TabPill { idx: 3; digit: "4"; label: "HEALTH" }
          TabPill { idx: 4; digit: "5"; label: "RECOVERY" }
          TabPill { idx: 5; digit: "6"; label: "SETTINGS"; dot: true }
        }
      }

      // ---- pages (one visible; popup refits to the active page) -------------
      Item {
        id: pages
        visible: !popup.onboarding
        Layout.fillWidth: true
        implicitHeight: children[popup.currentTab].implicitHeight

        // ================= TAB 1 · STATUS ==================================
        ColumnLayout {
          id: statusPage
          visible: popup.currentTab === 0
          width: pages.width
          spacing: Style.space(10)

          // reassurance row: state pill + one-line verdict
          RowLayout {
            Layout.fillWidth: true
            spacing: Style.space(8)
            StatePill {
              word: popup.stateWord()
              hue: popup.state === "never" ? popup.muted : popup.stateColor
              pulse: popup.state === "running"
            }
            Text {
              Layout.fillWidth: true
              text: popup.verdictLine()
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
              color: popup.muted
              elide: Text.ElideRight
            }
          }

          RowLayout {
            Layout.fillWidth: true
            spacing: Style.space(8)

            StatCard {
              label: "last backup"
              value: w.ageText
              sub: popup.fmtTs(probe.last_iso)
              vcolor: popup.stateColor
            }
            StatCard {
              label: "backup"
              value: probe.backup || "—"
              sub: (probe.size_mb || 0) + " MB · " + (probe.dur_s || 0) + "s"
            }
            StatCard {
              label: "history"
              value: (probe.backups_n || 0) + " in repo"
              sub: "avg " + Math.round(popup.sizeAvg) + " MB"
            }
            StatCard {
              label: "drill"
              value: drill ? (drill.pass + "/" + (drill.pass + drill.fail)) : "—"
              sub: drill ? popup.fmtTs(drill.ts) : "never run"
              vcolor: !drill ? popup.muted : drill.fail === 0 ? popup.ok : popup.bad
            }
          }

          // local btrfs snapshot freshness (fed by tm-snapper.sh, popup-open
          // only — hidden unless the feed answered ok; NN/g visibility of
          // system status)
          Text {
            visible: popup.snapper.status === "ok"
            Layout.fillWidth: true
            text: {
              var newest = popup.snapNewestT()
              var fresh = newest && (Date.now() / 1000 - newest) <= 7200
              return fresh
                ? "local snapshots current · " + popup.snapTotal() + " kept"
                : "local snapshots " + popup.fmtAgo(newest) + " old · " + popup.snapTotal() + " kept"
            }
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            color: (popup.snapNewestT() && (Date.now() / 1000 - popup.snapNewestT()) <= 7200)
              ? popup.ok : popup.warn
          }

          Rectangle {
            Layout.fillWidth: true
            implicitHeight: chartCol.implicitHeight + Style.space(20)
            radius: Style.space(6)
            color: popup.cardBg

            Column {
              id: chartCol
              anchors.fill: parent
              anchors.margins: Style.space(10)
              spacing: Style.space(6)

              RowLayout {
                width: parent.width
                Text {
                  text: "BACKUP SIZE — LAST " + popup.hist.length
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  color: popup.muted
                }
                Item { Layout.fillWidth: true }
                Text {
                  text: popup.hist.length
                    ? "max " + Math.round(popup.sizeMax) + " MB · avg "
                      + Math.round(popup.sizeAvg) + " MB" : ""
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  color: popup.muted
                }
              }

              SizeBars {
                id: bars
                width: parent.width
                barHeight: popup.hist.length ? Style.space(52) : Style.space(28)
                values: popup.sizes
                barColor: popup.info
                lastColor: popup.ok
              }

              Text {
                visible: popup.hist.length === 0
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                text: "no history yet — first backup will chart here"
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                color: popup.muted
              }

              // policy line wraps (never elides) — the restore doctrine
              // must survive any width (WCAG 1.4.4; the v0.2.0 defect)
              Text {
                width: parent.width
                property var ret: w.probe.retention || { daily: 14, weekly: 8, monthly: 12 }
                text: "rsync → " + w.label + " (plaintext) · schedule " + (w.probe.schedule || "")
                + " · retention " + ret.daily + "d/" + ret.weekly + "w/" + ret.monthly + "m"
                + " · sentinel verify weekly · restore = merge (ask first)"
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                color: popup.muted
                wrapMode: Text.WordWrap
              }
            }
          }

          RowLayout {
            Layout.fillWidth: true
            spacing: Style.space(8)

            CursorSurface {
              id: btnBackup
              bordered: true
              current: true   // primary: selected fill = the one filled button
              hasCursor: maBackup.containsMouse
              implicitWidth: btnBackupText.implicitWidth + Style.space(16)
              implicitHeight: Style.space(28)
              Text {
                id: btnBackupText
                anchors.centerIn: parent
                text: w.busy === "backup" ? "⟳ starting…" : "⟳ BACK UP NOW"
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                font.bold: true
                color: popup.fg
              }
              MouseArea {
                id: maBackup
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: w.backupNow()
              }
            }

            CursorSurface {
              id: btnDrill
              bordered: true
              hasCursor: maDrill.containsMouse
              implicitWidth: btnDrillText.implicitWidth + Style.space(16)
              implicitHeight: Style.space(28)
              Text {
                id: btnDrillText
                anchors.centerIn: parent
                text: w.busy === "drill" ? "◌ drilling…" : "✓ RUN DRILL"
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                font.bold: true
                color: popup.fg
              }
              MouseArea {
                id: maDrill
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: w.runDrill()
              }
            }

            Item { Layout.fillWidth: true }

            Text {
              visible: w.busy.length > 0
              text: w.busy === "drill" ? "restore drill running (~30–60s)" : ""
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              color: popup.muted
            }
          }

          Rectangle {
            visible: w.output.length > 0
            Layout.fillWidth: true
            implicitHeight: outText.implicitHeight + Style.space(16)
            radius: Style.space(6)
            color: Qt.alpha(popup.fg, 0.04)

            Text {
              id: outText
              anchors.fill: parent
              anchors.margins: Style.space(8)
              text: w.output
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              color: popup.muted
              wrapMode: Text.WrapAnywhere
            }
          }
        }

        // ================= TAB 2 · BACKUPS ==================================
        ColumnLayout {
          id: backupsPage
          visible: popup.currentTab === 1
          width: pages.width
          spacing: Style.space(10)

          // capacity card (title click = legacy list output, keeps the pin)
          Rectangle {
            visible: popup.snap.status === "ok"
            Layout.fillWidth: true
            implicitHeight: capCol.implicitHeight + Style.space(20)
            radius: Style.space(6)
            color: popup.cardBg

            Column {
              id: capCol
              anchors.fill: parent
              anchors.margins: Style.space(10)
              spacing: Style.space(6)

              RowLayout {
                width: parent.width
                spacing: Style.space(6)
                Text {
                  text: w.label
                  font.family: Style.font.family
                  font.pixelSize: Style.font.bodySmall
                  font.bold: true
                  color: popup.fg

                  MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: w.showRepo()
                  }
                }
                Item { Layout.fillWidth: true }
                Text {
                  text: popup.snap.total_gb
                    ? Math.round((1 - popup.snap.free_gb / popup.snap.total_gb) * 100) + "% used" : ""
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  color: popup.muted
                }
              }

              Text {
                width: parent.width
                text: (popup.snap.free_gb !== undefined ? popup.snap.free_gb : "—")
                  + " GB free of " + (popup.snap.total_gb !== undefined ? popup.snap.total_gb : "—")
                  + " GB · tree " + (popup.snap.tree_gb !== undefined && popup.snap.tree_gb !== null
                    ? popup.snap.tree_gb + " GB" : "—")
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                color: popup.muted
              }

              Rectangle {
                width: parent.width
                height: Style.space(4)
                radius: 2
                color: Qt.alpha(popup.fg, 0.08)
                Rectangle {
                  height: parent.height
                  width: popup.snap.total_gb
                    ? Math.max(0.02, Math.min(1, 1 - popup.snap.free_gb / popup.snap.total_gb))
                      * parent.width : 0
                  radius: 2
                  color: Color.accent
                  Behavior on width { NumberAnimation { duration: 250 } }
                }
              }
            }
          }

          // body: loading / unreachable / empty / ready
          Text {
            visible: popup.snap.status === "loading" || popup.snap.status === "idle"
            text: "◌ reading " + w.label + "…"
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            color: popup.muted

            SequentialAnimation on opacity {
              running: visible
              loops: Animation.Infinite
              NumberAnimation { from: 1; to: 0.3; duration: 600 }
              NumberAnimation { from: 0.3; to: 1; duration: 600 }
            }
          }

          RowLayout {
            visible: popup.snap.status === "unreachable" || popup.snap.status === "error"
            width: pages.width
            spacing: Style.space(8)
            Text {
              Layout.fillWidth: true
              text: popup.snap.status === "error"
                ? "backup listing failed — " + (popup.snap.detail || "stamp unreadable")
                : w.label + " unreachable"
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              color: popup.warn
            }
            ActionPill {
              label: "RETRY"
              hue: popup.warn
              onActivated: host.fetchSnapshots()
            }
          }

          Text {
            visible: popup.snap.status === "empty" || popup.snap.status === "never"
            text: popup.snap.status === "never"
              ? "no backup stamp yet — first backup pending"
              : "no backups on " + w.label + " yet — first backup pending"
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            color: popup.muted
          }

          // the day-grouped list (collapsed by default; today expanded)
          ColumnLayout {
            visible: popup.snap.status === "ok"
            width: pages.width
            spacing: Style.space(6)

            Repeater {
              model: popup.backupDayGroups()
              delegate: DayGroup { kind: "backup" }
            }
          }
        }

        // ================= TAB 3 · SNAPSHOTS (local btrfs) ====================
        ColumnLayout {
          id: snapshotsPage
          visible: popup.currentTab === 2
          width: pages.width
          spacing: Style.space(10)

          Text {
            visible: popup.snapper.status === "ok" || popup.snapper.status === "empty"
            Layout.fillWidth: true
            text: "local btrfs snapshots — hourly + on every package install"
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            color: popup.muted
            wrapMode: Text.WordWrap
          }
          Text {
            visible: popup.snapper.status === "ok" || popup.snapper.status === "empty"
            Layout.fillWidth: true
            text: "also bootable: pick one in the Limine boot menu at startup"
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            color: popup.muted
            wrapMode: Text.WordWrap
          }

          // manual pair — the pre-risky-change move (decision tree lane 2);
          // wheel-allowed, verified: create works without root on both configs
          RowLayout {
            visible: popup.snapper.status === "ok"
            width: pages.width
            spacing: Style.space(8)
            Text {
              Layout.fillWidth: true
              text: "creates a manual root + home pair now"
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              color: popup.muted
            }
            ActionPill {
              label: "SNAPSHOT NOW"
              hue: popup.ok
              onActivated: host.createSnapshots()
            }
          }

          Text {
            visible: popup.snapper.status === "idle" || popup.snapper.status === "loading"
            text: "◌ reading local snapshots…"
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            color: popup.muted

            SequentialAnimation on opacity {
              running: visible
              loops: Animation.Infinite
              NumberAnimation { from: 1; to: 0.3; duration: 600 }
              NumberAnimation { from: 0.3; to: 1; duration: 600 }
            }
          }

          RowLayout {
            visible: popup.snapper.status === "denied"
            width: pages.width
            spacing: Style.space(8)
            Text {
              Layout.fillWidth: true
              text: "can't list local snapshots — permission denied (root needed)"
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              color: popup.warn
            }
            ActionPill {
              label: "RETRY"
              hue: popup.warn
              onActivated: host.fetchSnapper()
            }
          }

          RowLayout {
            visible: popup.snapper.status === "unavailable"
            width: pages.width
            spacing: Style.space(8)
            Text {
              Layout.fillWidth: true
              text: "snapper not installed — local snapshots unavailable"
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              color: popup.muted
            }
            ActionPill {
              label: "RETRY"
              onActivated: host.fetchSnapper()
            }
          }

          Text {
            visible: popup.snapper.status === "empty"
            Layout.fillWidth: true
            text: "no local snapshots yet — created hourly and on package installs"
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            color: popup.muted
            wrapMode: Text.WordWrap
          }

          // one section per snapper config (root = SYSTEM @, home = HOME @HOME)
          Repeater {
            model: popup.snapper.status === "ok" ? (popup.snapper.configs || []) : []
            delegate: ColumnLayout {
              id: ssect
              required property var modelData
              required property int index
              width: pages.width
              spacing: Style.space(6)

              Text {
                text: (ssect.modelData.name === "root" ? "SYSTEM @" : "HOME @HOME")
                  + " · " + (ssect.modelData.count || 0)
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                font.letterSpacing: 1
                color: popup.muted
              }

              Repeater {
                model: popup.snapDayGroups(ssect.modelData.rows || [])
                delegate: DayGroup {
                  kind: "snapshot"
                  subvol: ssect.modelData.subvol || "/"
                }
              }
            }
          }
        }

        // ================= TAB 4 · HEALTH ====================================
        ColumnLayout {
          id: healthPage
          visible: popup.currentTab === 3
          width: pages.width
          spacing: Style.space(8)

          Text {
            Layout.fillWidth: true
            text: {
              if (drill && drill.fail > 0)
                return "drill failed " + drill.pass + "/" + (drill.pass + drill.fail) + " — inspect sentinels"
              if (drift && !drift.clean)
                return "drift needs review"
              if (!verify && !drill)
                return "first drill and verify still pending"
              if (!verify)
                return "drill " + drill.pass + "/" + (drill.pass + drill.fail) + " · verify first run Sunday"
              return "all checks green — nothing needs attention"
            }
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
            color: popup.muted
          }

          component HealthRow: Rectangle {
            id: hrow
            property string name
            property string sub: ""
            property string pillWord
            property color pillHue
            property string ts
            Layout.fillWidth: true
            implicitHeight: Style.space(40)
            radius: Style.space(6)
            color: popup.cardBg

            Row {
              anchors.fill: parent
              anchors.leftMargin: Style.space(10)
              anchors.rightMargin: Style.space(10)
              spacing: Style.space(8)

              Column {
                anchors.verticalCenter: parent.verticalCenter
                spacing: 1
                Text {
                  text: hrow.name
                  font.family: Style.font.family
                  font.pixelSize: Style.font.bodySmall
                  color: popup.fg
                }
                Text {
                  visible: hrow.sub.length > 0
                  text: hrow.sub
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  color: popup.muted
                }
              }

              Item { Layout.fillWidth: true }

              StatePill {
                anchors.verticalCenter: parent.verticalCenter
                word: hrow.pillWord
                hue: hrow.pillHue
              }

              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: hrow.ts
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                color: popup.muted
              }
            }
          }

          HealthRow {
            name: "restore drill"
            sub: drill && drill.fail === 0 && drill.pass === 0 ? "" : ""
            pillWord: drill ? (drill.pass + "/" + (drill.pass + drill.fail) + (drill.fail > 0 ? " FAIL" : " PASS"))
              : "—"
            pillHue: !drill ? popup.muted : drill.fail === 0 ? popup.ok : popup.bad
            ts: drill ? popup.fmtTs(drill.ts) : "never run"
          }
          HealthRow {
            name: "integrity verify"
            sub: verify ? "" : "first verify runs Sunday"
            pillWord: verify ? (verify.pass + "/" + verify.files) : "—"
            pillHue: verify ? (verify.fail === 0 ? popup.ok : popup.bad) : popup.muted
            ts: verify ? popup.fmtTs(verify.ts) : "—"
          }
          HealthRow {
            name: "healthcheck"
            sub: health ? "" : "healthcheck hasn't run yet"
            pillWord: health ? (health.ok ? "OK" : "ALERT") : "—"
            pillHue: !health ? popup.muted : health.ok ? popup.ok : popup.bad
            ts: health ? popup.fmtTs(health.ts) : "—"
          }
          HealthRow {
            name: "atlas drift"
            sub: drift && !drift.clean
              ? ("NEW-UNMANAGED " + drift.new_unmanaged + " · SIZE-JUMP " + drift.size_jump) : ""
            pillWord: drift ? (drift.clean ? "CLEAN" : "DRIFT") : "—"
            pillHue: !drift ? popup.muted : drift.clean ? popup.ok : popup.warn
            ts: popup.fmtTs(probe.last_iso)
          }
        }

        // ================= TAB 5 · RECOVERY ==================================
        ColumnLayout {
          id: recoveryPage
          visible: popup.currentTab === 4
          width: pages.width
          spacing: Style.space(10)

          Text {
            Layout.fillWidth: true
            text: "Files are plaintext on " + w.label + " — no keys, no tooling"
            font.family: Style.font.family
            font.pixelSize: Style.font.subtitle
            font.bold: true
            color: popup.fg
            wrapMode: Text.WordWrap
          }

          RowLayout {
            visible: popup.recoverSnapshot.length > 0
            width: pages.width
            spacing: Style.space(8)
            Text {
              Layout.fillWidth: true
              text: "recovering from " + popup.recoverSnapshot
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              color: popup.ok
            }
            ActionPill {
              label: "CLEAR"
              onActivated: popup.recoverSnapshot = ""
            }

            Behavior on opacity { NumberAnimation { duration: 140 } }
          }

          component CommandRow: Rectangle {
            id: crow
            property string label
            property string cmd
            property string note: ""
            Layout.fillWidth: true
            implicitHeight: crowCol.implicitHeight + Style.space(16)
            radius: Style.space(6)
            color: popup.cardBg

            Column {
              id: crowCol
              anchors.fill: parent
              anchors.margins: Style.space(10)
              spacing: Style.space(4)

              RowLayout {
                width: parent.width
                spacing: Style.space(6)
                Text {
                  Layout.alignment: Qt.AlignVCenter
                  text: crow.label
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  color: popup.muted
                }
                Item { Layout.fillWidth: true; height: 1 }
                ActionPill {
                  label: "COPY"
                  onActivated: w.copyText(crow.cmd)
                }
              }
              Text {
                width: parent.width
                text: crow.cmd
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
                color: popup.fg
                wrapMode: Text.WrapAnywhere
              }
              Text {
                visible: crow.note.length > 0
                width: parent.width
                text: crow.note
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                color: popup.muted
                wrapMode: Text.WordWrap
              }
            }
          }

          CommandRow {
            label: "browse-latest"
            cmd: "sshfs " + (popup.snap.scp_prefix || "<host>:/…/timemachine/backups/") + "latest ~/tm"
            note: "mount the newest backup as a folder — browse it in any file manager"
          }
          CommandRow {
            label: "fetch-one-file"
            cmd: "scp " + (popup.snap.scp_prefix || "<host>:/…/timemachine/backups/")
              + (popup.recoverSnapshot || popup.snap.latest || probe.backup || "<id>") + "/<path-to-file> ."
            note: popup.recoverSnapshot.length > 0
              ? "backup preselected from the Backups tab"
              : "swap in the backup id from the Backups tab"
          }
          CommandRow {
            visible: popup.recoverLocal !== null
            label: "recover-from-snapshot"
            cmd: "cp -a "
              + popup.localSnapPath(popup.recoverLocal ? popup.recoverLocal.subvol : "/",
                                    popup.recoverLocal ? popup.recoverLocal.id : 0)
              + "/<path-to-file> ."
            note: "local snapshot preselected from the Snapshots tab — merge, never overwrite"
          }
          CommandRow {
            label: "full-restore"
            cmd: "tm-restore.sh --latest"
            note: "merge, never overwrite — ask before restoring"
          }

          Text {
            Layout.fillWidth: true
            text: "restore = merge (ask first)"
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            color: popup.muted
          }

          // snapshot layout mini-map
          Rectangle {
            Layout.fillWidth: true
            implicitHeight: mapCol.implicitHeight + Style.space(16)
            radius: Style.space(6)
            color: popup.cardBg

            Column {
              id: mapCol
              anchors.fill: parent
              anchors.margins: Style.space(10)
              spacing: 2

              Text {
                text: "backup layout"
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                color: popup.muted
              }
              Repeater {
                model: popup.snapRows.slice(0, 3)
                delegate: Row {
                  spacing: Style.space(6)
                  Text {
                    text: index === 0 ? "├─" : "│ "
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    color: popup.muted
                  }
                  Text {
                    text: modelData.id + "/"
                    font.family: Style.font.family
                    font.pixelSize: Style.font.bodySmall
                    font.bold: modelData.id === popup.snap.latest
                    color: popup.fg
                  }
                  Text {
                    text: index === 0 ? "complete browsable HOME" : ""
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    color: popup.muted
                  }
                }
              }
              Row {
                spacing: Style.space(6)
                Text {
                  text: "└─"
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  color: popup.muted
                }
                Text {
                  text: "latest → " + (popup.snap.latest || "…")
                  font.family: Style.font.family
                  font.pixelSize: Style.font.bodySmall
                  font.bold: true
                  color: popup.fg
                }
              }
            }
          }
        }
        // ================= TAB 6 · SETTINGS ===================================
        ColumnLayout {
          id: settingsPage
          visible: popup.currentTab === 5 && !popup.onboarding
          width: pages.width
          spacing: Style.space(10)

          SettingsCard {
            title: "BACKUP TARGET"
            FieldRow {
              key: "TM_HOST"; label: "host"
              placeholder: "user@host"
              helper: "user@host — key-based ssh"
            }
            FieldRow {
              key: "TM_DEST"; label: "remote path"
              placeholder: "/mnt/pool/timemachine"
              helper: "snapshots land in <remote path>/snapshots/"
            }
            RowLayout {
              width: parent.width
              spacing: Style.space(8)
              FieldRow {
                Layout.preferredWidth: parent.width / 2 - Style.space(4)
                key: "TM_SSH_PORT"; label: "port"
                placeholder: "22"; numeric: true; fill: false; fixedWidth: 70
              }
              FieldRow {
                Layout.preferredWidth: parent.width / 2 - Style.space(4)
                key: "TM_LABEL"; label: "label"
                placeholder: "nas"
                helper: "shown in the popup — empty = hostname"
              }
            }
          }

          SettingsCard {
            title: "SCHEDULE"
            FieldRow {
              key: "TM_SCHEDULE"; label: "times"
              placeholder: "09:20,21:20"
              helper: "comma list of HH:MM — installs a systemd timer"
            }
            Text {
              width: parent.width
              text: w.conf.timer_installed
                ? "timer installed — next " + (w.conf.timer_next || "fire pending")
                : "timer not installed — press INSTALL TIMER below"
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              color: w.conf.timer_installed ? popup.muted : popup.warn
            }
          }

          SettingsCard {
            title: "RETENTION"
            RowLayout {
              width: parent.width
              spacing: Style.space(8)
              FieldRow {
                Layout.preferredWidth: parent.width / 3 - Style.space(3)
                key: "TM_RETENTION_DAILY"; label: "daily"
                placeholder: "14"; numeric: true; fill: false; fixedWidth: 70
              }
              FieldRow {
                Layout.preferredWidth: parent.width / 3 - Style.space(3)
                key: "TM_RETENTION_WEEKLY"; label: "weekly"
                placeholder: "8"; numeric: true; fill: false; fixedWidth: 70
              }
              FieldRow {
                Layout.preferredWidth: parent.width / 3 - Style.space(3)
                key: "TM_RETENTION_MONTHLY"; label: "monthly"
                placeholder: "12"; numeric: true; fill: false; fixedWidth: 70
              }
            }
          }

          SettingsCard {
            title: "HEALTH & INTEGRITY"
            RowLayout {
              width: parent.width
              spacing: Style.space(8)
              FieldRow {
                Layout.preferredWidth: parent.width / 2 - Style.space(4)
                key: "TM_MAX_AGE_H"; label: "fail if older"
                placeholder: "30"; numeric: true; fill: false; fixedWidth: 70
                helper: "hours"
              }
              FieldRow {
                Layout.preferredWidth: parent.width / 2 - Style.space(4)
                key: "TM_VERIFY_DOW"; label: "verify day"
                placeholder: "7"; numeric: true; fill: false; fixedWidth: 70
                helper: "1=Mon … 7=Sun"
              }
            }
            Text {
              text: "sentinel files — files that must survive a restore"
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              color: popup.muted
            }
            Repeater {
              model: popup.sentinels.length
              RowLayout {
                width: parent.width
                spacing: Style.space(6)
                Item {
                  Layout.fillWidth: true
                  implicitHeight: srowField.implicitHeight + Style.space(10)
                  Rectangle {
                    anchors.fill: parent
                    radius: Style.space(6)
                    color: Style.normalFillFor(popup.fg, Color.accent, Color.urgent)
                    border.width: 1
                    border.color: srowField.activeFocus ? Style.selectedBorderFor(popup.fg)
                      : Style.normalBorderFor(popup.fg)
                    Behavior on border.color { ColorAnimation { duration: 120 } }
                  }
                  TextField {
                    id: srowField
                    anchors { left: parent.left; right: parent.right
                              verticalCenter: parent.verticalCenter; margins: Style.space(6) }
                    text: popup.sentinels[index]
                    placeholderText: "path/relative/to/home"
                    foreground: popup.fg
                    font.family: Style.font.family
                    font.pixelSize: Style.font.bodySmall
                    verticalPadding: Style.space(2)
                    background: null
                    onTextChanged: if (srowField.text !== popup.sentinels[index])
                      popup.setSentinel(index, srowField.text)
                  }
                }
                ActionPill {
                  label: "×"
                  hue: popup.muted
                  onActivated: popup.removeSentinel(index)
                }
              }
            }
            Text {
              visible: popup.sentinels.length === 0
              text: "no sentinel files — add files that must survive"
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              color: popup.muted
            }
            ActionPill {
              label: "+ ADD SENTINEL"
              onActivated: popup.addSentinel()
            }
            FieldRow {
              key: "TM_NOTIFY_CMD"; label: "notify on failure"
              placeholder: "optional"
              helper: "sh -c command run when the health check fails"
            }
          }

          SettingsCard {
            title: "DISPLAY (OMARCHY SETTINGS)"
            opacity: 0.5
            Text {
              width: parent.width
              text: "refresh " + w.refreshSeconds + "s · stale " + w.staleHours
                + "h · fail " + w.failHours + "h · history " + w.historyDays
                + "d · rows " + w.snapshotRows
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
              color: popup.fg
            }
            Text {
              width: parent.width
              text: "display-only — change these in Omarchy plugin settings"
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              color: popup.muted
            }
          }

          Text {
            visible: w.saveState === "failed"
            text: "● save failed — " + (w.saveErr || "tm-conf.sh rejected a value")
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
            color: popup.bad
          }

          RowLayout {
            Layout.fillWidth: true
            spacing: Style.space(8)
            CursorSurface {
              id: btnTest
              bordered: true
              hasCursor: maTest.containsMouse
              opacity: w.conf.configured && w.testRes.state !== "running" ? 1 : 0.5
              implicitWidth: btnTestText.implicitWidth + Style.space(16)
              implicitHeight: Style.space(28)
              Text {
                id: btnTestText
                anchors.centerIn: parent
                text: w.testRes.state === "running" ? "◌ testing…"
                  : popup.dirty ? "SAVE & TEST" : "TEST CONNECTION"
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                font.bold: true
                color: popup.dirty ? Color.accent : popup.fg
              }
              MouseArea {
                id: maTest
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  if (w.testRes.state === "running" || w.saveState === "saving") return
                  if (!w.conf.configured && !popup.dirty) return
                  if (popup.dirty) {
                    if (popup.hasErrors) return
                    popup.pendingTest = true
                    w.saveKeys(popup.changedQueue())
                  } else {
                    w.testConnection()
                  }
                }
              }
            }
            Item { Layout.fillWidth: true }
            InstallButton {
              enabledOk: !popup.scheduleDirty && w.conf.configured
              onActivated: w.installTimer()
            }
            CursorSurface {
              id: btnSave
              current: true   // filled primary
              hasCursor: maSave.containsMouse
              opacity: popup.dirty && !popup.hasErrors && w.saveState !== "saving" ? 1 : 0.5
              implicitWidth: btnSaveText.implicitWidth + Style.space(16)
              implicitHeight: Style.space(28)
              Text {
                id: btnSaveText
                anchors.centerIn: parent
                text: w.saveState === "saving" ? "◌ saving…"
                  : w.saveState === "saved" ? "✓ saved" : "SAVE"
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                font.bold: true
                color: w.saveState === "saved" ? popup.ok : popup.fg
              }
              MouseArea {
                id: maSave
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  if (!popup.dirty || popup.hasErrors || w.saveState === "saving") return
                  w.saveKeys(popup.changedQueue())
                }
              }
            }
          }

          TestResultRow { }
        }
      }

      // ---- onboarding (replaces tab bar + pages until configured) -----------
      Rectangle {
        visible: popup.onboarding
        Layout.fillWidth: true
        implicitHeight: onboardingCol.implicitHeight + Style.space(28)
        radius: Style.space(6)
        color: popup.cardBg

        Column {
          id: onboardingCol
          anchors { fill: parent; margins: Style.space(14) }
          spacing: Style.space(10)

          Text {
            width: parent.width
            text: "SET UP BACKUPS"
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            font.letterSpacing: 1
            color: popup.muted
          }
          Text {
            width: parent.width
            wrapMode: Text.WordWrap
            text: "Whole-home backups to your own NAS or server — plain files, browsable, no keys."
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
            color: popup.fg
          }
          FieldRow {
            key: "TM_HOST"; label: "backup host"
            placeholder: "user@nas.example"
            helper: "key-based ssh — run ssh-copy-id first"
          }
          FieldRow {
            key: "TM_DEST"; label: "remote path"
            placeholder: "/mnt/pool/timemachine"
          }
          FieldRow {
            key: "TM_LABEL"; label: "label"
            placeholder: "nas — optional"
          }
          TestResultRow { }
          Text {
            visible: w.saveState === "failed"
            text: "● save failed — " + (w.saveErr || "tm-conf.sh rejected a value")
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
            color: popup.bad
          }
          RowLayout {
            width: parent.width
            spacing: Style.space(8)
            CursorSurface {
              id: btnObTest
              current: true   // filled primary
              hasCursor: maObTest.containsMouse
              opacity: dv("TM_HOST") && dv("TM_DEST") && !popup.hasErrors
                && w.testRes.state !== "running" ? 1 : 0.5
              implicitWidth: btnObTestText.implicitWidth + Style.space(16)
              implicitHeight: Style.space(28)
              Text {
                id: btnObTestText
                anchors.centerIn: parent
                text: w.testRes.state === "running" ? "◌ testing…" : "SAVE & TEST CONNECTION"
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                font.bold: true
                color: popup.fg
              }
              MouseArea {
                id: maObTest
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  if (!dv("TM_HOST") || !dv("TM_DEST") || popup.hasErrors) return
                  if (w.testRes.state === "running" || w.saveState === "saving") return
                  var q = []
                  if (dv("TM_HOST") !== (w.conf.host || "")) q.push(["TM_HOST", dv("TM_HOST")])
                  if (dv("TM_DEST") !== (w.conf.dest || "")) q.push(["TM_DEST", dv("TM_DEST")])
                  if (dv("TM_LABEL") !== (w.conf.label || "")) q.push(["TM_LABEL", dv("TM_LABEL")])
                  popup.pendingTest = true
                  w.saveKeys(q)
                }
              }
            }
            Item { Layout.fillWidth: true }
            InstallButton {
              enabledOk: w.testRes.state === "ok"
              onActivated: w.installTimer()
            }
            CursorSurface {
              id: btnObBackup
              bordered: true
              hasCursor: maObBackup.containsMouse
              opacity: w.testRes.state === "ok"
                && (w.conf.timer_installed || w.installState === "done") ? 1 : 0.5
              implicitWidth: btnObBackupText.implicitWidth + Style.space(16)
              implicitHeight: Style.space(28)
              Text {
                id: btnObBackupText
                anchors.centerIn: parent
                text: w.busy === "backup" ? "⟳ starting…" : "⟳ BACK UP NOW"
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                font.bold: true
                color: popup.fg
              }
              MouseArea {
                id: maObBackup
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  if (w.testRes.state !== "ok") return
                  if (!(w.conf.timer_installed || w.installState === "done")) return
                  w.backupNow()
                }
              }
            }
          }
          Text {
            width: parent.width
            text: "schedule defaults to 09:20,21:20 — tune it later in SETTINGS"
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            color: popup.muted
          }
          ActionPill {
            visible: w.testRes.state === "ok" || w.testRes.state === "fail"
            label: "open the dashboard →"
            hue: popup.muted
            onActivated: {
              w.fetchConf()
              popup.currentTab = 0
            }
          }
        }
      }
    }
  }
}
