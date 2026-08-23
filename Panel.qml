import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root

  // A file this plugin reads but does not own can be anything by the time it
  // is opened: a link pointing elsewhere, a pipe that never produces anything,
  // or something far too large. `head` opens a path the ordinary way and would
  // follow the first and wait forever on the second, inside a shell process
  // that stays up for days. So the open refuses on its own terms and hands
  // back nothing at all rather than something over the ceiling. O_NOFOLLOW
  // covers the final name only — a link in a parent directory is still
  // followed, which is the same trust already placed in the home directory.
  readonly property string safeRead: [
    'import os, stat, sys',
    'path = sys.argv[1]; ceiling = int(sys.argv[2])',
    'try:',
    '    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)',
    'except OSError:',
    '    raise SystemExit',
    'raw = b""',
    'try:',
    '    if stat.S_ISREG(os.fstat(fd).st_mode):',
    '        with os.fdopen(fd, "rb") as handle:',
    '            fd = None',
    '            raw = handle.read(ceiling + 1)',
    'except OSError:',
    '    raw = b""',
    'finally:',
    '    if fd is not None:',
    '        os.close(fd)',
    'if raw and len(raw) <= ceiling:',
    '    sys.stdout.buffer.write(raw)'
  ].join("\n")
  moduleName: "io.github.weedwhitesandwine.omazone"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null

  readonly property string homeDir: Quickshell.env("HOME")
  readonly property string pluginDir: homeDir + "/.config/omarchy/plugins/io.github.weedwhitesandwine.omazone"
  readonly property string stateDir: homeDir + "/.local/state/omarchy/omazone"
  readonly property string settingsPath: stateDir + "/settings.json"

  property var zoneIds: []
  property var zoneMeta: ({})
  property bool use24h: true
  property string keybind: "SUPER + I"
  property string barSection: "right"
  property bool settingsLoaded: false

  property bool settingsOpen: false
  property string editingId: ""
  property string editEmoji: ""
  property string editLabel: ""

  property int travelOffsetMinutes: 0
  property var zoneTimes: ({})

  property bool recording: false
  property string pendingCombo: ""
  property string recordError: ""
  property string applyStatus: ""
  property string applyError: ""

  function open() {
    root.travelOffsetMinutes = 0
    root.settingsOpen = false
    root.editingId = ""
    root.controller.show()
    root.refreshTimes()
  }

  function close() {
    root.recording = false
    root.editingId = ""
    root.controller.hide()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.hostWidget || root, direction)
    return false
  }

  SystemClock {
    id: clock
    precision: SystemClock.Minutes
    onDateChanged: root.scheduleRefresh()
  }

  readonly property int nowEpoch: Math.floor(clock.date.getTime() / 1000)
  readonly property int effectiveEpoch: nowEpoch + root.travelOffsetMinutes * 60

  onEffectiveEpochChanged: root.scheduleRefresh()
  onZoneIdsChanged: { root.scheduleRefresh(); root.scheduleSettingsSave() }

  Timer {
    id: refreshDebounce
    interval: 120
    repeat: false
    onTriggered: root.refreshTimes()
  }

  function scheduleRefresh() {
    refreshDebounce.restart()
  }

  Process {
    id: ensureDirsProc
    command: ["mkdir", "-p", root.stateDir]
  }

  // settings.json is written here but it lives on disk, where a restored backup
  // can leave anything at all, and this panel sits in a shell that stays up for
  // days. FileView cannot stop short of the end of a file, so it no longer does
  // the reading — it keeps the writing, with blockAllReads set so it never
  // pulls the file into memory, and `head` does the read with the ceiling in
  // front of it. A larger file arrives cut off, fails to parse, and leaves the
  // defaults in place.
  readonly property int settingsCeiling: 256 * 1024

  FileView {
    id: settingsFile
    path: root.settingsPath
    watchChanges: false
    atomicWrites: true
    blockAllReads: true
    preload: false
    printErrors: false
  }

  function readSettings() { settingsReader.running = false; settingsReader.running = true }

  Process {
    id: settingsReader
    command: ["python3", "-c", root.safeRead,
              root.settingsPath, String(root.settingsCeiling)]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.loadSettings(text)
    }
    // No settings file yet just means first run; the defaults are the truth.
    onExited: if (!root.settingsLoaded) root.loadSettings("")
  }

  Timer {
    id: settingsSaveTimer
    interval: 200
    repeat: false
    onTriggered: root.flushSettings()
  }

  // A hotkey is modifiers then one key. This value is substituted into
  // bindings.lua as Lua source, so anything else is refused rather than
  // escaped — here, and again in set-keybind.sh, since the file can be edited
  // or restored without going near this panel.
  readonly property var keybindPattern:
    /^(SUPER|CTRL|ALT|SHIFT)( \+ (SUPER|CTRL|ALT|SHIFT))* \+ ([A-Z0-9]|F([1-9]|1[0-2])|SPACE|RETURN|ENTER|TAB|ESCAPE|BACKSPACE|DELETE|INSERT|HOME|END|PAGE_UP|PAGE_DOWN|UP|DOWN|LEFT|RIGHT|COMMA|PERIOD|SLASH|MINUS|EQUAL|SEMICOLON|APOSTROPHE|GRAVE|BRACKETLEFT|BRACKETRIGHT|BACKSLASH)$/

  function validKeybind(v) {
    return typeof v === "string" && v.length <= 40 && root.keybindPattern.test(v)
  }

  function loadSettings(json) {
    var parsed = {}
    try { parsed = JSON.parse(json || "{}") } catch (e) { parsed = {} }
    if (Array.isArray(parsed.zoneIds)) root.zoneIds = parsed.zoneIds
    if (parsed.zoneMeta && typeof parsed.zoneMeta === "object") root.zoneMeta = parsed.zoneMeta
    if (typeof parsed.use24h === "boolean") root.use24h = parsed.use24h
    if (root.validKeybind(parsed.keybind)) root.keybind = parsed.keybind
    if (["left", "center", "right"].indexOf(parsed.barSection) >= 0) root.barSection = parsed.barSection
    root.settingsLoaded = true
    root.refreshTimes()
  }

  function scheduleSettingsSave() {
    if (root.settingsLoaded) settingsSaveTimer.restart()
  }

  function flushSettings() {
    settingsFile.setText(JSON.stringify({
      zoneIds: root.zoneIds,
      zoneMeta: root.zoneMeta,
      use24h: root.use24h,
      keybind: root.keybind,
      barSection: root.barSection
    }, null, 2) + "\n")
  }

  onUse24hChanged: scheduleSettingsSave()
  onKeybindChanged: scheduleSettingsSave()
  onZoneMetaChanged: scheduleSettingsSave()
  onBarSectionChanged: scheduleSettingsSave()

  // Move the bar icon to the chosen section through Omarchy's own bar CLI, so
  // the shell owns the edit to its own config. Arguments are passed as a
  // vector, never interpolated. Only ever run in response to the user picking
  // a placement — never on load, so opening the panel does not touch the bar.
  function applyBarSection(sec) {
    if (["left", "center", "right"].indexOf(sec) < 0) return
    root.barSection = sec
    barSectionProc.command = ["omarchy", "bar", "move",
                              "io.github.weedwhitesandwine.omazone", "--section", sec]
    barSectionProc.running = false
    barSectionProc.running = true
  }

  Process {
    id: barSectionProc
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true }
  }

  Component.onCompleted: {
    ensureDirsProc.running = true
    Qt.callLater(function() { root.readSettings() })
  }

  function refreshTimes() {
    var cmd = ["bash", root.pluginDir + "/get-times.sh", String(root.effectiveEpoch)].concat(root.zoneIds)
    timesProc.command = cmd
    timesProc.running = false
    timesProc.running = true
  }

  Process {
    id: timesProc
    stdout: StdioCollector {
      id: timesStdout
      waitForEnd: true
      onStreamFinished: root.zoneTimes = Model.parseTimesOutput(timesStdout.text)
    }
  }

  function zoneIcon(id) {
    var meta = root.zoneMeta[id]
    return (meta && meta.emoji) ? meta.emoji : Model.cityIcon(id)
  }

  function zoneLabel(id) {
    var meta = root.zoneMeta[id]
    return (meta && meta.label) ? meta.label : Model.friendlyName(id)
  }

  function zoneTimeText(id) {
    var e = root.zoneTimes[id]
    if (!e || e.time24 === undefined) return "--:--"
    return root.use24h ? e.time24 : (e.time12 + " " + e.ampm)
  }

  function zoneBadge(id) {
    var e = root.zoneTimes[id]
    var l = root.zoneTimes["__local__"]
    if (!e || !l) return ""
    return Model.dayBadge(e.date, l.date)
  }

  function zoneSubText(id) {
    var e = root.zoneTimes[id]
    if (!e || e.abbr === undefined) return ""
    return e.abbr + " · " + e.weekday
  }

  function beginEdit(id) {
    root.editingId = id
    root.editEmoji = root.zoneIcon(id)
    root.editLabel = root.zoneLabel(id)
  }

  function cancelEdit() {
    root.editingId = ""
  }

  function saveEdit() {
    if (root.editingId === "") return
    var meta = {}
    for (var key in root.zoneMeta) meta[key] = root.zoneMeta[key]
    meta[root.editingId] = { emoji: root.editEmoji.trim(), label: root.editLabel.trim() }
    root.zoneMeta = meta
    root.editingId = ""
  }

  function removeZone(id) {
    root.zoneIds = root.zoneIds.filter(function(z) { return z !== id })
    var meta = {}
    for (var key in root.zoneMeta) if (key !== id) meta[key] = root.zoneMeta[key]
    root.zoneMeta = meta
    if (root.editingId === id) root.editingId = ""
  }

  function moveZone(id, delta) {
    var ids = root.zoneIds.slice()
    var i = ids.indexOf(id)
    if (i === -1) return
    var j = i + delta
    if (j < 0 || j >= ids.length) return
    var tmp = ids[i]
    ids[i] = ids[j]
    ids[j] = tmp
    root.zoneIds = ids
  }

  function isBareModifier(key) {
    return key === Qt.Key_Super_L || key === Qt.Key_Super_R || key === Qt.Key_Meta
      || key === Qt.Key_Control || key === Qt.Key_Shift || key === Qt.Key_Alt || key === Qt.Key_AltGr
  }

  function hyprKeyName(key) {
    if (key >= Qt.Key_A && key <= Qt.Key_Z) return String.fromCharCode(key)
    if (key >= Qt.Key_0 && key <= Qt.Key_9) return String.fromCharCode(key)
    if (key >= Qt.Key_F1 && key <= Qt.Key_F12) return "F" + (key - Qt.Key_F1 + 1)
    var names = {}
    names[Qt.Key_Space] = "SPACE"
    names[Qt.Key_Return] = "RETURN"
    names[Qt.Key_Enter] = "RETURN"
    names[Qt.Key_Escape] = "ESCAPE"
    names[Qt.Key_Tab] = "TAB"
    names[Qt.Key_Backspace] = "BACKSPACE"
    names[Qt.Key_Delete] = "Delete"
    names[Qt.Key_Home] = "Home"
    names[Qt.Key_End] = "End"
    names[Qt.Key_PageUp] = "PageUp"
    names[Qt.Key_PageDown] = "PageDown"
    names[Qt.Key_Left] = "left"
    names[Qt.Key_Right] = "right"
    names[Qt.Key_Up] = "up"
    names[Qt.Key_Down] = "down"
    names[Qt.Key_Comma] = "comma"
    names[Qt.Key_Period] = "period"
    names[Qt.Key_Minus] = "minus"
    names[Qt.Key_Equal] = "equal"
    names[Qt.Key_Slash] = "slash"
    names[Qt.Key_Backslash] = "backslash"
    names[Qt.Key_Semicolon] = "semicolon"
    names[Qt.Key_Apostrophe] = "apostrophe"
    names[Qt.Key_BracketLeft] = "bracketleft"
    names[Qt.Key_BracketRight] = "bracketright"
    names[Qt.Key_QuoteLeft] = "grave"
    return names[key] || ""
  }

  function beginRecording() {
    root.recording = true
    root.recordError = ""
    root.pendingCombo = ""
    root.applyStatus = ""
    Qt.callLater(function() { recorder.forceActiveFocus() })
  }

  function cancelRecording() {
    root.recording = false
    root.recordError = ""
    root.pendingCombo = ""
  }

  function handleRecordKey(event) {
    if (event.key === Qt.Key_Escape && event.modifiers === Qt.NoModifier) {
      root.cancelRecording()
      event.accepted = true
      return
    }
    if (root.isBareModifier(event.key)) {
      event.accepted = true
      return
    }

    var mods = []
    if (event.modifiers & Qt.MetaModifier) mods.push("SUPER")
    if (event.modifiers & Qt.ControlModifier) mods.push("CTRL")
    if (event.modifiers & Qt.AltModifier) mods.push("ALT")
    if (event.modifiers & Qt.ShiftModifier) mods.push("SHIFT")

    var keyStr = root.hyprKeyName(event.key)
    if (keyStr === "") {
      root.recordError = "Unsupported key — try a letter, digit, F-key, arrow, or punctuation key."
      event.accepted = true
      return
    }
    if (mods.length === 0) {
      root.recordError = "Add a modifier (Super/Ctrl/Alt/Shift) — a bare key would break typing everywhere."
      event.accepted = true
      return
    }
    if (mods.length > 1) {
      root.recordError = "Use exactly one modifier — combos with two or more fail to apply on this system."
      event.accepted = true
      return
    }

    root.recordError = ""
    root.pendingCombo = mods.join(" ") + " + " + keyStr
    event.accepted = true
  }

  function confirmRecording() {
    if (root.pendingCombo === "") return
    root.applyStatus = "applying"
    root.applyError = ""
    keybindProc.command = ["bash", root.pluginDir + "/set-keybind.sh", root.pendingCombo]
    keybindProc.running = true
  }

  Process {
    id: keybindProc
    stdout: StdioCollector { id: keybindStdout; waitForEnd: true }
    stderr: StdioCollector { id: keybindStderr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode === 0) {
        root.keybind = root.pendingCombo
        root.applyStatus = ""
        root.recording = false
        root.pendingCombo = ""
      } else {
        root.applyStatus = "error"
        root.applyError = (keybindStderr.text || "").trim() || "Failed to apply keybind"
      }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.hostWidget || root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(Style.space(460))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.recording || root.editingId !== ""
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Item {
        anchors.fill: parent

        Row {
          id: headerRow
          width: parent.width
          height: Math.max(titleText.implicitHeight, gearBtn.implicitHeight)

          Text {
            textFormat: Text.PlainText
            id: titleText
            anchors.verticalCenter: parent.verticalCenter
            text: "Omazone"
            color: root.barForeground
            font.bold: true
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.subtitle
          }

          Item {
            width: headerRow.width - titleText.width - gearBtn.width
            height: 1
          }

          PanelActionButton {
            id: gearBtn
            anchors.verticalCenter: parent.verticalCenter
            iconText: root.settingsOpen ? "✕" : "󰒓"
            tooltipText: root.settingsOpen ? "Back to cities" : "Settings"
            foreground: root.barForeground
            onClicked: root.settingsOpen = !root.settingsOpen
          }
        }

        Flickable {
          id: bodyFlick
          anchors.top: headerRow.bottom
          anchors.topMargin: Style.space(8)
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          clip: true
          contentWidth: width
          contentHeight: root.settingsOpen ? settingsColumn.implicitHeight : mainColumn.implicitHeight
          boundsBehavior: Flickable.StopAtBounds
          interactive: contentHeight > height

          Column {
            id: mainColumn
            visible: !root.settingsOpen
            width: bodyFlick.width
            spacing: Style.space(10)

            PanelSectionHeader { text: "TIME TRAVEL"; foreground: root.barForeground }

            Row {
              width: parent.width
              height: Math.max(travelLabel.implicitHeight, nowBtn.implicitHeight)

              Text {
                textFormat: Text.PlainText
                id: travelLabel
                anchors.verticalCenter: parent.verticalCenter
                text: Model.formatOffset(root.travelOffsetMinutes)
                color: root.barForeground
                font.bold: true
                font.pixelSize: Style.font.body
              }

              Item {
                width: parent.width - travelLabel.width - nowBtn.width
                height: 1
              }

              PanelActionButton {
                id: nowBtn
                anchors.verticalCenter: parent.verticalCenter
                iconText: "⟲"
                tooltipText: "Reset to now"
                foreground: root.barForeground
                enabled: root.travelOffsetMinutes !== 0
                onClicked: root.travelOffsetMinutes = 0
              }
            }

            PanelSlider {
              width: parent.width
              bar: root.bar
              minimum: -1440
              maximum: 2880
              step: 15
              integer: true
              value: root.travelOffsetMinutes
              onMoved: function(v) { root.travelOffsetMinutes = v }
              onReleased: function(v) { root.travelOffsetMinutes = v; root.refreshTimes() }
            }

            Text {
              textFormat: Text.PlainText
              visible: root.travelOffsetMinutes !== 0
              width: parent.width
              text: {
                var l = root.zoneTimes["__local__"]
                if (!l || l.date === undefined) return ""
                return l.weekday + " " + l.date + " · " + (root.use24h ? l.time24 : (l.time12 + " " + l.ampm)) + " your local time"
              }
              color: Qt.darker(root.barForeground, 1.4)
              font.pixelSize: Style.font.caption
              wrapMode: Text.Wrap
            }

            PanelSeparator { foreground: root.barForeground }

            Text {
              textFormat: Text.PlainText
              visible: root.zoneIds.length === 0
              width: parent.width
              text: "No cities yet — add some from Settings (" + "⚙" + ")."
              color: Qt.darker(root.barForeground, 1.5)
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.Wrap
            }

            Repeater {
              model: root.zoneIds

              delegate: Item {
                id: rowItem
                required property string modelData
                readonly property bool editing: root.editingId === modelData
                width: mainColumn.width
                height: editing ? Style.space(40) : Style.space(46)

                Row {
                  id: editRow
                  visible: rowItem.editing
                  width: parent.width
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.spacing.xs

                  TextField {
                    id: emojiField
                    width: Style.space(46)
                    text: root.editEmoji
                    foreground: root.barForeground
                    horizontalAlignment: Text.AlignHCenter
                    onTextChanged: root.editEmoji = text
                  }

                  TextField {
                    id: labelField
                    width: editRow.width - emojiField.width - saveBtn.width - cancelBtn.width - editRow.spacing * 3
                    text: root.editLabel
                    foreground: root.barForeground
                    placeholderText: Model.friendlyName(rowItem.modelData)
                    onTextChanged: root.editLabel = text
                  }

                  PanelActionButton {
                    id: saveBtn
                    iconText: "✓"
                    tooltipText: "Save"
                    foreground: root.barForeground
                    onClicked: root.saveEdit()
                  }

                  PanelActionButton {
                    id: cancelBtn
                    iconText: "✕"
                    tooltipText: "Cancel"
                    foreground: root.barForeground
                    onClicked: root.cancelEdit()
                  }
                }

                Row {
                  id: normalRow
                  visible: !rowItem.editing
                  width: parent.width
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.spacing.sm

                  Row {
                    id: leftBlock
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.spacing.sm

                    Text {
                      textFormat: Text.PlainText
                      text: root.zoneIcon(rowItem.modelData)
                      font.pixelSize: Style.font.subtitle
                    }

                    Column {
                      anchors.verticalCenter: parent.verticalCenter
                      spacing: 2

                      Text {
                        textFormat: Text.PlainText
                        text: root.zoneLabel(rowItem.modelData)
                        color: root.barForeground
                        font.bold: true
                        font.pixelSize: Style.font.body
                      }
                      Text {
                        textFormat: Text.PlainText
                        text: Model.regionName(rowItem.modelData)
                        color: Qt.darker(root.barForeground, 1.5)
                        font.pixelSize: Style.font.caption
                      }
                    }
                  }

                  Item {
                    id: spacerItem
                    width: Math.max(0, normalRow.width - leftBlock.width - timeBlock.width - actionsBlock.width - normalRow.spacing * 3)
                    height: 1
                  }

                  Column {
                    id: timeBlock
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 2

                    Row {
                      anchors.right: parent.right
                      spacing: Style.spacing.xs

                      Text {
                        textFormat: Text.PlainText
                        text: root.zoneTimeText(rowItem.modelData)
                        color: root.barForeground
                        font.bold: true
                        font.pixelSize: Style.font.subtitle
                      }
                      Text {
                        textFormat: Text.PlainText
                        visible: text !== ""
                        text: root.zoneBadge(rowItem.modelData)
                        color: Color.accent
                        font.bold: true
                        font.pixelSize: Style.font.caption
                      }
                    }

                    Text {
                      textFormat: Text.PlainText
                      anchors.right: parent.right
                      text: root.zoneSubText(rowItem.modelData)
                      color: Qt.darker(root.barForeground, 1.5)
                      font.pixelSize: Style.font.caption
                    }
                  }

                  Row {
                    id: actionsBlock
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 0

                    PanelActionButton {
                      iconText: "↑"
                      tooltipText: "Move up"
                      foreground: root.barForeground
                      onClicked: root.moveZone(rowItem.modelData, -1)
                    }
                    PanelActionButton {
                      iconText: "↓"
                      tooltipText: "Move down"
                      foreground: root.barForeground
                      onClicked: root.moveZone(rowItem.modelData, 1)
                    }
                    PanelActionButton {
                      iconText: "✎"
                      tooltipText: "Edit icon & label"
                      foreground: root.barForeground
                      onClicked: root.beginEdit(rowItem.modelData)
                    }
                    PanelActionButton {
                      iconText: "✕"
                      tooltipText: "Remove"
                      foreground: root.barForeground
                      hoverColor: Color.urgent
                      onClicked: root.removeZone(rowItem.modelData)
                    }
                  }
                }
              }
            }
          }

          Column {
            id: settingsColumn
            visible: root.settingsOpen
            width: bodyFlick.width
            spacing: Style.space(14)

            PanelSectionHeader { text: "CITIES"; foreground: root.barForeground }

            MultiSelect {
              width: parent.width
              label: "Track these cities"
              values: root.zoneIds
              optionsCommand: ["bash", root.pluginDir + "/list-zones.sh"]
              placeholderText: "Search timezones…"
              emptyText: "No matches"
              noSelectionText: "None selected"
              foreground: root.barForeground
              accent: Color.accent
              fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
              onChanged: function(values) { root.zoneIds = values }
            }

            PanelSeparator { foreground: root.barForeground }

            PanelSectionHeader { text: "FORMAT"; foreground: root.barForeground }

            Toggle {
              width: parent.width
              label: "24-hour time"
              description: root.use24h ? "14:30" : "2:30 PM"
              checked: root.use24h
              foreground: root.barForeground
              onClicked: root.use24h = !root.use24h
            }

            PanelSeparator { foreground: root.barForeground }

            PanelSectionHeader { text: "BAR"; foreground: root.barForeground }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: "Which side of the bar the Omazone icon sits on."
              color: Qt.darker(root.barForeground, 1.5)
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.Wrap
            }

            Row {
              width: parent.width
              spacing: Style.spacing.xs
              readonly property real btnW: (width - Style.spacing.xs * 2) / 3

              Button {
                width: parent.btnW
                text: "Left"
                bordered: root.barSection === "left"
                foreground: root.barForeground
                fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
                onClicked: root.applyBarSection("left")
              }
              Button {
                width: parent.btnW
                text: "Center"
                bordered: root.barSection === "center"
                foreground: root.barForeground
                fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
                onClicked: root.applyBarSection("center")
              }
              Button {
                width: parent.btnW
                text: "Right"
                bordered: root.barSection === "right"
                foreground: root.barForeground
                fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
                onClicked: root.applyBarSection("right")
              }
            }

            PanelSeparator { foreground: root.barForeground }

            PanelSectionHeader { text: "KEYBIND"; foreground: root.barForeground }

            Button {
              text: root.recording ? (root.pendingCombo !== "" ? root.pendingCombo : "Press keys…") : root.keybind
              bordered: true
              foreground: root.barForeground
              fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
              onClicked: root.recording ? root.cancelRecording() : root.beginRecording()
            }

            Item {
              id: recorder
              width: 1
              height: 1
              focus: root.recording
              Keys.onPressed: function(event) { root.handleRecordKey(event) }
            }

            Text {
              textFormat: Text.PlainText
              visible: root.recording
              text: "Press a shortcut with one modifier (e.g. Super+T). Esc to cancel."
              color: Qt.darker(root.barForeground, 1.4)
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.Wrap
              width: parent.width
            }

            Text {
              textFormat: Text.PlainText
              visible: root.recordError !== ""
              text: root.recordError
              color: Color.urgent
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.Wrap
              width: parent.width
            }

            Row {
              visible: root.recording && root.pendingCombo !== ""
              spacing: Style.spacing.sm

              Button {
                text: "Apply"
                bordered: true
                foreground: root.barForeground
                onClicked: root.confirmRecording()
              }
              Button {
                text: "Cancel"
                bordered: true
                foreground: root.barForeground
                onClicked: root.cancelRecording()
              }
            }

            Text {
              textFormat: Text.PlainText
              visible: root.applyStatus === "applying"
              text: "Applying…"
              color: Qt.darker(root.barForeground, 1.4)
              font.pixelSize: Style.font.bodySmall
            }
            Text {
              textFormat: Text.PlainText
              visible: root.applyStatus === "error"
              text: "Failed: " + root.applyError
              color: Color.urgent
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.Wrap
              width: parent.width
            }
          }
        }
      }
    }
  }
}
