import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import qs.Commons
import qs.Ui

// Agent workspaces: each slot is a fixed index cell (the number, or a pin icon) plus a
// name tail when the workspace holds a Claude Code session. Session name and state come
// from the terminal title Claude sets ("<glyph> <title>"); "needs you" from a hook flag.
// Design: UI expert spec 2026-09-05. Colours are the bar's theme tokens only.
BarWidget {
  id: root
  moduleName: "omarchy.workspaces"

  readonly property string home: Quickshell.env("HOME")
  readonly property string stateDir: (Quickshell.env("XDG_STATE_HOME") || home + "/.local/state") + "/omarchy/agent-workspaces"

  property var config: ({})     // workspace-names.json: "2": "name" | {"icon","label","name","launch"}
  property var needs: ({})      // needs.json: window address -> timestamp
  property var slugs: ({})      // slugs.json: full title -> label (Haiku)
  property var local: ({})      // title -> heuristic label, from `agent-ws slug`
  property var lastActive: ({}) // window address -> ms of last title/focus change
  property var asked: ({})      // titles already sent to agent-ws slug

  readonly property string workingGlyphs: "◐◑◒◓"
  readonly property string idleGlyph: "✳"
  readonly property real cellWidth: Style.space(24)
  readonly property real tailPad: Style.space(10)
  // Budget from the screen, never from the bar: the bar's width depends on ours (binding loop).
  readonly property var screenOf: root.QsWindow.window ? root.QsWindow.window.screen : null
  readonly property real barWidth: screenOf ? screenOf.width : (Quickshell.screens.length ? Quickshell.screens[0].width : 1920)
  readonly property real budget: barWidth * 0.30
  Component.onCompleted: { root.debug("agent-workspaces: budget " + Math.round(budget) + "px of screen " + Math.round(barWidth)); Qt.callLater(root.scanTitles) }
  readonly property color fg: root.bar ? root.bar.barForeground : Color.foreground
  // Needs-you: the theme's urgent colour, unless the bar is transparent (measured 1.16:1 there).
  readonly property color loud: root.bar && !root.bar.transparent ? root.bar.urgent : fg
  readonly property bool animate: root.bar ? root.bar.foregroundAnimationEnabled : true

  // ---------- files ----------
  FileView {
    path: root.home + "/.config/omarchy/workspace-names.json"
    watchChanges: true; printErrors: false
    onLoaded: { root.config = root.parse(text()); root.forgetWidths() }
    onLoadFailed: root.config = ({})
    onFileChanged: reload()
  }
  FileView {
    path: root.stateDir + "/needs.json"
    watchChanges: true; printErrors: false
    onLoaded: root.needs = root.parse(text())
    onLoadFailed: root.needs = ({})
    onFileChanged: reload()
  }
  FileView {
    path: root.stateDir + "/slugs.json"
    watchChanges: true; printErrors: false
    onLoaded: root.slugs = root.parse(text())
    onLoadFailed: root.slugs = ({})
    onFileChanged: reload()
  }
  // Hyprland reports window addresses as "0x55..." over hyprctl and bare over the event
  // socket. Everything here is compared without the prefix, lowercased.
  function normAddr(a) { return String(a || "").replace(/^0x/i, "").toLowerCase() }

  function parse(t) {
    try { var v = JSON.parse(t || "{}"); return (v && typeof v === "object") ? v : ({}) } catch (e) { return ({}) }
  }

  // Most-recently-active session: Hyprland tells us when a title or the focused window changes.
  Connections {
    target: Hyprland
    function onRawEvent(ev) {
      if (ev.name === "windowtitlev2" || ev.name === "activewindowv2") {
        var addr = root.normAddr(String(ev.data).split(",")[0])
        if (!addr) return
        var m = Object.assign({}, root.lastActive); m[addr] = Date.now(); root.lastActive = m
      }
      if (ev.name === "openwindow" || ev.name === "closewindow") root.forgetWidths()
      if (ev.name === "windowtitlev2" || ev.name === "openwindow") Qt.callLater(root.scanTitles)
    }
  }

  // Heuristic label now (and Haiku in the background) via the agent-ws tool, once per title.
  Process {
    id: slugProc
    property string title: ""
    command: ["agent-ws", "slug", title]
    stdout: StdioCollector {
      id: slugOut
      onStreamFinished: {
        var m = Object.assign({}, root.local); m[slugProc.title] = slugOut.text.trim(); root.local = m
        root.forgetWidths()
      }
    }
  }
  property var queue: []
  function requestSlug(title) {
    if (root.asked[title]) return
    var a = Object.assign({}, root.asked); a[title] = true; root.asked = a
    root.queue = root.queue.concat([title]); pump()
  }
  function pump() {
    if (slugProc.running || root.queue.length === 0) return
    slugProc.title = root.queue[0]; root.queue = root.queue.slice(1); slugProc.running = true
  }
  Connections { target: slugProc; function onRunningChanged() { if (!slugProc.running) root.pump() } }

  // ---------- model ----------
  function workspaceById(id) {
    var v = Hyprland.workspaces.values
    for (var i = 0; i < v.length; i++) if (v[i].id === id) return v[i]
    return null
  }
  function workspaceIds() {
    var ids = [1, 2, 3, 4, 5]
    var v = Hyprland.workspaces.values
    for (var i = 0; i < v.length; i++) {
      var id = v[i].id
      if (id > 0 && id <= 10 && ids.indexOf(id) === -1) ids.push(id)
    }
    for (var k in root.config) { var n = parseInt(k); if (n > 0 && n <= 10 && ids.indexOf(n) === -1 && root.pinOf(n)) ids.push(n) }
    ids.sort(function(a, b) { return a - b })
    return ids
  }
  function entry(id) {
    var e = root.config[String(id)]
    if (typeof e === "string") return e.trim() ? ({ name: e.trim() }) : null
    return (e && typeof e === "object") ? e : null
  }
  function manualName(id) { var e = entry(id); return e && e.name ? String(e.name).slice(0, 14) : "" }
  function pinOf(id) { var e = entry(id); return e && e.icon ? e : null }
  function pinGlyph(icon) {
    switch (String(icon)) {
      case "youtube": return ""
      case "container": return String.fromCodePoint(0xF01A7)
      case "x": return "X"
      default: return String(icon)
    }
  }

  // Sessions in a workspace: Claude windows, recognised by the status glyph in their title.
  function sessionsIn(ws) {
    var out = []
    if (!ws) return out
    var tls = ws.toplevels.values
    for (var i = 0; i < tls.length; i++) {
      var t = tls[i]; var title = String(t.title || "")
      if (title.length === 0) continue      // indexOf("") is 0: an untitled window would match
      var g = title.charAt(0)
      var working = root.workingGlyphs.indexOf(g) !== -1
      if (!working && g !== root.idleGlyph) continue
      var ipc = t.lastIpcObject || {}
      var addr = root.normAddr(t.address !== undefined ? t.address : ipc.address)
      var flagged = t.urgent === true
      if (!flagged) for (var k in root.needs) if (root.normAddr(k) === addr) { flagged = true; break }
      var full = title.slice(1).trim()
      out.push({ title: full, addr: addr, focused: !!t.activated,
                 state: flagged ? "needs" : (working ? "working" : "idle"),
                 last: root.lastActive[addr] || 0 })
    }
    return out
  }
  function worst(sessions) {
    var s = "none"
    for (var i = 0; i < sessions.length; i++) {
      if (sessions[i].state === "needs") return "needs"
      if (sessions[i].state === "working") s = "working"
      else if (s === "none") s = "idle"
    }
    return s
  }
  function lead(sessions) {
    var best = null
    for (var i = 0; i < sessions.length; i++) {
      var s = sessions[i]
      if (!best || (s.focused && !best.focused) || (s.focused === best.focused && s.last > best.last)) best = s
    }
    return best
  }
  function label(title) {
    if (!title) return ""
    var l = root.slugs[title] !== undefined ? String(root.slugs[title])
          : (root.local[title] !== undefined ? String(root.local[title]) : "")
    return l.length > 13 ? l.split(/[ \-]/)[0].slice(0, 10) : l
  }
  // Ask agent-ws for labels of titles we have not seen. Runs from window events, never from a binding.
  Process {
    id: dbg
    property string line: ""
    command: ["agent-ws", "log", dbg.line]
    stdout: StdioCollector {}
  }
  property var dbgQueue: []
  function debug(msg) { root.dbgQueue = root.dbgQueue.concat([String(msg)]); root.dbgPump() }
  function dbgPump() {
    if (dbg.running || root.dbgQueue.length === 0) return
    dbg.line = root.dbgQueue[0]; root.dbgQueue = root.dbgQueue.slice(1); dbg.running = true
  }
  Connections { target: dbg; function onRunningChanged() { if (!dbg.running) root.dbgPump() } }
  function scanTitles() {
    var v = Hyprland.workspaces.values
    for (var i = 0; i < v.length; i++) {
      var ss = root.sessionsIn(v[i])
      for (var j = 0; j < ss.length; j++)
        if (!root.slugs[ss[j].title] && root.local[ss[j].title] === undefined) root.requestSlug(ss[j].title)
    }
  }
  Timer { interval: 2000; repeat: true; running: true; onTriggered: root.scanTitles() }

  function stateWord(s) { return s === "needs" ? "needs you" : s }

  // ---------- width ladder ----------
  // The Row reports what it wants at the current level; if that overruns the budget we step
  // down one level and it re-reports. Measured, not estimated, so it cannot drift from reality.
  // 0: full label · 1: first word · 2: first word, only where something is happening ·
  // 3: only the focused slot and any slot needing you
  readonly property int maxLevel: 3
  property int level: 0
  // What the row asked for at each rung. A rung already measured as too wide is never
  // returned to, otherwise a name that fits at one rung and overruns the next pumps forever.
  property var widthAt: ({})
  function forgetWidths() { root.widthAt = ({}) }
  function fullNameFor(id, sessions) {
    var m = manualName(id); if (m) return m
    if (pinOf(id)) return ""
    var l = lead(sessions); return l ? label(l.title) : ""
  }
  function shown(name, level, state, focused) {
    if (!name) return ""
    if (level >= 3 && !focused && state !== "needs") return ""
    if (level >= 2 && !focused && state !== "needs" && state !== "working") return ""
    if (level >= 1) return name.split(/[ \-]/)[0]
    return name
  }
  Timer {
    id: ladder
    interval: 60; repeat: false
    onTriggered: {
      var want = row.implicitWidth
      var w = Object.assign({}, root.widthAt); w[root.level] = want; root.widthAt = w
      if (want > root.budget && root.level < root.maxLevel) {
        root.level += 1; ladder.restart(); return
      }
      var up = root.level - 1
      if (root.level > 0 && want < root.budget * 0.75
          && (root.widthAt[up] === undefined || root.widthAt[up] <= root.budget)) {
        root.level -= 1; ladder.restart()
      }
    }
  }
  onLevelChanged: root.debug("level " + level + " (row wants " + Math.round(row.implicitWidth) + " of " + Math.round(budget) + ")")

  implicitWidth: row.implicitWidth + Style.spaceReal(1.5)
  implicitHeight: row.implicitHeight

  Row {
    id: row
    spacing: 0
    onImplicitWidthChanged: ladder.restart()
    anchors.verticalCenter: parent.verticalCenter

    Repeater {
      model: root.workspaceIds()

      Item {
        id: slot
        required property int modelData
        readonly property var workspace: root.workspaceById(modelData)
        readonly property var sessions: root.sessionsIn(workspace)
        readonly property string wsState: root.worst(sessions)
        readonly property bool focused: Hyprland.focusedWorkspace !== null && Hyprland.focusedWorkspace.id === modelData
        readonly property bool occupied: workspace !== null && workspace.toplevels.values.length > 0
        readonly property var pin: root.pinOf(modelData)
        readonly property string name: root.shown(root.fullNameFor(modelData, sessions), root.level, wsState, focused)
        readonly property bool loud: wsState === "needs"

        width: root.cellWidth + (nameText.visible ? nameText.implicitWidth + root.tailPad : 0)
        height: root.barSize
        Behavior on width { enabled: root.animate; NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }

        // index cell: number or pin glyph, plus every mark
        Item {
          id: cell
          width: root.cellWidth; height: parent.height

          Text {
            anchors.centerIn: parent
            text: slot.pin ? root.pinGlyph(slot.pin.icon) : (slot.modelData === 10 ? "0" : String(slot.modelData))
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: slot.pin && slot.pin.icon !== "x" ? Style.bar.iconFont : Style.font.body
            color: slot.loud ? root.loud : root.fg
            opacity: slot.occupied || slot.focused ? 1 : 0.5
            Behavior on color { enabled: root.animate; ColorAnimation { duration: 160 } }
            Behavior on opacity { enabled: root.animate; NumberAnimation { duration: 160 } }
          }
          Rectangle {   // working / idle
            anchors.bottom: parent.bottom; anchors.bottomMargin: Style.space(4); anchors.horizontalCenter: parent.horizontalCenter
            width: 3; height: 3; radius: 1.5; color: root.fg
            opacity: slot.wsState === "working" ? 1 : (slot.wsState === "idle" ? 0.5 : 0)
            Behavior on opacity { enabled: root.animate; NumberAnimation { duration: 160 } }
          }
          Rectangle {   // needs you
            anchors.bottom: parent.bottom; anchors.left: parent.left; anchors.right: parent.right
            height: 2; color: root.loud
            opacity: slot.loud ? 1 : 0
            Behavior on opacity { enabled: root.animate; NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
          }
        }

        Text {
          id: nameText
          anchors.left: cell.right
          anchors.verticalCenter: parent.verticalCenter
          text: slot.name
          visible: slot.name !== "" && !root.vertical
          textFormat: Text.PlainText
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.caption
          color: slot.loud ? root.loud : root.fg
          opacity: 0.85
          Behavior on color { enabled: root.animate; ColorAnimation { duration: 160 } }
          // The heuristic label lands first and Haiku replaces it seconds later; fade the
          // swap so it reads as the same name settling, not as the row blinking.
          onTextChanged: if (root.animate) nameFade.restart()
          NumberAnimation {
            id: nameFade
            target: nameText; property: "opacity"; from: 0; to: 0.85
            duration: 160; easing.type: Easing.OutCubic
          }
        }

        Rectangle {   // focus: over the number, and over the name when there is one
          anchors.top: parent.top
          anchors.left: parent.left
          anchors.right: nameText.visible ? nameText.right : cell.right
          height: 2; color: root.fg; visible: slot.focused
        }

        MouseArea {
          anchors.fill: parent
          hoverEnabled: true
          onClicked: if (root.bar) root.bar.run("hyprctl dispatch " + Util.shellQuote("hl.dsp.focus({ workspace = \"" + slot.modelData + "\" })"))
          onEntered: { var t = slot.tooltip(); if (t && root.bar) root.bar.showTooltip(slot, t) }
          onExited: if (root.bar) root.bar.hideTooltip(slot)
        }

        function tooltip() {
          var head = String(modelData)
          var mn = root.manualName(modelData); if (mn) head += " · " + mn
          else if (pin) head += " · " + (pin.label || pin.icon)
          if (sessions.length === 0) return (mn || pin) ? head : ""
          var order = { needs: 0, working: 1, idle: 2 }
          var ss = sessions.slice().sort(function(a, b) { return (order[a.state] - order[b.state]) || (b.last - a.last) })
          var lines = [head]
          for (var i = 0; i < Math.min(4, ss.length); i++) {
            var t = ss[i].title.length > 48 ? ss[i].title.slice(0, 47) + "…" : ss[i].title
            lines.push(root.stateWord(ss[i].state) + " — " + t)
          }
          if (ss.length > 4) lines.push("+" + (ss.length - 4) + " more")
          return lines.join("\n")
        }
      }
    }
  }
}
