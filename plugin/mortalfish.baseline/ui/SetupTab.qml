import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Setup: the slower-moving things. Baseline's health (check & repair), battery
// care, the mouse and the dictation indicator.
Column {
  id: root
  property var host: null
  readonly property color amber: Commons.Color.accent
  readonly property color teal: host ? host.themeCyan : Commons.Color.foreground
  spacing: Style.space(12)

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("../i18n") }

  function n(v, d) { return Commons.I18n.formatNumber(v, d || 0) }
  function pct(v) { return strings.t("percent").arg(n(Math.round(v))) }
  // Health: every part Baseline puts into the system (links, hooks, bar,
  // services, the look reaching other apps), checked when the tab opens.
  // Repair puts back whatever an Omarchy update or refresh knocked out; it
  // also runs on its own after every update.
  Column {
    id: health
    width: parent.width
    spacing: Style.space(8)
    property var info: null
    property string result: ""
    readonly property string tool: root.host ? root.host.afterlightPath : ""
    readonly property int failing: info ? info.failing : 0
    readonly property var groups: ["links", "desktop", "bar", "services", "look", "system"]
    readonly property bool barOff: !!info && info.checks.some(c => c.id === "bar" && !c.ok)
    readonly property bool busy: healthRunner.running
    function read() { if (!healthRunner.running) { healthRunner.command = [tool, "check", "--json"]; healthRunner.running = true } }
    function act(args) {
      result = ""
      healthRunner.command = [tool].concat(args).concat(["--json"])
      healthRunner.running = true
    }
    Process {
      id: healthRunner
      stdout: StdioCollector {
        onStreamFinished: {
          try {
            const r = JSON.parse(text)
            health.info = r
            if (r.fixed && r.fixed.length) health.result = strings.t("health.fixed").arg(r.fixed.join(", "))
            else if (r.errors && r.errors.length) health.result = r.errors.join("\n")
          } catch (error) {}
        }
      }
    }
    Process { id: healthSystem; command: [health.tool, "repair", "--system"] }
    Process { id: healthKeep; command: [health.tool, "repair", "--keep-bar"]; onExited: health.read() }
    Component.onCompleted: read()

    Section { width: parent.width; title: strings.t("health.title"); amber: root.amber; teal: root.teal }

    // The verdict: one plate, teal when all is in place, accent when not.
    Rectangle {
      id: plate
      width: parent.width
      height: verdict.implicitHeight + Style.space(20)
      radius: Style.cornerRadius > 0 ? Style.space(6) : 0
      readonly property color tone: health.failing > 0 ? root.amber : root.teal
      color: Qt.rgba(tone.r, tone.g, tone.b, 0.07)
      border.width: 1
      border.color: Qt.rgba(tone.r, tone.g, tone.b, 0.35)
      RowLayout {
        id: verdict
        anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; margins: Style.space(12) }
        spacing: Style.space(12)
        Label {
          text: health.busy ? "󰔟" : health.failing > 0 ? "◆" : "◇"
          font.family: "Iosevka Nerd Font Propo"
          font.pixelSize: Style.font.iconLarge
          color: plate.tone
          RotationAnimation on rotation { running: health.busy && !Style.reduceMotion; loops: Animation.Infinite; from: 0; to: 360; duration: 1200 }
          onTextChanged: if (!health.busy) rotation = 0
        }
        Column {
          Layout.fillWidth: true
          spacing: Style.space(2)
          Label {
            width: parent.width
            textFormat: Text.PlainText
            font.bold: true
            font.letterSpacing: Style.space(1)
            color: plate.tone
            text: !health.info ? strings.t("health.checking")
              : health.failing > 0 ? strings.tn("health.failing", health.failing).arg(root.n(health.failing))
              : strings.t("health.allGood").arg(root.n(health.info.checks.length))
          }
          Label {
            width: parent.width
            textFormat: Text.PlainText
            font.pixelSize: Style.font.caption
            opacity: 0.6
            text: health.info ? strings.t("health.checked").arg(health.info.checked.slice(11, 16)) : ""
          }
        }
      }
    }

    // One line per part of the system: its name, a count, and what's wrong.
    Column {
      width: parent.width
      spacing: Style.space(4)
      Repeater {
        model: health.info ? health.groups : []
        delegate: Column {
          id: groupRow
          required property string modelData
          readonly property var rows: health.info.checks.filter(c => c.group === modelData)
          readonly property var bad: rows.filter(c => !c.ok)
          width: parent.width
          spacing: Style.space(2)
          visible: rows.length > 0
          RowLayout {
            width: parent.width
            spacing: Style.space(8)
            Rectangle {
              implicitWidth: Style.space(6); implicitHeight: Style.space(6); radius: Style.space(3)
              color: groupRow.bad.length ? root.amber : root.teal
              opacity: groupRow.bad.length ? 1 : 0.7
            }
            Label {
              Layout.fillWidth: true
              text: strings.t("health.group." + groupRow.modelData)
              font.pixelSize: Style.font.caption
              font.letterSpacing: Style.space(1)
              color: groupRow.bad.length ? root.amber : Commons.Color.popups.text
              opacity: groupRow.bad.length ? 1 : 0.8
            }
            Label {
              text: (groupRow.rows.length - groupRow.bad.length) + " / " + groupRow.rows.length
              font.pixelSize: Style.font.caption
              font.family: Style.font.family
              opacity: 0.5
            }
          }
          Repeater {
            model: groupRow.bad
            delegate: Label {
              required property var modelData
              x: Style.space(14)
              width: groupRow.width - x
              wrapMode: Text.WordWrap
              elide: Text.ElideNone
              textFormat: Text.PlainText
              font.pixelSize: Style.font.caption
              color: root.amber
              opacity: 0.85
              text: modelData.label + (modelData.fix === "sudo" ? "  · " + strings.t("health.needsPassword") : "")
            }
          }
        }
      }
    }

    Flow {
      width: parent.width
      spacing: Style.space(8)
      ActionButton {
        icon: "󰦛"
        text: strings.t("health.repair")
        tone: health.failing > 0 ? root.amber : root.teal
        enabled: !health.busy
        onClicked: health.act(["repair"])
      }
      ActionButton {
        icon: "󰑓"
        text: strings.t("health.check")
        tone: root.teal
        enabled: !health.busy
        onClicked: { health.result = ""; health.read() }
      }
      ActionButton {
        visible: health.barOff
        icon: "󰕮"
        text: strings.t("health.keepBar")
        tone: root.teal
        onClicked: healthKeep.running = true
      }
      ActionButton {
        visible: !!health.info && health.info.sudo
        icon: "󰌾"
        text: strings.t("health.system")
        tone: root.amber
        onClicked: healthSystem.running = true
      }
    }
    Label {
      width: parent.width
      visible: health.result !== ""
      wrapMode: Text.WordWrap
      elide: Text.ElideNone
      textFormat: Text.PlainText
      font.pixelSize: Style.font.caption
      color: root.teal
      text: health.result
    }
    Label {
      width: parent.width
      wrapMode: Text.WordWrap
      elide: Text.ElideNone
      font.pixelSize: Style.font.caption
      opacity: 0.5
      text: strings.t("health.hint")
    }
  }

  // Battery care: the firmware's charge limit, and how worn the cell is.
  Column {
    id: care
    width: parent.width
    spacing: Style.space(6)
    property var b: null
    readonly property string tool: root.host ? root.host.afterlightPath : ""
    function read() { if (!careReader.running) careReader.running = true }
    Process {
      id: careReader
      command: [care.tool, "battery", "status"]
      stdout: StdioCollector { onStreamFinished: { try { care.b = JSON.parse(text) } catch (error) {} } }
    }
    Process { id: careSetter; onExited: care.read() }
    Component.onCompleted: read()

    Section { width: parent.width; title: strings.t("battery.care"); amber: root.amber; teal: root.teal }
    OptionTile {
      width: parent.width
      visible: !!care.b && care.b.canLimit
      icon: "󱈏"
      title: strings.t("battery.limit").arg(care.b ? care.b.limitPercent : 80)
      detail: (care.b && care.b.health !== null ? strings.t("battery.health").arg(care.b.health) + " · " : "")
        + strings.t(care.b && care.b.limit ? "battery.limitOn" : "battery.limitOff")
      checked: !!care.b && care.b.limit
      amber: root.amber; teal: root.teal
      onToggled: {
        careSetter.command = [care.tool, "battery", "limit", checked ? "off" : "on"]
        careSetter.running = true
      }
    }
  }

  // Apps: which coding and chat apps own workspaces 3 and 4 and start there
  // at login (`afterlight apps`). Click to step forward, right-click back.
  Column {
    id: appsBox
    width: parent.width
    spacing: Style.space(6)
    property var info: null
    readonly property string tool: root.host ? root.host.afterlightPath : ""
    function read() { if (!appsReader.running) appsReader.running = true }
    function step(role, by) {
      const r = info[role]
      const ids = r.choices.map(c => c.id)
      const next = ids[(ids.indexOf(r.chosen) + by + ids.length) % ids.length]
      const copy = JSON.parse(JSON.stringify(info))
      copy[role].chosen = next
      info = copy
      appsSetter.command = [tool, "apps", "set", role, next]
      appsSetter.running = true
    }
    Process {
      id: appsReader
      command: [appsBox.tool, "apps"]
      stdout: StdioCollector { onStreamFinished: { try { appsBox.info = JSON.parse(text) } catch (error) {} } }
    }
    Process { id: appsSetter; onExited: appsBox.read() }
    Component.onCompleted: read()

    Section { width: parent.width; title: strings.t("apps.title"); amber: root.amber; teal: root.teal }
    Repeater {
      model: appsBox.info ? ["coding", "chat"] : []
      delegate: Rectangle {
        id: appRow
        required property string modelData
        readonly property var role: appsBox.info[modelData]
        readonly property var chosen: role.choices.find(c => c.id === role.chosen) || { id: "none", name: "None" }
        width: appsBox.width
        implicitHeight: appLine.implicitHeight + Style.space(12)
        radius: Style.cornerRadius > 0 ? Style.space(4) : 0
        color: Qt.rgba(1, 1, 1, appArea.containsMouse ? 0.06 : 0.03)
        border.width: 1
        border.color: Qt.rgba(1, 1, 1, 0.08)
        Behavior on color { ColorAnimation { duration: Style.duration(160) } }
        RowLayout {
          id: appLine
          anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter
                    leftMargin: Style.space(8); rightMargin: Style.space(8) }
          spacing: Style.space(6)
          Label { Layout.fillWidth: true; text: strings.t("apps." + appRow.modelData); opacity: 0.7 }
          Label { text: Commons.I18n.rightToLeft ? "›" : "‹"; opacity: appArea.containsMouse ? 0.7 : 0.3 }
          Label {
            textFormat: Text.PlainText
            text: appRow.chosen.id === "none" ? strings.t("apps.none") : appRow.chosen.name
            color: appRow.chosen.id === "none" ? Commons.Color.popups.text : root.amber
            opacity: appRow.chosen.id === "none" ? 0.55 : 1
          }
          Label { text: Commons.I18n.rightToLeft ? "‹" : "›"; opacity: appArea.containsMouse ? 0.7 : 0.3 }
        }
        MouseArea {
          id: appArea
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          acceptedButtons: Qt.LeftButton | Qt.RightButton
          onClicked: function(event) { appsBox.step(appRow.modelData, event.button === Qt.RightButton ? -1 : 1) }
        }
      }
    }
    Label {
      width: parent.width
      wrapMode: Text.WordWrap
      elide: Text.ElideNone
      font.pixelSize: Style.font.caption
      opacity: 0.5
      text: strings.t("apps.hint")
    }
  }

  // The Razer mouse, when it's plugged in: lighting in the mode's colours,
  // and what the slow-down button, side buttons and wheel tilt do.
  Column {
    id: mouseBox
    width: parent.width
    spacing: Style.space(6)
    visible: !!info && info.connected
    property var info: null
    property var queue: []
    readonly property bool lit: !!info && info.lighting
    readonly property string tool: root.host ? root.host.afterlightPath : ""
    function read() { if (!mouseReader.running) mouseReader.running = true }
    function choices(button) {
      if (!info) return []
      var tapOnly = info.tapOnly.indexOf(button) >= 0
      return info.actions.filter(function(a) { return !(tapOnly && info.holds.indexOf(a) >= 0) })
    }
    function send(key, value) {
      queue = queue.concat([[tool, "set", "mouse." + key, JSON.stringify(value)]])
      if (!mouseSetter.running) next()
    }
    function next() {
      if (queue.length === 0) { read(); return }
      mouseSetter.command = queue[0]
      queue = queue.slice(1)
      mouseSetter.running = true
    }
    function step(button, by) {
      var list = choices(button)
      if (list.length === 0) return
      var at = list.indexOf(info.buttons[button])
      var value = list[((at < 0 ? 0 : at + by) + list.length) % list.length]
      var copy = JSON.parse(JSON.stringify(info))
      copy.buttons[button] = value
      info = copy
      send(button, value)
    }
    function setLighting(on) {
      var copy = JSON.parse(JSON.stringify(info))
      copy.lighting = on
      info = copy
      send("lighting", on)
    }
    function stepColour(zone, by) {
      var list = info.colourNames
      var at = list.indexOf(info.zones[zone])
      var value = list[((at < 0 ? 0 : at + by) + list.length) % list.length]
      var copy = JSON.parse(JSON.stringify(info))
      copy.zones[zone] = value
      info = copy
      send(zone, value)
    }
    Process {
      id: mouseReader
      command: [mouseBox.tool, "mouse", "status"]
      stdout: StdioCollector { onStreamFinished: { try { mouseBox.info = JSON.parse(text) } catch (error) {} } }
    }
    Process { id: mouseSetter; onExited: Qt.callLater(mouseBox.next) }
    Component.onCompleted: read()

    Section { width: parent.width; title: strings.t("mouse.title"); amber: root.amber; teal: root.teal }
    OptionTile {
      width: parent.width
      icon: "󰍽"
      title: strings.t("mouse.lighting")
      detail: strings.t(mouseBox.info && mouseBox.info.lighting ? "mouse.lightingOn" : "mouse.lightingOff")
      checked: !!mouseBox.info && mouseBox.info.lighting
      amber: root.amber; teal: root.teal
      onToggled: mouseBox.setLighting(!checked)
    }
    // The mouse as it's lit now, beside each light's colour (click to change).
    RowLayout {
      width: parent.width
      visible: mouseBox.lit
      spacing: Style.space(12)

      Item {
        id: mouseArt
        // Room for the halo, which reaches past the body.
        Layout.leftMargin: Style.space(10)
        Layout.topMargin: Style.space(8)
        Layout.bottomMargin: Style.space(8)
        Layout.preferredWidth: Style.space(62)
        Layout.preferredHeight: Style.space(100)
        readonly property var now: mouseBox.info ? mouseBox.info.now : ({})
        function lit(zone) { const c = now[zone]; return c && c !== "#000000" ? c : "transparent" }

        // The light strip: a halo all round the body, in its colour.
        readonly property bool stripOn: lit("strip") !== "transparent"
        Repeater {
          model: mouseArt.stripOn ? [Style.space(7), Style.space(4.5), Style.space(2.5)] : []
          Rectangle {
            required property real modelData
            required property int index
            anchors.fill: parent
            anchors.margins: -modelData
            radius: width * 0.46
            color: "transparent"
            border.width: Style.space(2.5)
            border.color: mouseArt.lit("strip")
            opacity: [0.12, 0.22, 0.4][index]
          }
        }
        Rectangle {
          id: body
          anchors.fill: parent
          radius: width * 0.46
          color: Qt.rgba(1, 1, 1, 0.04)
          border.width: mouseArt.stripOn ? Style.space(1.5) : 1
          border.color: mouseArt.stripOn ? mouseArt.lit("strip") : Qt.rgba(1, 1, 1, 0.2)
        }
        // The two buttons' parting.
        Rectangle { x: parent.width / 2; y: 2; width: 1; height: parent.height * 0.36; color: Qt.rgba(1, 1, 1, 0.16) }
        Rectangle {
          x: 0; y: parent.height * 0.36; width: parent.width; height: 1
          color: Qt.rgba(1, 1, 1, 0.08)
        }
        // Wheel.
        Rectangle {
          anchors.horizontalCenter: parent.horizontalCenter
          y: Style.space(8)
          width: Style.space(14); height: Style.space(26); radius: width / 2
          color: mouseArt.lit("wheel"); opacity: 0.3
        }
        Rectangle {
          anchors.horizontalCenter: parent.horizontalCenter
          y: Style.space(11)
          width: Style.space(7); height: Style.space(20); radius: width / 2
          color: mouseArt.lit("wheel") === "transparent" ? Qt.rgba(1, 1, 1, 0.1) : mouseArt.lit("wheel")
        }
        // Logo.
        Rectangle {
          anchors.horizontalCenter: parent.horizontalCenter
          y: parent.height * 0.64 - Style.space(4)
          width: Style.space(20); height: width; radius: width / 2
          color: mouseArt.lit("logo"); opacity: 0.3
        }
        Rectangle {
          anchors.horizontalCenter: parent.horizontalCenter
          y: parent.height * 0.64
          width: Style.space(12); height: width; radius: width / 2
          color: mouseArt.lit("logo") === "transparent" ? Qt.rgba(1, 1, 1, 0.1) : mouseArt.lit("logo")
        }
      }

      ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.space(6)
        Repeater {
          model: ["logo", "wheel", "strip"]
          delegate: Rectangle {
            id: zoneRow
            required property string modelData
            readonly property string colourName: mouseBox.info ? (mouseBox.info.zones[modelData] || "off") : "off"
            Layout.fillWidth: true
            implicitHeight: zoneLine.implicitHeight + Style.space(12)
            radius: Style.cornerRadius > 0 ? Style.space(4) : 0
            color: Qt.rgba(1, 1, 1, zoneArea.containsMouse ? 0.06 : 0.03)
            border.width: 1
            border.color: Qt.rgba(1, 1, 1, 0.08)
            Behavior on color { ColorAnimation { duration: Style.duration(160) } }

            RowLayout {
              id: zoneLine
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.space(8)
              anchors.rightMargin: Style.space(8)
              spacing: Style.space(6)
              Label { Layout.fillWidth: true; text: strings.t("mouse.zone." + zoneRow.modelData); opacity: 0.7 }
              Label { text: Commons.I18n.rightToLeft ? "›" : "‹"; opacity: zoneArea.containsMouse ? 0.7 : 0.3 }
              Label {
                text: strings.t("mouse.colour." + zoneRow.colourName)
                color: zoneRow.colourName === "off" ? Commons.Color.popups.text : (mouseBox.info && mouseBox.info.now[zoneRow.modelData]) || root.amber
                opacity: zoneRow.colourName === "off" ? 0.5 : 1
              }
              Label { text: Commons.I18n.rightToLeft ? "‹" : "›"; opacity: zoneArea.containsMouse ? 0.7 : 0.3 }
            }
            MouseArea {
              id: zoneArea
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              acceptedButtons: Qt.LeftButton | Qt.RightButton
              onClicked: function(event) { mouseBox.stepColour(zoneRow.modelData, event.button === Qt.RightButton ? -1 : 1) }
            }
          }
        }
      }
    }
    ThemedSlider {
      width: parent.width
      visible: mouseBox.lit
      icon: "󰏘"
      label: strings.t("mouse.strength")
      valueText: root.pct(liveValue * 100)
      value: mouseBox.info ? mouseBox.info.strength : 0.8
      minimum: 0; maximum: 1; step: 0.05
      fromColor: root.amber
      toColor: root.teal
      onCommitted: function(v) { mouseBox.send("strength", v) }
    }
    // Brightness per mode, side by side.
    Row {
      id: brightRow
      width: parent.width
      visible: mouseBox.lit
      spacing: Style.space(10)
      Repeater {
        model: mouseBox.lit ? ["day", "night", "saver"] : []
        delegate: ThemedSlider {
          required property string modelData
          width: (brightRow.width - brightRow.spacing * 2) / 3
          icon: modelData === "day" ? "󰖨" : modelData === "night" ? "󰖔" : "󰌪"
          label: strings.t("mode." + modelData)
          valueText: root.pct(liveValue)
          value: mouseBox.info.brightness[modelData]
          minimum: 5; maximum: 100; step: 5
          rangeGradient: true
          fromColor: "#000000"
          toColor: root.amber
          onCommitted: function(v) { mouseBox.send("brightness" + modelData.charAt(0).toUpperCase() + modelData.slice(1), Math.round(v)) }
        }
      }
    }
    Label {
      visible: mouseBox.lit
      text: strings.t("mouse.brightnessHint")
      font.pixelSize: Style.font.caption
      opacity: 0.5
    }
    Item { width: 1; height: Style.space(2) }
    Label {
      text: strings.t("mouse.buttons").toUpperCase()
      font.pixelSize: Style.font.caption
      font.letterSpacing: Style.space(2)
      color: root.teal
      opacity: 0.8
    }
    Repeater {
      model: ["sniper", "front", "rear", "tiltLeft", "tiltRight"]
      delegate: Rectangle {
        id: buttonRow
        required property string modelData
        readonly property string action: mouseBox.info ? (mouseBox.info.buttons[modelData] || "default") : "default"
        width: mouseBox.width
        implicitHeight: buttonLine.implicitHeight + Style.space(12)
        radius: Style.cornerRadius > 0 ? Style.space(4) : 0
        color: Qt.rgba(1, 1, 1, buttonArea.containsMouse ? 0.06 : 0.03)
        border.width: 1
        border.color: Qt.rgba(1, 1, 1, 0.08)
        Behavior on color { ColorAnimation { duration: Style.duration(160) } }

        RowLayout {
          id: buttonLine
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          anchors.leftMargin: Style.space(8)
          anchors.rightMargin: Style.space(8)
          spacing: Style.space(6)
          Label { Layout.fillWidth: true; text: strings.t("mouse.button." + buttonRow.modelData); opacity: 0.7 }
          Label { text: Commons.I18n.rightToLeft ? "›" : "‹"; opacity: buttonArea.containsMouse ? 0.7 : 0.3 }
          Label {
            text: buttonRow.action === "default" ? strings.t("mouse.default." + buttonRow.modelData)
                                                 : strings.t("mouse.action." + buttonRow.action)
            color: buttonRow.action === "default" ? Commons.Color.popups.text : root.amber
            opacity: buttonRow.action === "default" ? 0.55 : 1
          }
          Label { text: Commons.I18n.rightToLeft ? "‹" : "›"; opacity: buttonArea.containsMouse ? 0.7 : 0.3 }
        }
        MouseArea {
          id: buttonArea
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          acceptedButtons: Qt.LeftButton | Qt.RightButton
          onClicked: function(event) { mouseBox.step(buttonRow.modelData, event.button === Qt.RightButton ? -1 : 1) }
        }
      }
    }
    Label {
      width: parent.width
      wrapMode: Text.WordWrap
      elide: Text.ElideNone
      font.pixelSize: Style.font.caption
      opacity: 0.5
      text: strings.t("mouse.hint")
    }
  }

  // Superwhisper's recording indicator: the glow round the window you're
  // dictating into (in the look's accent), a small pill, or nothing.
  Column {
    id: dictation
    width: parent.width
    spacing: Style.space(6)
    property var cfg: null
    readonly property string current: !cfg ? "" : cfg.showRecordingIndicator === false ? "off"
      : (cfg.recordingIndicatorStyle || "edgeGlow")
    visible: cfg !== null
    function read() { if (!dictReader.running) dictReader.running = true }
    function choose(value) {
      const copy = JSON.parse(JSON.stringify(cfg))
      copy.showRecordingIndicator = value !== "off"
      if (value !== "off") copy.recordingIndicatorStyle = value
      cfg = copy
      const cmd = value === "off" ? "superwhisper audio set showRecordingIndicator false"
        : "superwhisper audio set showRecordingIndicator true && superwhisper audio set recordingIndicatorStyle '\"" + value + "\"'"
      dictSetter.command = ["sh", "-c", cmd]
      dictSetter.running = true
    }
    Process {
      id: dictReader
      command: ["superwhisper", "audio", "show"]
      stdout: StdioCollector { onStreamFinished: { try { dictation.cfg = JSON.parse(text).config || {} } catch (error) {} } }
    }
    Process { id: dictSetter; onExited: dictation.read() }
    Component.onCompleted: read()

    Section { width: parent.width; title: strings.t("dictation.title"); amber: root.amber; teal: root.teal }
    Row {
      id: dictRow
      width: parent.width
      spacing: Style.space(8)
      Repeater {
        model: [
          { value: "edgeGlow", icon: "󰹞" },
          { value: "pill", icon: "󰍬" },
          { value: "off", icon: "󰍭" }
        ]
        delegate: OptionTile {
          required property var modelData
          width: (dictRow.width - dictRow.spacing * 2) / 3
          icon: modelData.icon
          title: strings.t("dictation." + modelData.value)
          checked: dictation.current === modelData.value
          amber: root.amber; teal: root.teal
          onToggled: dictation.choose(modelData.value)
        }
      }
    }
    Label {
      width: parent.width
      wrapMode: Text.WordWrap
      elide: Text.ElideNone
      font.pixelSize: Style.font.caption
      opacity: 0.5
      text: strings.t("dictation.hint")
    }
  }
}
