import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Resources as gauges with their limits, then where the power is going: in
// from the charger, used by the system, and into or out of the battery.
Column {
  id: root
  property var host: null
  readonly property var s: host ? host.snapshot : null
  readonly property var p: s ? s.power : null
  readonly property color amber: Commons.Color.accent
  readonly property color teal: host ? host.themeCyan : Commons.Color.foreground
  readonly property color red: Commons.Color.urgent
  spacing: Style.space(12)

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("../i18n") }

  function num(value) { return typeof value === "number" && isFinite(value) }
  function n(v, d) { return Commons.I18n.formatNumber(v, d || 0) }
  function pct(v) { return strings.t("percent").arg(n(Math.round(v))) }
  function watts(v, est) { return num(v) ? (est ? "≈" : "") + strings.t("watts").arg(n(Math.abs(v), 1)) : "—" }

  Label {
    visible: !root.s
    text: strings.t(root.host && root.host.failed ? "unavailable" : "collecting")
  }

  QuickControls { width: parent.width; host: root.host }

  // ======================================================== Resources
  Column {
    width: parent.width
    spacing: Style.space(7)
    visible: !!root.s

    Section { width: parent.width; title: strings.t("system.resources"); amber: root.amber; teal: root.teal }

    Meter {
      width: parent.width; teal: root.teal; amber: root.amber; red: root.red
      name: strings.t("baseline.cpu")
      value: root.s && root.num(root.s.cpu) ? root.s.cpu : -1
      limit: root.host ? root.host.cpuLimit : 85
      alarm: !!root.host && root.host.cpuOff
      reading: root.s ? root.pct(root.s.cpu) : ""
    }
    Meter {
      width: parent.width; teal: root.teal; amber: root.amber; red: root.red
      name: strings.t("baseline.mem")
      value: root.s ? 100 * root.s.memoryUsed / root.s.memoryTotal : -1
      limit: root.host ? root.host.memoryLimit : 90
      alarm: !!root.host && root.host.memoryOff
      reading: root.s ? root.pct(100 * root.s.memoryUsed / root.s.memoryTotal) : ""
    }
    Meter {
      width: parent.width; teal: root.teal; amber: root.amber; red: root.red
      name: strings.t("baseline.temp")
      value: root.s && root.num(root.s.temperature) ? root.s.temperature : -1
      limit: root.host ? root.host.tempLimit : 75
      alarm: !!root.host && root.host.tempOff
      reading: root.s && root.num(root.s.temperature) ? strings.t("hover.degrees").arg(root.n(Math.round(root.s.temperature))) : ""
    }
    Meter {
      width: parent.width; teal: root.teal; amber: root.amber; red: root.red
      name: strings.t("baseline.disk")
      value: root.host ? root.host.baselineDiskFree : -1
      limit: root.host ? root.host.diskLimit : 10
      low: true
      alarm: !!root.host && root.host.diskOff
      reading: root.host ? root.pct(root.host.baselineDiskFree) : ""
    }
    Meter {
      width: parent.width; teal: root.teal; amber: root.amber; red: root.red
      name: strings.t("system.screen")
      value: root.s && root.num(root.s.screen) ? root.s.screen : -1
      reading: root.s && root.num(root.s.screen) ? root.pct(root.s.screen) : ""
    }
  }

  // ======================================================== Power
  Column {
    width: parent.width
    spacing: Style.space(8)
    visible: !!root.p && root.num(root.p.batteryWatts)

    Section { width: parent.width; title: strings.t("power.title"); amber: root.amber; teal: root.teal }

    // Three readouts: in, system, battery.
    Row {
      id: readouts
      width: parent.width
      spacing: Style.space(8)
      readonly property real cell: (width - spacing * 2) / 3
      readonly property bool charging: !!root.p && root.p.batteryWatts > 0

      Repeater {
        model: [
          { key: "power.in", glyph: "󰚥", tone: "text" },
          { key: "power.used", glyph: "󰍹", tone: "teal" },
          { key: readouts.charging ? "power.charging" : "power.draining", glyph: readouts.charging ? "󰂄" : "󰁾", tone: "amber" }
        ]
        delegate: Rectangle {
          id: cell
          required property var modelData
          required property int index
          readonly property color tone: modelData.tone === "teal" ? root.teal : modelData.tone === "amber" ? root.amber : Commons.Color.popups.text
          width: readouts.cell
          height: cellColumn.implicitHeight + Style.space(12)
          radius: Style.cornerRadius > 0 ? Style.space(4) : 0
          color: Qt.rgba(tone.r, tone.g, tone.b, 0.07)
          border.width: 1
          border.color: Qt.rgba(tone.r, tone.g, tone.b, 0.35)
          Column {
            id: cellColumn
            anchors.centerIn: parent
            spacing: Style.space(2)
            Label {
              anchors.horizontalCenter: parent.horizontalCenter
              text: {
                if (!root.p) return ""
                if (cell.index === 0) return root.watts(root.p.inWatts, root.p.estimated)
                if (cell.index === 1) return root.watts(root.p.systemWatts, root.p.estimated)
                return root.watts(root.p.batteryWatts, false)
              }
              font.pixelSize: Style.font.subtitle
              font.bold: true
              color: cell.tone
            }
            Label {
              anchors.horizontalCenter: parent.horizontalCenter
              text: cell.modelData.glyph + " " + strings.t(cell.modelData.key)
              font.pixelSize: Style.font.caption
              opacity: 0.65
            }
          }
        }
      }
    }

    // The split, as one bar: system (teal) and battery (amber).
    Item {
      id: flowBar
      width: parent.width
      height: Style.space(6)
      readonly property bool charging: !!root.p && root.p.batteryWatts > 0
      readonly property real first: !root.p ? 0 : charging ? (root.p.systemWatts || 0) : Math.max(0, root.p.inWatts || 0)
      readonly property real second: root.p && root.num(root.p.batteryWatts) ? Math.abs(root.p.batteryWatts) : 0
      readonly property real total: Math.max(0.001, first + second)
      Rectangle { anchors.fill: parent; color: Qt.rgba(1, 1, 1, 0.06) }
      Row {
        anchors.fill: parent
        spacing: Style.space(2)
        Rectangle {
          height: parent.height
          width: (parent.width - parent.spacing) * flowBar.first / flowBar.total
          color: flowBar.charging ? root.teal : Commons.Color.popups.text
          opacity: flowBar.charging ? 1 : 0.6
          Behavior on width { NumberAnimation { duration: Style.duration(240); easing.type: Easing.OutCubic } }
        }
        Rectangle {
          height: parent.height
          width: (parent.width - parent.spacing) * flowBar.second / flowBar.total
          color: root.amber
          Behavior on width { NumberAnimation { duration: Style.duration(240); easing.type: Easing.OutCubic } }
        }
      }
    }

    Meter {
      width: parent.width; teal: root.teal; amber: root.amber; red: root.red
      name: strings.t("baseline.bat")
      value: root.p && root.num(root.p.percent) ? root.p.percent : -1
      limit: root.host ? root.host.batteryLimit : 15
      low: true
      alarm: !!root.host && root.host.batteryOff
      detail: root.p ? strings.t(root.p.external ? "externalPower" : "batteryPower") : ""
      reading: root.p && root.num(root.p.percent) ? root.pct(root.p.percent) : ""
    }

    Label {
      width: parent.width
      wrapMode: Text.WordWrap
      elide: Text.ElideNone
      opacity: 0.6
      font.pixelSize: Style.font.caption
      visible: text !== ""
      text: {
        if (!root.p || !root.p.external) return ""
        if (root.p.batteryWatts < 0) return strings.t("power.weakCharger")
        if (root.p.estimated) return strings.t("power.estimated")
        return ""
      }
    }
  }

  // Power profile, which the bar's battery menu used to hold.
  Column {
    id: profiles
    width: parent.width
    spacing: Style.space(6)
    property string current: ""
    function read() { if (!profileReader.running) profileReader.running = true }
    Process {
      id: profileReader
      command: ["powerprofilesctl", "get"]
      stdout: StdioCollector { onStreamFinished: profiles.current = text.trim() }
    }
    Process { id: profileSetter; onExited: profiles.read() }
    Timer { interval: 10000; repeat: true; triggeredOnStart: true; running: profiles.visible; onTriggered: profiles.read() }

    Section { width: parent.width; title: strings.t("power.profile"); amber: root.amber; teal: root.teal }
    Row {
      id: profileRow
      width: parent.width
      spacing: Style.space(8)
      Repeater {
        model: [
          { value: "power-saver", icon: "󰌪" },
          { value: "balanced", icon: "󰾅" },
          { value: "performance", icon: "󰓅" }
        ]
        delegate: OptionTile {
          required property var modelData
          width: (profileRow.width - profileRow.spacing * 2) / 3
          icon: modelData.icon
          title: strings.t("power.profile." + modelData.value)
          checked: profiles.current === modelData.value
          amber: root.amber; teal: root.teal
          onToggled: {
            profiles.current = modelData.value
            profileSetter.command = ["powerprofilesctl", "set", modelData.value]
            profileSetter.running = true
          }
        }
      }
    }
  }

  ActionButton {
    icon: "󰄪"
    text: strings.t("btop")
    tone: root.teal
    onClicked: {
      root.host.close()
      root.host.bar.run("omarchy-launch-or-focus-tui btop")
    }
  }
}
