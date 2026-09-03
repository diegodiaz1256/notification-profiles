// Notification profiles: a bar chip showing the active profile, a popup to
// switch between them, and an editor for the rules each one carries.
//
// The daemon (zeroge.notifications) owns the profile state. This panel never
// writes the settings file itself — it reads over IPC and hands whole profile
// lists back, so a notification arriving mid-edit cannot interleave with a
// half-written rule set.

import QtQuick
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

  // Which profile the editor is showing. Empty means the switcher list.
  property string editingName: ""
  // "switcher" | "editor" | "history" — the editor also needs editingName set.
  property string view: "switcher"
  property var historyRows: []
  property bool historyLoading: false

  readonly property var editing: findProfile(editingName)
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
    run(["saveProfiles", JSON.stringify(list)])
  }

  // Rebuilds the list with one profile replaced. The editor edits a copy and
  // sends the whole thing, which is also what keeps rename safe: the daemon
  // re-points activeProfile itself when the name it held disappears.
  function replaceProfile(name, changes) {
    var next = []
    for (var i = 0; i < profiles.length; i++) {
      var p = profiles[i]
      if (p.name !== name) { next.push(p); continue }
      next.push({
        name: changes.name !== undefined ? changes.name : p.name,
        icon: changes.icon !== undefined ? changes.icon : p.icon,
        muteApps: changes.muteApps !== undefined ? changes.muteApps : p.muteApps,
        dndAll: changes.dndAll !== undefined ? changes.dndAll : p.dndAll
      })
    }
    saveProfiles(next)
    if (changes.name !== undefined) root.editingName = changes.name
  }

  function addProfile() {
    // Names are the identity the daemon matches on, so a new one has to be
    // unique before it is sent.
    var base = "New profile"
    var name = base
    var n = 2
    while (findProfile(name)) { name = base + " " + n; n++ }
    saveProfiles(profiles.concat([{ name: name, icon: "󰂚", muteApps: [], dndAll: false }]))
    root.editingName = name
    root.view = "editor"
  }

  function deleteProfile(name) {
    var next = profiles.filter(function(p) { return p.name !== name })
    // The daemon falls back to the first profile when the list empties, but a
    // list with nothing in it silences the switcher entirely — keep one.
    if (!next.length) return
    saveProfiles(next)
    root.editingName = ""
    root.view = "switcher"
  }

  function toggleMute(profileName, app, muted) {
    run([muted ? "muteApp" : "unmuteApp", profileName, app])
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
      root.editingName = ""
      root.view = "switcher"
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
      root.editingName = root.activeName
      root.view = "editor"
      if (!root.opened) root.open()
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
    contentHeight: panel.fittedContentHeight(content.implicitHeight)

    PanelKeyCatcher {
      id: keys
      anchors.fill: parent
      onCloseRequested: {
        // Escape backs out of the editor first, then closes the panel.
        if (root.view !== "switcher") { root.editingName = ""; root.view = "switcher" }
        else root.close()
      }
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: content
        anchors.fill: parent
        spacing: Style.space(12)

        // ---------- profile strip: always visible above history, one row of
        // small chips rather than a full-width list, so the history below is
        // still the majority of the panel ----------

        Column {
          width: parent.width
          spacing: Style.space(6)
          visible: root.view !== "editor"

          PanelSectionHeader {
            width: parent.width
            text: "Notification profile"
            fontFamily: root.fontFamily
            foreground: root.foreground
          }

          Flow {
            width: parent.width
            spacing: Style.space(6)

            Repeater {
              model: root.profiles

              delegate: Rectangle {
                required property var modelData
                readonly property bool isActive: modelData.name === root.activeName

                implicitWidth: chipRow.implicitWidth + Style.space(16)
                implicitHeight: Style.space(30)
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
                  onClicked: root.switchTo(modelData.name)
                }

                Row {
                  id: chipRow
                  anchors.centerIn: parent
                  spacing: Style.space(6)

                  Text {
                    textFormat: Text.PlainText
                    anchors.verticalCenter: parent.verticalCenter
                    text: (modelData.icon || "󰂚") + "  " + modelData.name
                    color: parent.parent.isActive ? root.foreground : root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: parent.parent.isActive
                  }

                  // A second, smaller click target inside the chip: editing a
                  // profile is rarer than switching to it, so it doesn't need
                  // equal weight, just its own hit area.
                  Text {
                    textFormat: Text.PlainText
                    anchors.verticalCenter: parent.verticalCenter
                    text: "󰏫"
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption

                    MouseArea {
                      anchors.fill: parent
                      anchors.margins: -Style.space(4)
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: function(mouse) {
                        mouse.accepted = true
                        root.editingName = modelData.name
                        root.view = "editor"
                      }
                    }
                  }
                }
              }
            }

            // "+" chip matches the profile chips' shape so it reads as one
            // more item in the same row rather than a separate control.
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

          PanelSeparator { width: parent.width }
        }

        // ---------- editor ----------

        Column {
          width: parent.width
          spacing: Style.space(10)
          visible: root.view === "editor" && root.editing !== null

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
              onPressed: function(b) { root.editingName = ""; root.view = "switcher" }
            }

            Text {
              id: editTitle
              anchors.left: backButton.right
              anchors.leftMargin: Style.space(8)
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: root.editing ? root.editing.name : ""
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
            }
          }

          TextField {
            id: nameField
            width: parent.width
            foreground: root.foreground
            placeholderText: "Profile name"
            // Rebinding on every keystroke would fight the cursor; the text is
            // seeded when the editor opens instead.
            text: root.editing ? root.editing.name : ""
            onAccepted: {
              var wanted = String(text || "").trim()
              if (wanted && wanted !== root.editingName && !root.findProfile(wanted)) {
                root.replaceProfile(root.editingName, { name: wanted })
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
              checked: root.editing ? !!root.editing.dndAll : false
              onToggled: root.replaceProfile(root.editingName, { dndAll: !root.editing.dndAll })
            }
          }

          PanelSeparator { width: parent.width }

          PanelSectionHeader {
            width: parent.width
            text: "Mute these apps"
            fontFamily: root.fontFamily
            foreground: root.foreground
          }

          // Apps that have never sent anything cannot be listed, and typing a
          // name from memory rarely matches what the sender actually set.
          Text {
            width: parent.width
            visible: root.seenApps.length === 0
            text: "No apps have sent a notification yet. They appear here once they do."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          Repeater {
            model: root.seenApps

            delegate: Item {
              required property var modelData
              width: content.width
              height: Style.space(34)
              // A profile that silences everything has nothing per-app left
              // to decide, so the rows go quiet rather than lying.
              opacity: root.editing && root.editing.dndAll ? 0.4 : 1.0

              Text {
                anchors.left: parent.left
                anchors.right: appSwitch.left
                anchors.rightMargin: Style.space(10)
                anchors.verticalCenter: parent.verticalCenter
                text: modelData
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                elide: Text.ElideRight
              }

              ToggleSwitch {
                id: appSwitch
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                foreground: root.foreground
                enabled: !(root.editing && root.editing.dndAll)
                checked: root.isMuted(root.editing, modelData)
                onToggled: root.toggleMute(root.editingName, modelData, !checked)
              }
            }
          }

          PanelSeparator { width: parent.width }

          Button {
            width: parent.width
            visible: root.profiles.length > 1
            text: "Delete this profile"
            fontFamily: root.fontFamily
            foreground: bar ? bar.urgent : Color.urgent
            onClicked: root.deleteProfile(root.editingName)
          }
        }

        // ---------- history: shown together with the profile strip above,
        // not behind a separate tab ----------

        Column {
          width: parent.width
          spacing: Style.space(8)
          visible: root.view !== "editor"

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

            delegate: Column {
              required property var modelData
              width: content.width
              spacing: Style.space(2)

              Item {
                width: parent.width
                implicitHeight: Math.max(appText.implicitHeight, timeText.implicitHeight)

                Text {
                  id: appText
                  textFormat: Text.PlainText
                  anchors.left: parent.left
                  anchors.right: timeText.left
                  anchors.rightMargin: Style.space(8)
                  text: modelData.app || "Unknown"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: true
                  elide: Text.ElideRight
                }

                Text {
                  id: timeText
                  textFormat: Text.PlainText
                  anchors.right: parent.right
                  text: root.relativeTime(modelData.timestamp)
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }

              Text {
                width: parent.width
                visible: (modelData.summary || "") !== ""
                text: modelData.summary || ""
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
              }

              Text {
                width: parent.width
                visible: (modelData.body || "") !== ""
                text: modelData.body || ""
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
                maximumLineCount: 2
                wrapMode: Text.WordWrap
              }

              PanelSeparator { width: parent.width }
            }
          }
        }
      }
    }
  }
}
