// Notification profiles: a bar chip showing the active profile, a popup to
// switch between them, and an editor for the rules each one carries.
//
// The daemon (zeroge.notifications) owns the profile state. This panel never
// writes the settings file itself — it reads over IPC and hands whole profile
// lists back, so a notification arriving mid-edit cannot interleave with a
// half-written rule set.

import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "zeroge.notification-profiles"
  ipcTarget: "notification-profiles"

  // Mirror of the daemon's state, refreshed after every command.
  property var profiles: []
  property string activeName: ""
  property var seenApps: []
  property var importantApps: []

  // Which profile the editor is showing. Empty means the switcher list.
  property string editingName: ""
  // "switcher" | "editor" | "history" — the editor also needs editingName set.
  property string view: "switcher"
  property var historyRows: []
  property bool historyLoading: false

  // The editor works on a local copy and only reaches the daemon on Save —
  // every earlier version sent each toggle immediately, which is fine for a
  // switch but wrong for a name/icon a person is still deciding on, and it's
  // what a new profile needs anyway: nothing to show in the switcher until
  // there's a Create to press.
  property var draft: null
  property bool draftIsNew: false
  property bool iconPickerOpen: false

  // Installed-app picker: search DesktopEntries for an app that hasn't sent
  // a notification yet, so its rules can be set up ahead of time. Query
  // text lives here (not the TextField's own text) so closing and
  // reopening the picker starts clean.
  property bool appPickerOpen: false
  property string appPickerQuery: ""
  readonly property int appPickerResultsCap: 8

  readonly property var appPickerResults: {
    if (!root.appPickerOpen) return []
    var query = root.appPickerQuery.trim().toLowerCase()
    var tracked = {}
    for (var i = 0; i < root.seenApps.length; i++) tracked[String(root.seenApps[i]).toLowerCase()] = true
    var out = []
    var values = DesktopEntries.applications.values || []
    for (var j = 0; j < values.length && out.length < root.appPickerResultsCap; j++) {
      var entry = values[j]
      var name = String((entry && entry.name) || "").trim()
      if (!name || tracked[name.toLowerCase()]) continue
      if (query && name.toLowerCase().indexOf(query) === -1) continue
      out.push({ name: name, icon: (entry && entry.icon) || "" })
    }
    return out
  }

  function addTrackedApp(name) {
    var app = String(name || "").trim()
    if (!app) return
    // Applied locally first, same reasoning as everywhere else in this file:
    // the round-trip to the daemon and back would leave the row missing from
    // root.seenApps for one refresh cycle otherwise.
    var already = false
    for (var i = 0; i < root.seenApps.length; i++) {
      if (String(root.seenApps[i]).toLowerCase() === app.toLowerCase()) { already = true; break }
    }
    if (!already) root.seenApps = root.seenApps.concat([app])
    run(["trackApp", app])
    root.appPickerOpen = false
    root.appPickerQuery = ""
  }

  readonly property var availableIcons: [
    "󰂚", "󰂱", "󰖃", "󰽥", "󰖨", "󰋜", "󰋑", "󰓎", "󰈻", "󰄦",
    "󰂺", "󰝚", "󰅩", "󰒃", "󰊄", "󰀝", "󰄋", "󰣆", "󰄐", "󰉚",
    "󰏲", "󰇮", "󰃭", "󰔂", "󰋋", "󰜎", "󰂴", "󰏑", "󰕷", "󰌧",
    "󰐗", "󰑦", "󰒓", "󰄨", "󰌾", "󰃢"
  ]

  function openEditor(profile, isNew) {
    root.draft = {
      name: profile.name,
      icon: profile.icon || "",
      muteApps: (profile.muteApps || []).slice(),
      dndAll: !!profile.dndAll,
      // Plain per-profile boolean, defaulting true (allow) for a profile
      // that has never touched it.
      allowUnknownApps: typeof profile.allowUnknownApps === "boolean" ? profile.allowUnknownApps : true,
      // Per-app "keep this app's toast on screen" override for this
      // profile, an inherit/on/off shape keyed per app instead of a single
      // value — this one is unrelated to allowUnknownApps.
      importantOverrideOn: (profile.importantOverrideOn || []).slice(),
      importantOverrideOff: (profile.importantOverrideOff || []).slice()
    }
    root.draftIsNew = !!isNew
    root.editingName = profile.name
    root.iconPickerOpen = false
    root.view = "editor"
  }

  function closeEditor() {
    root.draft = null
    root.editingName = ""
    root.iconPickerOpen = false
    root.view = "switcher"
  }

  // The global-apps screen has no draft to discard — just a plain nav back,
  // kept as its own function so a future addition to closeEditor's cleanup
  // doesn't silently start running for this screen too.
  function openGlobalApps() {
    root.appPickerOpen = false
    root.appPickerQuery = ""
    root.view = "globalApps"
  }

  function closeGlobalApps() {
    root.appPickerOpen = false
    root.appPickerQuery = ""
    root.view = "switcher"
  }

  // Every draft edit goes through this: one place that carries every field
  // forward, so adding a field to the draft only means changing it here
  // instead of at each call site that happens to build one.
  function mergeDraft(changes) {
    if (!root.draft) return
    root.draft = {
      name: changes.name !== undefined ? changes.name : root.draft.name,
      icon: changes.icon !== undefined ? changes.icon : root.draft.icon,
      muteApps: changes.muteApps !== undefined ? changes.muteApps : root.draft.muteApps,
      dndAll: changes.dndAll !== undefined ? changes.dndAll : root.draft.dndAll,
      allowUnknownApps: changes.allowUnknownApps !== undefined ? changes.allowUnknownApps : root.draft.allowUnknownApps,
      importantOverrideOn: changes.importantOverrideOn !== undefined ? changes.importantOverrideOn : root.draft.importantOverrideOn,
      importantOverrideOff: changes.importantOverrideOff !== undefined ? changes.importantOverrideOff : root.draft.importantOverrideOff
    }
  }

  // Tri-state read for one app in the draft: true/false if this profile
  // overrides it, null if it's inheriting the global.
  function draftImportantOverride(app) {
    if (!root.draft) return null
    var needle = String(app || "").toLowerCase()
    var on = root.draft.importantOverrideOn || []
    for (var i = 0; i < on.length; i++) {
      if (String(on[i]).toLowerCase() === needle) return true
    }
    var off = root.draft.importantOverrideOff || []
    for (var j = 0; j < off.length; j++) {
      if (String(off[j]).toLowerCase() === needle) return false
    }
    return null
  }

  // value: true/false to set an override, null to clear it back to inherit.
  function setDraftImportantOverride(app, value) {
    if (!root.draft) return
    var needle = String(app || "").trim()
    if (!needle) return
    var on = (root.draft.importantOverrideOn || []).filter(function(a) {
      return String(a).trim().toLowerCase() !== needle.toLowerCase()
    })
    var off = (root.draft.importantOverrideOff || []).filter(function(a) {
      return String(a).trim().toLowerCase() !== needle.toLowerCase()
    })
    if (value === true) on.push(needle)
    else if (value === false) off.push(needle)
    root.mergeDraft({ importantOverrideOn: on, importantOverrideOff: off })
  }

  function draftMuted(app) {
    if (!root.draft) return false
    var needle = String(app || "").toLowerCase()
    var list = root.draft.muteApps || []
    for (var i = 0; i < list.length; i++) {
      if (String(list[i]).toLowerCase() === needle) return true
    }
    return false
  }

  function setDraftMuted(app, muted) {
    if (!root.draft) return
    var needle = String(app || "").trim()
    if (!needle) return
    var apps = (root.draft.muteApps || []).filter(function(a) {
      return String(a).trim().toLowerCase() !== needle.toLowerCase()
    })
    if (muted) apps.push(needle)
    root.mergeDraft({ muteApps: apps })
  }

  // Saves the draft: a rename target still has to be unique, an empty name
  // just keeps the old one rather than saving something unusable.
  function saveDraft() {
    if (!root.draft) return
    var wanted = String(root.draft.name || "").trim()
    if (!wanted) wanted = root.editingName
    if (wanted !== root.editingName && root.findProfile(wanted)) wanted = root.editingName

    var entry = {
      name: wanted,
      icon: root.draft.icon,
      muteApps: root.draft.muteApps,
      dndAll: root.draft.dndAll,
      allowUnknownApps: root.draft.allowUnknownApps,
      importantOverrideOn: root.draft.importantOverrideOn,
      importantOverrideOff: root.draft.importantOverrideOff
    }
    var next
    if (root.draftIsNew) {
      next = root.profiles.concat([entry])
    } else {
      next = root.profiles.map(function(p) { return p.name === root.editingName ? entry : p })
    }
    root.profiles = next
    saveProfiles(next)
    root.closeEditor()
  }

  readonly property var active: findProfile(activeName)
  readonly property string icon: active && active.icon ? active.icon : "󰂚"
  readonly property bool showName: setting("showProfileName", true) === true

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.5)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  function findProfile(name) {
    for (var i = 0; i < profiles.length; i++) {
      if (profiles[i] && profiles[i].name === String(name || "")) return profiles[i]
    }
    return null
  }

  // ---------------------------------------------------------------- daemon

  // Every command goes out through the same process and refreshes on the way
  // back, so the panel can never drift from what the daemon actually holds.
  Process {
    id: cmd
    property bool refreshAfter: true
    stdout: StdioCollector {
      onStreamFinished: {
        if (cmd.refreshAfter) refresh.running = true
      }
    }
  }

  Process {
    id: refresh
    command: ["omarchy-shell", "notifications", "listProfiles"]
    stdout: StdioCollector {
      onStreamFinished: root.applyState(this.text)
    }
  }

  function applyState(raw) {
    var parsed = null
    try {
      parsed = JSON.parse(String(raw || "").trim())
    } catch (e) {
      // The daemon is mid-restart or predates profiles. Leaving the last
      // known state up beats blanking the widget on a transient failure.
      return
    }
    if (!parsed) return
    root.profiles = Array.isArray(parsed.profiles) ? parsed.profiles : []
    root.activeName = String(parsed.active || "")
    root.seenApps = Array.isArray(parsed.seenApps) ? parsed.seenApps : []
    if (Array.isArray(parsed.importantApps)) root.importantApps = parsed.importantApps
  }

  function isImportantApp(app) {
    var needle = String(app || "").toLowerCase()
    for (var i = 0; i < root.importantApps.length; i++) {
      if (String(root.importantApps[i]).toLowerCase() === needle) return true
    }
    return false
  }

  function setImportantApp(app, important) {
    var next = root.importantApps.filter(function(a) { return a !== app })
    if (important) next.push(app)
    root.importantApps = next
    run(["setImportantApp", app, important ? "true" : "false"])
  }

  function forgetSeenApp(app) {
    root.seenApps = root.seenApps.filter(function(a) { return a !== app })
    run(["forgetSeenApp", app])
  }

  function run(args) {
    cmd.command = ["omarchy-shell", "notifications"].concat(args)
    cmd.running = true
  }

  function switchTo(name) {
    run(["setProfile", name])
    root.close()
  }

  function saveProfiles(list) {
    // Sent as {"profiles": [...]}, not a bare array — qs ipc's argv parsing
    // strips a leading "[" / trailing "]" from an argument that is exactly
    // one, which silently truncated every save to garbage. See the matching
    // note on the daemon's saveProfiles.
    run(["saveProfiles", JSON.stringify({ profiles: list })])
  }

  // Opens the editor on a fresh draft. Names are the identity the daemon
  // matches on, so a new one has to be unique before Save ever sends it —
  // nothing is written until then, unlike the old version which created and
  // saved the profile immediately on click.
  function addProfile() {
    var base = "New profile"
    var name = base
    var n = 2
    while (findProfile(name)) { name = base + " " + n; n++ }
    root.openEditor({ name: name, icon: root.availableIcons[0], muteApps: [], dndAll: false }, true)
  }

  // Mirrors Service.qml's defaultProfileName — the daemon is authoritative
  // and re-adds this one if a list ever arrives without it, but the button
  // is hidden here too so deleting it never looks like an option in the
  // first place.
  readonly property string defaultProfileName: "Normal"

  function deleteProfile(name) {
    if (name === root.defaultProfileName) return
    var next = profiles.filter(function(p) { return p.name !== name })
    // The daemon falls back to the first profile when the list empties, but a
    // list with nothing in it silences the switcher entirely — keep one.
    if (!next.length) return
    root.profiles = next
    saveProfiles(next)
    root.closeEditor()
  }

  // ---------------------------------------------------------------- history
  //
  // Reads the daemon's own history files straight off disk rather than
  // through IPC: they're already the daemon's public, readable record (the
  // stock notifications plugin lets any script glob the same directory), and
  // an IPC method can only return synchronously, which a directory read
  // can't promise.

  readonly property string historyDir: Quickshell.env("HOME") + "/.local/state/omarchy/notifications/history/"

  Process {
    id: historyProc
    command: ["bash", "-c", "awk 1 \"$1\"/*.json 2>/dev/null || true", "--", root.historyDir]
    stdout: StdioCollector {
      onStreamFinished: root.applyHistory(this.text)
    }
    onExited: root.historyLoading = false
  }

  function loadHistory() {
    if (historyProc.running) return
    root.historyLoading = true
    historyProc.running = true
  }

  function applyHistory(raw) {
    var lines = String(raw || "").split("\n")
    var rows = []
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i].trim()
      if (!line) continue
      try {
        var value = JSON.parse(line)
        if (value && typeof value === "object") rows.push(value)
      } catch (e) {
        // A torn write from a crash mid-save — skip the line, keep the rest.
      }
    }
    rows.sort(function(a, b) { return (b.timestamp || 0) - (a.timestamp || 0) })
    root.historyRows = rows.slice(0, 50)
  }

  // Same resolution NotificationCard.qml uses for the live toast's icon: a
  // file:// or image:// value is used as-is, an absolute path is turned into
  // a file URL, and anything else (a bare name like "brave-browser") is
  // looked up as a themed icon. History rows persist appIcon as this same
  // string, so it resolves exactly the same way once archived.
  function iconSource(icon) {
    var value = String(icon || "")
    if (value.length === 0) return ""
    if (value.indexOf("file://") === 0 || value.indexOf("image://") === 0) return value
    if (value.charAt(0) === "/") return Util.fileUrl(value)
    return Quickshell.iconPath(value, true)
  }

  function relativeTime(ms) {
    var deltaSec = Math.max(0, Math.round((Date.now() - Number(ms || 0)) / 1000))
    if (deltaSec < 60) return "just now"
    var deltaMin = Math.round(deltaSec / 60)
    if (deltaMin < 60) return deltaMin + (deltaMin === 1 ? " min ago" : " min ago")
    var deltaHour = Math.round(deltaMin / 60)
    if (deltaHour < 24) return deltaHour + (deltaHour === 1 ? " hour ago" : " hours ago")
    var deltaDay = Math.round(deltaHour / 24)
    return deltaDay + (deltaDay === 1 ? " day ago" : " days ago")
  }

  function isMuted(profile, app) {
    if (!profile) return false
    var needle = String(app || "").toLowerCase()
    var list = profile.muteApps || []
    for (var i = 0; i < list.length; i++) {
      if (String(list[i]).toLowerCase() === needle) return true
    }
    return false
  }

  Component.onCompleted: refresh.running = true

  // Reopening always re-reads: DND and profile can both be changed from the
  // command line while the panel is closed.
  onOpenedChanged: {
    if (opened) {
      root.closeEditor()
      refresh.running = true
      root.loadHistory()
    }
  }


  // ------------------------------------------------------------- bar chip
  //
  // Icon and label are separate elements: BarIconButton's glyph is drawn by
  // OpticalGlyph, which optically centers a single icon codepoint and isn't
  // meant to shape a run that mixes an icon with plain text in the same
  // string (mixing them here once rendered as a garbled overlap).

  implicitWidth: chip.implicitWidth
  implicitHeight: chip.implicitHeight

  // WidgetButton: the same base every other bar chip with a click + hover
  // cursor uses. It renders icon-and-label as one plain-text run (no
  // OpticalGlyph single-glyph assumption to fight) and owns exactly one
  // MouseArea, which is what earlier attempts here kept colliding with.
  WidgetButton {
    id: chip
    anchors.fill: parent
    bar: root.bar
    text: root.showName && root.activeName && !root.bar.vertical
      ? root.icon + "  " + root.activeName
      : root.icon
    fixedHeight: root.bar ? root.bar.barSize : Style.bar.sizeHorizontal
    onPressed: function(b) { root.handleChipPress(b) }
  }

  function handleChipPress(button) {
    if (button === Qt.RightButton) {
      // Straight into the editor for what is on now — the common reason to
      // right-click is "this profile just let something through".
      if (!root.opened) root.open()
      var current = root.findProfile(root.activeName)
      if (current) root.openEditor(current, false)
    } else {
      root.toggle()
    }
  }

  // ---------------------------------------------------------------- popup

  KeyboardPanel {
    id: panel
    anchorItem: root
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keys
    contentWidth: panel.fittedContentWidth(Style.space(360))
    // Capped well under a full screen: history can grow past that on its
    // own, and the Flickable below is what makes the rest of the panel
    // reachable once it does, rather than the whole card just growing
    // off-screen.
    contentHeight: panel.fittedContentHeight(
      (profileStrip.visible ? profileStrip.implicitHeight + Style.space(12) : 0) + content.implicitHeight,
      Style.space(480))

    PanelKeyCatcher {
      id: keys
      anchors.fill: parent
      onCloseRequested: {
        // Escape backs out of the editor (discarding the draft) or the
        // global-apps screen first, then closes the panel.
        if (root.view === "editor") root.closeEditor()
        else if (root.view === "globalApps") root.closeGlobalApps()
        else root.close()
      }
      onTabRequested: function(direction) { root.switchPanel(direction) }

      // ---------- profile strip: pinned above the scrollable history below,
      // not part of the Flickable, so it stays put while history scrolls ----------

      Column {
        id: profileStrip
        width: parent.width
        spacing: Style.space(6)
        visible: root.view === "switcher"

        Item {
          width: parent.width
          implicitHeight: Math.max(profileHeader.implicitHeight, globalAppsButton.height)

          PanelSectionHeader {
            id: profileHeader
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: "Notification profile"
            fontFamily: root.fontFamily
            foreground: root.foreground
          }

          // Reach-anywhere entry to the global (not-per-profile) app
          // settings — the master Important toggle, the "allow unknown
          // apps" default, and the add-app picker. Those used to live only
          // inside a specific profile's editor, which read as if they were
          // scoped to that one profile when they apply everywhere.
          Rectangle {
            id: globalAppsButton
            width: Style.space(26)
            height: Style.space(26)
            radius: width / 2
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            color: globalAppsMouse.containsMouse ? Style.hoverFillFor(root.foreground, Color.accent) : "transparent"

            Text {
              anchors.centerIn: parent
              textFormat: Text.PlainText
              text: "󰒓"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }

            MouseArea {
              id: globalAppsMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.openGlobalApps()

              PanelToolTip {
                visible: globalAppsMouse.containsMouse
                text: "Global app settings — applies across every profile"
                fontFamily: root.fontFamily
              }
            }
          }
        }

        // One profile chip's visuals + behavior, shared between the two
        // container modes below so switching modes at the cap never means
        // two copies of this to keep in sync.
        Component {
          id: profileChipComponent

          Rectangle {
            id: chipRoot
            required property var modelData
            readonly property bool isActive: modelData.name === root.activeName

            // Flow mode sizes each chip to its content (a Flow, unlike
            // Column, never stretches children); the scrollable-list mode
            // stretches every row to the list's full width instead, which
            // reads better as a list than a run of left-aligned pills would.
            // Left/right-anchored content below (rather than centered) means
            // this doesn't need its own separate layout per mode — a
            // compact chip's width already equals its content's natural
            // width, so the anchors collapse to the same look either way.
            //
            // Both Repeaters exist at once (one under a hidden Flow), so
            // which mode is active is read from the same global condition
            // that decides Flow-vs-list visibility, not from this instance's
            // own parent — a per-parent-type check can't tell "the Flow I'm
            // in happens to be the hidden one right now" from "the visible
            // one", since both are real Items either way.
            readonly property bool stretchToFill: root.profiles.length > profileStrip.chipOverflowCap
            width: stretchToFill && parent ? parent.width : implicitWidth
            implicitWidth: nameText.implicitWidth + editChipBg.width + Style.space(24)
            implicitHeight: Style.space(32)
            radius: height / 2
            color: chipMouse.containsMouse
              ? Style.hoverFillFor(root.foreground, Color.accent)
              : (isActive ? Style.selectedFillFor(root.foreground, Color.accent) : "transparent")
            border.width: isActive ? 0 : 1
            border.color: Qt.darker(root.foreground, 2.2)

            MouseArea {
              id: chipMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.switchTo(chipRoot.modelData.name)
            }

            Text {
              id: nameText
              textFormat: Text.PlainText
              anchors.left: parent.left
              anchors.leftMargin: Style.space(12)
              anchors.right: editChipBg.left
              anchors.rightMargin: Style.space(6)
              anchors.verticalCenter: parent.verticalCenter
              text: (chipRoot.modelData.icon || "󰂚") + "  " + chipRoot.modelData.name
              color: chipRoot.isActive ? root.foreground : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: chipRoot.isActive
              elide: Text.ElideRight
            }

            // A second, smaller click target inside the chip: editing a
            // profile is rarer than switching to it, so it doesn't need
            // equal weight, just its own hit area — a small hover circle,
            // same treatment as the other inline glyph buttons.
            Rectangle {
              id: editChipBg
              width: Style.space(18)
              height: Style.space(18)
              radius: width / 2
              anchors.right: parent.right
              anchors.rightMargin: Style.space(7)
              anchors.verticalCenter: parent.verticalCenter
              color: editChipMouse.containsMouse ? Style.hoverFillFor(root.foreground, Color.accent) : "transparent"

              Text {
                textFormat: Text.PlainText
                anchors.centerIn: parent
                text: "󰏫"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              MouseArea {
                id: editChipMouse
                anchors.fill: parent
                anchors.margins: -Style.space(2)
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: function(mouse) {
                  mouse.accepted = true
                  root.openEditor(chipRoot.modelData, false)
                }
              }
            }
          }
        }

        // The "+" add-chip, shared the same way — appended after the last
        // profile chip in Flow mode, or as its own row below the list in
        // scrollable mode.
        Component {
          id: addChipComponent

          Rectangle {
            implicitWidth: Style.space(30)
            implicitHeight: Style.space(30)
            radius: height / 2
            color: addMouse.containsMouse ? Style.hoverFillFor(root.foreground, Color.accent) : "transparent"
            border.width: 1
            border.color: Qt.darker(root.foreground, 2.2)

            Text {
              anchors.centerIn: parent
              text: "+"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.subtitle
            }

            MouseArea {
              id: addMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.addProfile()
            }
          }
        }

        // Past this many profiles a wrapping Flow starts eating too much of
        // the panel's height on its own — a fixed-height scrollable list
        // reads better than a chip block that can grow without bound.
        readonly property int chipOverflowCap: 8

        Flow {
          width: parent.width
          spacing: Style.space(6)
          visible: root.profiles.length <= profileStrip.chipOverflowCap

          Repeater {
            model: root.profiles
            delegate: profileChipComponent
          }

          Loader { sourceComponent: addChipComponent }
        }

        Column {
          width: parent.width
          spacing: Style.space(6)
          visible: root.profiles.length > profileStrip.chipOverflowCap

          // A handful of rows' worth of height, then it scrolls — long
          // enough to feel like a real list, short enough that history below
          // still gets the majority of the panel.
          Flickable {
            width: parent.width
            height: Math.min(chipListColumn.implicitHeight, Style.space(32 * 5 + 6 * 4))
            contentWidth: width
            contentHeight: chipListColumn.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            flickableDirection: Flickable.VerticalFlick
            interactive: contentHeight > height
            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

            Column {
              id: chipListColumn
              width: parent.width
              spacing: Style.space(6)

              Repeater {
                model: root.profiles
                delegate: profileChipComponent
              }
            }
          }

          Loader { sourceComponent: addChipComponent }
        }

        PanelSeparator { width: parent.width }
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        // The strip above already reserved its own space in the Column below
        // panelFlick's sibling slot — the Flickable only needs to yield the
        // height profileStrip occupies, not re-lay it out itself.
        anchors.topMargin: profileStrip.visible ? profileStrip.implicitHeight + Style.space(12) : 0
        contentWidth: width
        contentHeight: content.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { id: historyScrollBar; policy: ScrollBar.AsNeeded }

      Column {
        id: content
        // Narrowed by the scrollbar's own width when it's actually taking up
        // space (AsNeeded means it can be 0 while everything fits) — the
        // remove button sits at the row's right edge, exactly where an
        // overlaid scrollbar would land on top of it otherwise.
        width: panelFlick.width - (historyScrollBar.visible ? historyScrollBar.width : 0)
        spacing: Style.space(12)

        // ---------- editor: works on root.draft, a local copy. Nothing
        // reaches the daemon until Save/Create — Cancel and the back arrow
        // both just discard it via closeEditor(). ----------

        Column {
          width: parent.width
          spacing: Style.space(10)
          visible: root.view === "editor" && root.draft !== null

          Item {
            width: parent.width
            implicitHeight: Math.max(backButton.height, editTitle.implicitHeight)

            BarIconButton {
              id: backButton
              bar: root.bar
              width: Style.space(30)
              height: Style.space(30)
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: "󰅁"
              onPressed: function(b) { root.closeEditor() }
            }

            Text {
              id: editTitle
              anchors.left: backButton.right
              anchors.leftMargin: Style.space(8)
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: root.draftIsNew ? "New profile" : root.editingName
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
            }
          }

          // ---- icon + name ----

          Item {
            width: parent.width
            implicitHeight: Math.max(iconButton.height, nameField.implicitHeight)

            Rectangle {
              id: iconButton
              width: Style.space(40)
              height: Style.space(40)
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              radius: Style.spacing.labelGap
              color: iconButtonMouse.containsMouse
                ? Style.hoverFillFor(root.foreground, Color.accent)
                : Style.normalFillFor(root.foreground, Color.accent)
              border.width: 1
              border.color: Qt.darker(root.foreground, 2.2)

              Text {
                anchors.centerIn: parent
                textFormat: Text.PlainText
                text: root.draft ? (root.draft.icon || "󰂚") : "󰂚"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.subtitle
              }

              MouseArea {
                id: iconButtonMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.iconPickerOpen = !root.iconPickerOpen
              }
            }

            TextField {
              id: nameField
              anchors.left: iconButton.right
              anchors.leftMargin: Style.space(10)
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              foreground: root.foreground
              placeholderText: "Profile name"
              // Rebinding on every keystroke would fight the cursor; the
              // text is seeded once when the editor opens instead, and
              // synced into the draft as it's typed — no immediate send.
              text: root.draft ? root.draft.name : ""
              onTextChanged: {
                if (root.draft && text !== root.draft.name)
                  root.mergeDraft({ name: text })
              }
            }
          }

          // ---- icon picker: a fixed palette rather than free typing, so
          // every choice is a glyph already known to render on this bar ----

          Flow {
            width: parent.width
            spacing: Style.space(6)
            visible: root.iconPickerOpen

            Repeater {
              model: root.availableIcons

              delegate: Rectangle {
                required property string modelData
                readonly property bool isSelected: root.draft && root.draft.icon === modelData

                width: Style.space(32)
                height: Style.space(32)
                radius: Style.spacing.labelGap
                color: iconOptionMouse.containsMouse
                  ? Style.hoverFillFor(root.foreground, Color.accent)
                  : (isSelected ? Style.selectedFillFor(root.foreground, Color.accent) : "transparent")
                border.width: isSelected ? 0 : 1
                border.color: Qt.darker(root.foreground, 2.2)

                Text {
                  anchors.centerIn: parent
                  textFormat: Text.PlainText
                  text: modelData
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.subtitle
                }

                MouseArea {
                  id: iconOptionMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: {
                    root.mergeDraft({ icon: modelData })
                    root.iconPickerOpen = false
                  }
                }
              }
            }
          }

          Item {
            width: parent.width
            implicitHeight: Math.max(dndLabel.implicitHeight, dndSwitch.implicitHeight)

            Column {
              id: dndLabel
              anchors.left: parent.left
              anchors.right: dndSwitch.left
              anchors.rightMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(1)

              Text {
                text: "Silence everything"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                elide: Text.ElideRight
                width: parent.width
              }

              Text {
                text: "Nothing raises a toast. It all still lands in history."
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
                width: parent.width
              }
            }

            ToggleSwitch {
              id: dndSwitch
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              foreground: root.foreground
              checked: root.draft ? !!root.draft.dndAll : false
              onToggled: root.mergeDraft({ dndAll: !root.draft.dndAll })
            }
          }

          Item {
            width: parent.width
            implicitHeight: Math.max(unknownAppsDraftLabel.implicitHeight, unknownAppsDraftSwitch.implicitHeight)

            Column {
              id: unknownAppsDraftLabel
              anchors.left: parent.left
              anchors.right: unknownAppsDraftSwitch.left
              anchors.rightMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(1)

              Text {
                text: "Apps you haven't seen before"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                elide: Text.ElideRight
                width: parent.width
              }

              Text {
                text: root.draft && root.draft.allowUnknownApps
                  ? "On. A first-time sender shows normally in this profile."
                  : "Off. A first-time sender is silenced in this profile (still recorded below) until it's sent once."
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
                wrapMode: Text.WordWrap
                width: parent.width
              }
            }

            ToggleSwitch {
              id: unknownAppsDraftSwitch
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              foreground: root.foreground
              checked: root.draft ? !!root.draft.allowUnknownApps : true
              onToggled: root.mergeDraft({ allowUnknownApps: !root.draft.allowUnknownApps })
            }
          }

          PanelSeparator { width: parent.width }

          Item {
            width: parent.width
            implicitHeight: Math.max(muteHeader.implicitHeight, openGlobalAppsFromEditor.height)

            PanelSectionHeader {
              id: muteHeader
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: "Mute these apps"
              fontFamily: root.fontFamily
              foreground: root.foreground
            }

            // Adding an app to the tracked list, and the master Important
            // toggle, are global settings — moved off this profile-scoped
            // screen entirely so they stop reading as if they only applied
            // here. This just links over to where they actually live.
            Rectangle {
              id: openGlobalAppsFromEditor
              width: Style.space(120)
              height: Style.space(26)
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              radius: Style.spacing.labelGap
              color: openGlobalAppsFromEditorMouse.containsMouse ? Style.hoverFillFor(root.foreground, Color.accent) : "transparent"
              border.width: 1
              border.color: Qt.darker(root.foreground, 2.2)

              Text {
                anchors.centerIn: parent
                textFormat: Text.PlainText
                text: "Add / track app"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              MouseArea {
                id: openGlobalAppsFromEditorMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.openGlobalApps()

                PanelToolTip {
                  visible: openGlobalAppsFromEditorMouse.containsMouse
                  text: "Opens global app settings — the same screen for every profile"
                  fontFamily: root.fontFamily
                }
              }
            }
          }

          Text {
            width: parent.width
            visible: root.seenApps.length > 0
            text: "Every app that has ever sent a notification, plus any you've added in global app settings."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          // Apps that have never sent anything, and haven't been added from
          // the global picker, have no real name to show a rule for yet.
          Text {
            width: parent.width
            visible: root.seenApps.length === 0
            text: "No apps tracked yet. They appear here once they notify you, or once you add one from global app settings."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          Repeater {
            model: root.seenApps

            delegate: Rectangle {
              id: seenAppRow
              required property var modelData
              width: content.width
              height: Style.space(68)
              radius: Style.spacing.labelGap
              color: rowHover.containsMouse ? Style.hoverFillFor(root.foreground, Color.accent) : "transparent"
              // A profile that silences everything has nothing per-app left
              // to decide, so the rows go quiet rather than lying.
              opacity: root.draft && root.draft.dndAll ? 0.4 : 1.0

              HoverHandler { id: rowHover }

              Text {
                id: appNameText
                anchors.left: parent.left
                anchors.top: parent.top
                anchors.topMargin: Style.space(6)
                anchors.leftMargin: Style.space(6)
                anchors.right: appMuteLabel.left
                anchors.rightMargin: Style.space(8)
                text: seenAppRow.modelData
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                elide: Text.ElideRight
              }

              // A bare switch here doesn't say which way is which — "on"
              // could as easily read as "notifications on" as "muted on".
              // The word next to it removes the ambiguity and updates live
              // with the switch. Placed before (left of) the forget-× so the
              // name/label/switch reads as one line and forget stays a
              // clearly separate, secondary action past it.
              Text {
                id: appMuteLabel
                anchors.right: forgetAppBg.left
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: appSwitch.verticalCenter
                textFormat: Text.PlainText
                text: root.draftMuted(seenAppRow.modelData) ? "Muted" : "Allowed"
                color: root.draftMuted(seenAppRow.modelData) ? root.foreground : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              // Untracks the app entirely (also ages out after 30 days on
              // its own) — separate from the mute switch, which only ever
              // acts on an app still being tracked.
              Rectangle {
                id: forgetAppBg
                width: Style.space(22)
                height: Style.space(22)
                radius: width / 2
                anchors.right: appSwitch.left
                anchors.rightMargin: Style.space(8)
                anchors.top: parent.top
                anchors.topMargin: Style.space(1)
                color: forgetAppMouse.containsMouse ? Style.hoverFillFor(root.foreground, Color.accent) : "transparent"

                Text {
                  anchors.centerIn: parent
                  textFormat: Text.PlainText
                  text: "󰅖"
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }

                MouseArea {
                  id: forgetAppMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.forgetSeenApp(seenAppRow.modelData)
                }
              }

              ToggleSwitch {
                id: appSwitch
                anchors.right: parent.right
                anchors.rightMargin: Style.space(6)
                anchors.top: parent.top
                foreground: root.foreground
                enabled: !(root.draft && root.draft.dndAll)
                checked: root.draftMuted(seenAppRow.modelData)
                onToggled: root.setDraftMuted(seenAppRow.modelData, !checked)
              }

              // This profile's override of the global "keep its toast on
              // screen" default (set in global app settings, reached via
              // the gear icon / "Add / track app" above) — Inherit follows
              // that global switch, On/Off pin it just for this profile.
              Column {
                anchors.left: parent.left
                anchors.leftMargin: Style.space(6)
                anchors.right: parent.right
                anchors.rightMargin: Style.space(6)
                anchors.bottom: parent.bottom
                anchors.bottomMargin: Style.space(6)
                spacing: Style.space(4)

                Column {
                  width: parent.width
                  spacing: Style.space(3)

                  // The label alone doesn't fit next to a full-width
                  // tri-state row at this panel width — stacked, like every
                  // other label+control pair in this editor (Silence
                  // everything, Apps you haven't seen before), rather than
                  // squeezed onto one line where the two collided.
                  Text {
                    id: overrideLabel
                    textFormat: Text.PlainText
                    text: "Keep its toast up in this profile"
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                    width: parent.width
                  }

                  Row {
                    width: parent.width
                    height: Style.space(22)
                    spacing: Style.space(4)

                    Repeater {
                      model: [
                        { label: "Inherit", value: null },
                        { label: "On", value: true },
                        { label: "Off", value: false }
                      ]

                      delegate: Rectangle {
                        required property var modelData
                        readonly property bool isSelected: root.draftImportantOverride(seenAppRow.modelData) === modelData.value
                        width: (parent.width - Style.space(8)) / 3
                        height: parent.height
                        radius: Style.spacing.labelGap
                        color: overrideMouse.containsMouse
                          ? Style.hoverFillFor(root.foreground, Color.accent)
                          : (isSelected ? Style.selectedFillFor(root.foreground, Color.accent) : "transparent")
                        border.width: isSelected ? 0 : 1
                        border.color: Qt.darker(root.foreground, 2.2)

                        Text {
                          anchors.centerIn: parent
                          textFormat: Text.PlainText
                          text: modelData.label
                          color: parent.isSelected ? root.foreground : root.dim
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.caption
                        }

                        MouseArea {
                          id: overrideMouse
                          anchors.fill: parent
                          hoverEnabled: true
                          cursorShape: Qt.PointingHandCursor
                          onClicked: root.setDraftImportantOverride(seenAppRow.modelData, modelData.value)

                          PanelToolTip {
                            visible: overrideMouse.containsMouse
                            text: modelData.value === null
                              ? "Follow the global default"
                              : (modelData.value ? "Toast stays up in this profile, even if the global default is off" : "Toast dismisses normally in this profile, even if the global default is on")
                            fontFamily: root.fontFamily
                          }
                        }
                      }
                    }
                  }
                }
              }
            }
          }

          PanelSeparator { width: parent.width }

          // New profile: Cancel / Create. Existing profile: Delete / Cancel
          // / Save — delete stays its own button since it acts immediately
          // (no "cancel" undoes a delete), the other two are the draft's.
          Row {
            width: parent.width
            spacing: Style.space(8)

            // Delete is unavailable for a new (unsaved) draft — nothing to
            // delete yet — and for the protected default profile, which can
            // only be edited. Either way Cancel/Save split the row in two
            // instead of three.
            readonly property bool showDelete: !root.draftIsNew && root.editingName !== root.defaultProfileName
            readonly property real buttonWidth: showDelete
              ? (width - Style.space(16)) / 3
              : (width - Style.space(8)) / 2

            Button {
              width: parent.buttonWidth
              visible: parent.showDelete
              text: "Delete"
              fontFamily: root.fontFamily
              foreground: bar ? bar.urgent : Color.urgent
              enabled: root.profiles.length > 1
              onClicked: root.deleteProfile(root.editingName)
            }

            Button {
              width: parent.buttonWidth
              text: "Cancel"
              fontFamily: root.fontFamily
              foreground: root.foreground
              onClicked: root.closeEditor()
            }

            Button {
              width: parent.buttonWidth
              text: root.draftIsNew ? "Create" : "Save"
              fontFamily: root.fontFamily
              foreground: root.foreground
              onClicked: root.saveDraft()
            }
          }
        }

        // ---------- global app settings: reachable from the gear icon in
        // the switcher, or "Add / track app" in any profile's editor. Only
        // the settings that actually apply everywhere live here — the
        // master Important toggle, the "allow unknown apps" default, and
        // the add-app picker. Mute rules and per-profile overrides stay in
        // the profile editor, since those genuinely differ per profile. ----------

        Column {
          width: parent.width
          spacing: Style.space(10)
          visible: root.view === "globalApps"

          Item {
            width: parent.width
            implicitHeight: Math.max(globalBackButton.height, globalTitle.implicitHeight)

            BarIconButton {
              id: globalBackButton
              bar: root.bar
              width: Style.space(30)
              height: Style.space(30)
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: "󰅁"
              onPressed: function(b) { root.closeGlobalApps() }
            }

            Text {
              id: globalTitle
              anchors.left: globalBackButton.right
              anchors.leftMargin: Style.space(8)
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: "Global app settings"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
            }
          }

          Text {
            width: parent.width
            text: "Whether a first-time sender is allowed through is set per profile, in that profile's own editor — nothing global to set here."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          PanelSeparator { width: parent.width }

          Item {
            width: parent.width
            implicitHeight: Math.max(trackedHeader.implicitHeight, globalAddAppButton.height)

            PanelSectionHeader {
              id: trackedHeader
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: "Tracked apps"
              fontFamily: root.fontFamily
              foreground: root.foreground
            }

            Rectangle {
              id: globalAddAppButton
              width: Style.space(90)
              height: Style.space(26)
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              radius: Style.spacing.labelGap
              color: globalAddAppMouse.containsMouse
                ? Style.hoverFillFor(root.foreground, Color.accent)
                : (root.appPickerOpen ? Style.selectedFillFor(root.foreground, Color.accent) : "transparent")
              border.width: root.appPickerOpen ? 0 : 1
              border.color: Qt.darker(root.foreground, 2.2)

              Text {
                anchors.centerIn: parent
                textFormat: Text.PlainText
                text: "+ Add app"
                color: root.appPickerOpen ? root.foreground : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              MouseArea {
                id: globalAddAppMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  root.appPickerOpen = !root.appPickerOpen
                  if (!root.appPickerOpen) root.appPickerQuery = ""
                }
              }
            }
          }

          // Search installed apps and add one ahead of it ever notifying, so
          // its rules can be set up in advance — see root.addTrackedApp.
          Column {
            width: parent.width
            spacing: Style.space(6)
            visible: root.appPickerOpen

            TextField {
              id: globalAppPickerField
              width: parent.width
              foreground: root.foreground
              placeholderText: "Search installed apps"
              text: root.appPickerQuery
              onTextChanged: root.appPickerQuery = text
              Component.onCompleted: forceActiveFocus()
            }

            Text {
              width: parent.width
              visible: root.appPickerResults.length === 0
              text: root.appPickerQuery.trim()
                ? "No installed app matches, or it's already tracked."
                : "Type to search, or browse installed apps."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            Repeater {
              model: root.appPickerResults

              delegate: Rectangle {
                required property var modelData
                width: parent ? parent.width : 0
                height: Style.space(36)
                radius: Style.spacing.labelGap
                color: globalResultMouse.containsMouse ? Style.hoverFillFor(root.foreground, Color.accent) : "transparent"

                Image {
                  id: globalResultIcon
                  readonly property string src: root.iconSource(modelData.icon)
                  visible: src !== "" && status === Image.Ready
                  source: src
                  width: Style.space(20)
                  height: Style.space(20)
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  fillMode: Image.PreserveAspectFit
                  asynchronous: true
                }

                Text {
                  textFormat: Text.PlainText
                  anchors.left: globalResultIcon.visible ? globalResultIcon.right : parent.left
                  anchors.leftMargin: Style.space(8)
                  anchors.right: parent.right
                  anchors.rightMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  text: modelData.name
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  elide: Text.ElideRight
                }

                MouseArea {
                  id: globalResultMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.addTrackedApp(modelData.name)
                }
              }
            }

            PanelSeparator { width: parent.width }
          }

          Text {
            width: parent.width
            visible: root.seenApps.length > 0
            text: "Every app that has ever sent a notification, plus any you've added above."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          Text {
            width: parent.width
            visible: root.seenApps.length === 0
            text: "No apps tracked yet. They appear here once they notify you, or once you add one above."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          Repeater {
            model: root.seenApps

            delegate: Rectangle {
              id: globalAppRow
              required property var modelData
              width: content.width
              height: Style.space(44)
              radius: Style.spacing.labelGap
              color: globalRowHover.containsMouse ? Style.hoverFillFor(root.foreground, Color.accent) : "transparent"

              HoverHandler { id: globalRowHover }

              Text {
                anchors.left: parent.left
                anchors.leftMargin: Style.space(8)
                anchors.right: globalImportantSwitch.left
                anchors.rightMargin: Style.space(10)
                anchors.verticalCenter: parent.verticalCenter
                text: globalAppRow.modelData
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                elide: Text.ElideRight
              }

              ToggleSwitch {
                id: globalImportantSwitch
                anchors.right: globalForgetBg.left
                anchors.rightMargin: Style.space(10)
                anchors.verticalCenter: parent.verticalCenter
                foreground: root.foreground
                checked: root.isImportantApp(globalAppRow.modelData)
                onToggled: root.setImportantApp(globalAppRow.modelData, !checked)
              }

              Rectangle {
                id: globalForgetBg
                width: Style.space(22)
                height: Style.space(22)
                radius: width / 2
                anchors.right: parent.right
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                color: globalForgetMouse.containsMouse ? Style.hoverFillFor(root.foreground, Color.accent) : "transparent"

                Text {
                  anchors.centerIn: parent
                  textFormat: Text.PlainText
                  text: "󰅖"
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }

                MouseArea {
                  id: globalForgetMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.forgetSeenApp(globalAppRow.modelData)
                }
              }
            }
          }
        }

        // ---------- history: shown together with the profile strip above,
        // not behind a separate tab ----------

        Column {
          width: parent.width
          spacing: Style.space(10)
          visible: root.view === "switcher"

          Item {
            width: parent.width
            implicitHeight: Math.max(historyHeader.implicitHeight, clearButton.height)

            PanelSectionHeader {
              id: historyHeader
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: "Recent notifications"
              fontFamily: root.fontFamily
              foreground: root.foreground
            }

            BarIconButton {
              id: clearButton
              bar: root.bar
              width: Style.space(30)
              height: Style.space(30)
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: "󰃢"
              visible: root.historyRows.length > 0
              onPressed: function(b) { root.run(["clear"]); root.historyRows = [] }
            }
          }

          Text {
            width: parent.width
            visible: root.historyLoading
            text: "Reading the archive…"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Text {
            width: parent.width
            visible: !root.historyLoading && root.historyRows.length === 0
            text: "Nothing recorded yet. Silenced and delivered notifications both end up here."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          Repeater {
            model: root.historyRows

            // A quieter sibling of the live toast card: same background/
            // border tokens and corner radius as NotificationCard.qml, so an
            // entry doesn't change visual language on its way into history.
            delegate: BorderSurface {
              id: historyRow
              required property var modelData
              readonly property string stem: String(modelData.timestamp || 0) + "-" + String(modelData.originalId || 0)
              width: content.width
              implicitHeight: cardBody.implicitHeight + topPadding + bottomPadding
              radius: Style.cornerRadius
              color: Color.notifications.background
              borderSpec: Border.surfaceSpec("notifications", "border", Color.notifications.border, Math.max(1, Style.space(1)))
              padding: Style.space(10)

              Column {
                id: cardBody
                x: parent.leftPadding
                y: parent.topPadding
                width: parent.width - parent.leftPadding - parent.rightPadding
                spacing: Style.space(4)

                Item {
                  width: parent.width
                  implicitHeight: Math.max(appIconBg.height, appText.implicitHeight, removeButtonBg.height)

                  Rectangle {
                    id: appIconBg
                    visible: appIconImage.visible
                    width: Style.space(22)
                    height: Style.space(22)
                    radius: Style.spacing.labelGap
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    color: Style.normalFillFor(root.foreground, Color.accent)

                    Image {
                      id: appIconImage
                      readonly property string src: root.iconSource(historyRow.modelData.appIcon)
                      visible: src !== "" && status === Image.Ready
                      source: src
                      anchors.fill: parent
                      anchors.margins: Style.space(3)
                      fillMode: Image.PreserveAspectFit
                      asynchronous: true
                    }
                  }

                  Text {
                    id: appText
                    textFormat: Text.PlainText
                    anchors.left: appIconImage.visible ? appIconBg.right : parent.left
                    anchors.leftMargin: appIconImage.visible ? Style.space(8) : 0
                    anchors.right: silencedBadge.visible ? silencedBadge.left : timeText.left
                    anchors.rightMargin: Style.space(8)
                    anchors.verticalCenter: parent.verticalCenter
                    text: historyRow.modelData.app || "Unknown"
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    font.bold: true
                    elide: Text.ElideRight
                  }

                  // Marks an entry that never actually showed as a toast —
                  // silenced by a profile's mute list, dndAll, global DND,
                  // or an unmuted first-time sender under a block. Everything
                  // else on this row reached the screen and was dismissed or
                  // expired normally.
                  Text {
                    id: silencedBadge
                    textFormat: Text.PlainText
                    visible: !!historyRow.modelData.silenced
                    anchors.right: timeText.left
                    anchors.rightMargin: Style.space(6)
                    anchors.verticalCenter: parent.verticalCenter
                    text: "󰂛"
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body

                    HoverHandler { id: silencedBadgeHover }
                    PanelToolTip {
                      visible: silencedBadgeHover.hovered
                      text: "Silenced — this notification never showed as a toast"
                      fontFamily: root.fontFamily
                    }
                  }

                  Text {
                    id: timeText
                    textFormat: Text.PlainText
                    anchors.right: removeButtonBg.left
                    anchors.rightMargin: Style.space(6)
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.relativeTime(historyRow.modelData.timestamp)
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }

                  // A real button, not sharing space with the row's click
                  // area below — the two used to overlap as parent/child
                  // MouseAreas, which was unreliable about which one a click
                  // actually landed on. A plain glyph + MouseArea, same
                  // shape as the profile chips above, rather than
                  // BarIconButton — it doesn't expose a hover state to paint
                  // the circle from.
                  Rectangle {
                    id: removeButtonBg
                    width: Style.space(24)
                    height: Style.space(24)
                    radius: width / 2
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    color: removeMouse.containsMouse ? Style.hoverFillFor(root.foreground, Color.accent) : "transparent"

                    Text {
                      textFormat: Text.PlainText
                      anchors.centerIn: parent
                      text: "󰅖"
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                    }

                    MouseArea {
                      id: removeMouse
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: {
                        var stem = historyRow.stem
                        root.run(["removeHistoryEntry", stem])
                        // Filtered by stem, not object identity: a Repeater's
                        // modelData for a plain-array model is a value handed
                        // to the delegate, not a live reference back into
                        // root.historyRows, so `r !== historyRow.modelData`
                        // never matched and the row never actually left.
                        root.historyRows = root.historyRows.filter(function(r) {
                          return (String(r.timestamp || 0) + "-" + String(r.originalId || 0)) !== stem
                        })
                      }
                    }
                  }
                }

                // Archived entries carry no live action to replay (the
                // sender's Notification object is long gone) — focusing the
                // app by name is the same fallback invokePopupDefault uses
                // for chat apps that never registered a "default" action.
                // Its own row below the header, not overlapping the delete
                // button above. Clicking also clears the entry from history,
                // matching how a live toast click dismisses itself — the
                // explicit delete button above stays for clearing without
                // focusing.
                MouseArea {
                  width: parent.width
                  height: bodyColumn.implicitHeight
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: {
                    var stem = historyRow.stem
                    root.run(["focusHistoryApp", historyRow.modelData.app || "", historyRow.modelData.body || ""])
                    root.run(["removeHistoryEntry", stem])
                    root.historyRows = root.historyRows.filter(function(r) {
                      return (String(r.timestamp || 0) + "-" + String(r.originalId || 0)) !== stem
                    })
                    // Clicking is meant to jump to the app, same as a live
                    // toast click — leaving the panel open over top of it
                    // defeats that.
                    root.close()
                  }

                  Column {
                  id: bodyColumn
                  width: parent.width
                  spacing: Style.space(2)

                  Text {
                    width: parent.width
                    visible: (historyRow.modelData.summary || "") !== ""
                    text: historyRow.modelData.summary || ""
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                  }

                  Text {
                    width: parent.width
                    visible: (historyRow.modelData.body || "") !== ""
                    text: historyRow.modelData.body || ""
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                    maximumLineCount: 2
                    wrapMode: Text.WordWrap
                  }
                  }
                }
              }
            }
          }
        }
      }
      }
    }
  }
}
