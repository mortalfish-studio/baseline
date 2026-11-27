import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons

// What used to sit on the bar as icons. Wi-Fi and Bluetooth open a picker
// right here (networks with a password field; devices to pair, connect or
// forget), then the quiet switches: do not disturb, stay awake and Focus.
Column {
  id: root
  property var host: null
  spacing: Style.space(7)

  readonly property color amber: Commons.Color.accent
  readonly property color teal: host ? host.themeCyan : Commons.Color.foreground
  readonly property string tool: host ? host.afterlightPath : ""
  property var q: null
  property string expanded: ""        // "", "wifi" or "bt"
  property var wifi: null
  property var bt: null
  property string busy: ""            // what a running action is about, shown on its row
  property string error: ""
  property string askFor: ""          // the secured network waiting for a password

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("../i18n") }

  function refresh() {
    if (!reader.running) reader.running = true
    if (expanded === "wifi" && !wifiReader.running) { wifiReader.command = [tool, "wifi", "list"]; wifiReader.running = true }
    if (expanded === "bt" && !btReader.running) { btReader.command = [tool, "bt", "list"]; btReader.running = true }
  }
  function scan() {
    if (expanded === "wifi" && !wifiReader.running) { wifiReader.command = [tool, "wifi", "scan"]; wifiReader.running = true }
    if (expanded === "bt" && !btReader.running) { btReader.command = [tool, "bt", "scan"]; btReader.running = true }
  }
  function toggleSection(name) {
    expanded = expanded === name ? "" : name
    askFor = ""
    error = ""
    scan()
  }
  // One action at a time; text for stdin (a Wi-Fi password) is optional.
  function act(argv, note, input) {
    if (actor.running) return
    busy = note || ""
    error = ""
    actor.pendingInput = input || ""
    actor.command = argv
    actor.running = true
  }

  Process {
    id: reader
    command: [root.tool, "quick"]
    stdout: StdioCollector { onStreamFinished: { try { root.q = JSON.parse(text) } catch (error) {} } }
  }
  Process {
    id: wifiReader
    stdout: StdioCollector { onStreamFinished: { try { root.wifi = JSON.parse(text) } catch (error) {} } }
  }
  Process {
    id: btReader
    stdout: StdioCollector { onStreamFinished: { try { root.bt = JSON.parse(text) } catch (error) {} } }
  }
  Process {
    id: actor
    property string pendingInput: ""
    stdinEnabled: true
    onStarted: {
      if (pendingInput !== "") write(pendingInput + "\n")
      pendingInput = ""
      stdinEnabled = false
    }
    stderr: StdioCollector {
      onStreamFinished: {
        const message = text.trim().split("\n").pop() || ""
        if (message !== "") root.error = message.slice(0, 160)
      }
    }
    onExited: { stdinEnabled = true; root.busy = ""; root.refresh() }
  }

  Timer {
    interval: 5000
    repeat: true
    triggeredOnStart: true
    running: root.visible
    onTriggered: root.refresh()
  }

  Section { width: parent.width; title: strings.t("quick.title"); amber: root.amber; teal: root.teal }

  Grid {
    id: grid
    width: parent.width
    columns: 2
    columnSpacing: Style.space(8)
    rowSpacing: Style.space(8)
    readonly property real cell: (width - columnSpacing) / 2

    OptionTile {
      width: grid.cell
      readonly property var w: root.q ? root.q.wifi : null
      icon: w && w.ssid ? "󰖩" : "󰖪"
      title: strings.t("quick.wifi") + (root.expanded === "wifi" ? "  ▾" : "")
      detail: !w ? "" : !w.on ? strings.t("quick.wifiOff")
        : !w.ssid ? strings.t("quick.wifiNone")
        : strings.t("quick.wifiOn").arg(w.ssid).arg(Commons.I18n.formatNumber(w.signal || 0))
      checked: !!w && w.ssid !== ""
      amber: root.amber; teal: root.teal
      onToggled: root.toggleSection("wifi")
    }
    OptionTile {
      width: grid.cell
      readonly property var b: root.q ? root.q.bluetooth : null
      icon: b && b.on ? "󰂯" : "󰂲"
      title: strings.t("quick.bluetooth") + (root.expanded === "bt" ? "  ▾" : "")
      detail: !b ? "" : !b.on ? strings.t("quick.btOff")
        : b.devices.length ? b.devices.join(", ") : strings.t("quick.btOn")
      checked: !!b && b.on
      amber: root.amber; teal: root.teal
      onToggled: root.toggleSection("bt")
    }
  }

  // ---- The picker for whichever tile is open
  Rectangle {
    width: parent.width
    visible: root.expanded !== ""
    height: picker.implicitHeight + Style.space(16)
    radius: Style.cornerRadius > 0 ? Style.space(4) : 0
    color: Qt.rgba(1, 1, 1, 0.03)
    border.width: 1
    border.color: Qt.rgba(root.teal.r, root.teal.g, root.teal.b, 0.3)

    Column {
      id: picker
      x: Style.space(8)
      y: Style.space(8)
      width: parent.width - Style.space(16)
      spacing: Style.space(6)

      readonly property bool isWifi: root.expanded === "wifi"
      readonly property var info: isWifi ? root.wifi : root.bt
      readonly property bool radioOn: !!info && info.on
      readonly property bool scanning: isWifi ? wifiReader.running : btReader.running

      RowLayout {
        width: parent.width
        spacing: Style.space(6)
        Label {
          Layout.fillWidth: true
          text: picker.scanning ? strings.t("quick.scanning")
            : picker.radioOn ? strings.t(picker.isWifi ? "quick.pickNetwork" : "quick.pickDevice")
            : strings.t(picker.isWifi ? "quick.wifiIsOff" : "quick.btIsOff")
          font.pixelSize: Style.font.caption
          opacity: 0.7
        }
        ActionButton {
          visible: picker.radioOn
          icon: "󰑐"
          text: strings.t("quick.scan")
          tone: root.teal
          enabled: !picker.scanning
          onClicked: root.scan()
        }
        ActionButton {
          text: strings.t(picker.radioOn ? "quick.turnOff" : "quick.turnOn")
          tone: root.amber
          onClicked: picker.isWifi
            ? root.act([root.tool, "wifi", "power", picker.radioOn ? "off" : "on"], "power")
            : root.act(["omarchy-bluetooth-power", picker.radioOn ? "off" : "on"], "power")
        }
      }

      // Networks
      Repeater {
        model: picker.isWifi && picker.radioOn && root.wifi ? root.wifi.networks : []
        delegate: Column {
          id: net
          required property var modelData
          width: picker.width
          spacing: Style.space(4)
          readonly property bool asking: root.askFor === modelData.ssid

          Rectangle {
            width: parent.width
            height: netRow.implicitHeight + Style.space(10)
            radius: Style.cornerRadius > 0 ? Style.space(3) : 0
            color: net.modelData.active ? Qt.rgba(root.teal.r, root.teal.g, root.teal.b, 0.12)
              : netHover.hovered ? Qt.rgba(1, 1, 1, 0.06) : "transparent"
            RowLayout {
              id: netRow
              anchors.verticalCenter: parent.verticalCenter
              x: Style.space(6)
              width: parent.width - Style.space(12)
              spacing: Style.space(8)
              Label {
                text: net.modelData.signal > 66 ? "󰤨" : net.modelData.signal > 33 ? "󰤥" : "󰤟"
                font.family: "Iosevka Nerd Font Propo"
                color: net.modelData.active ? root.teal : Commons.Color.popups.text
              }
              Label {
                Layout.fillWidth: true
                text: net.modelData.ssid
                font.bold: net.modelData.active
                color: net.modelData.active ? root.teal : Commons.Color.popups.text
              }
              Label {
                font.pixelSize: Style.font.caption
                opacity: 0.6
                text: root.busy === net.modelData.ssid ? strings.t("quick.connecting")
                  : net.modelData.active ? strings.t("quick.connected")
                  : net.modelData.known ? strings.t("quick.saved")
                  : net.modelData.secure ? "󰌾" : strings.t("quick.open")
              }
            }
            HoverHandler { id: netHover; cursorShape: Qt.PointingHandCursor }
            TapHandler {
              onTapped: {
                const n = net.modelData
                if (n.active) root.act([root.tool, "wifi", "disconnect"], n.ssid)
                else if (n.known || !n.secure) root.act([root.tool, "wifi", "connect", n.ssid], n.ssid)
                else { root.askFor = root.askFor === n.ssid ? "" : n.ssid; root.error = "" }
              }
            }
          }

          // Password for a new secured network.
          RowLayout {
            visible: net.asking
            width: parent.width
            spacing: Style.space(6)
            Rectangle {
              Layout.fillWidth: true
              implicitHeight: pass.implicitHeight + Style.space(10)
              radius: Style.cornerRadius > 0 ? Style.space(3) : 0
              color: Qt.rgba(1, 1, 1, 0.05)
              border.width: 1
              border.color: pass.activeFocus ? root.amber : Qt.rgba(1, 1, 1, 0.15)
              TextInput {
                id: pass
                anchors.verticalCenter: parent.verticalCenter
                x: Style.space(6)
                width: parent.width - Style.space(12)
                echoMode: TextInput.Password
                color: Commons.Color.popups.text
                font.family: Style.font.family
                font.pixelSize: Style.font.body
                clip: true
                onVisibleChanged: if (visible) { text = ""; forceActiveFocus() }
                onAccepted: connectButton.clicked()
                Text {
                  visible: pass.text === ""
                  textFormat: Text.PlainText
                  text: strings.t("quick.password")
                  color: Commons.Color.popups.text
                  opacity: 0.4
                  font: pass.font
                }
              }
            }
            ActionButton {
              id: connectButton
              text: strings.t("quick.connect")
              tone: root.amber
              enabled: pass.text.length >= 8
              onClicked: {
                root.act([root.tool, "wifi", "connect", net.modelData.ssid], net.modelData.ssid, pass.text)
                pass.text = ""
                root.askFor = ""
              }
            }
          }
        }
      }

      // Bluetooth devices
      Repeater {
        model: !picker.isWifi && picker.radioOn && root.bt ? root.bt.devices : []
        delegate: Rectangle {
          id: dev
          required property var modelData
          width: picker.width
          height: devRow.implicitHeight + Style.space(10)
          radius: Style.cornerRadius > 0 ? Style.space(3) : 0
          color: modelData.connected ? Qt.rgba(root.teal.r, root.teal.g, root.teal.b, 0.12)
            : devHover.hovered ? Qt.rgba(1, 1, 1, 0.06) : "transparent"
          RowLayout {
            id: devRow
            anchors.verticalCenter: parent.verticalCenter
            x: Style.space(6)
            width: parent.width - Style.space(12)
            spacing: Style.space(8)
            Label {
              text: "󰂱"
              font.family: "Iosevka Nerd Font Propo"
              color: dev.modelData.connected ? root.teal : Commons.Color.popups.text
            }
            Label {
              Layout.fillWidth: true
              text: dev.modelData.name
              font.bold: dev.modelData.connected
              color: dev.modelData.connected ? root.teal : Commons.Color.popups.text
            }
            Label {
              font.pixelSize: Style.font.caption
              opacity: 0.6
              text: root.busy === dev.modelData.address ? strings.t("quick.connecting")
                : dev.modelData.connected ? strings.t("quick.connected")
                : dev.modelData.paired ? strings.t("quick.paired") : strings.t("quick.pair")
            }
            // Forget, for paired devices.
            Label {
              visible: dev.modelData.paired
              text: "󰆴"
              font.family: "Iosevka Nerd Font Propo"
              opacity: forgetHover.hovered ? 1 : 0.4
              color: forgetHover.hovered ? Commons.Color.urgent : Commons.Color.popups.text
              HoverHandler { id: forgetHover; cursorShape: Qt.PointingHandCursor }
              TapHandler { onTapped: root.act(["omarchy-bluetooth-device", "forget", dev.modelData.address], dev.modelData.address) }
            }
          }
          HoverHandler { id: devHover; cursorShape: Qt.PointingHandCursor }
          TapHandler {
            onTapped: {
              const d = dev.modelData
              const verb = d.connected ? "disconnect" : d.paired ? "connect" : "pair"
              root.act(["omarchy-bluetooth-device", verb, d.address], d.address)
            }
          }
        }
      }

      Label {
        visible: picker.radioOn && !picker.scanning && !!picker.info
          && (picker.isWifi ? picker.info.networks : picker.info.devices).length === 0
        text: strings.t(picker.isWifi ? "quick.noNetworks" : "quick.noDevices")
        font.pixelSize: Style.font.caption
        opacity: 0.6
      }
    }
  }

  Grid {
    id: quiet
    width: parent.width
    columns: 2
    columnSpacing: Style.space(8)
    rowSpacing: Style.space(8)
    readonly property real cell: (width - columnSpacing) / 2

    OptionTile {
      width: quiet.cell
      icon: "󰂛"
      title: strings.t("quick.dnd")
      detail: root.q && root.q.dnd ? strings.t("quick.dndOn") : strings.t("quick.dndOff")
      checked: !!root.q && root.q.dnd
      amber: root.amber; teal: root.teal
      onToggled: root.act(["omarchy-shell", "notifications", "toggleDnd"], "dnd")
    }
    OptionTile {
      width: quiet.cell
      icon: "󰅶"
      title: strings.t("quick.awake")
      detail: root.q && root.q.awake ? strings.t("quick.awakeOn") : strings.t("quick.awakeOff")
      checked: !!root.q && root.q.awake
      amber: root.amber; teal: root.teal
      onToggled: root.act(["omarchy-toggle-idle"], "awake")
    }
  }

  // Focus: one switch for a quiet, dark, paused desk.
  OptionTile {
    width: parent.width
    icon: "󰽥"
    title: strings.t("quick.focus")
    detail: root.q && root.q.focus ? strings.t("quick.focusOn") : strings.t("quick.focusOff")
    checked: !!root.q && root.q.focus
    amber: root.amber; teal: root.teal
    onToggled: root.act([root.tool, "focus", "toggle"], "focus")
  }

  // Any switch or picker action that failed says why, here under them all.
  Label {
    visible: root.error !== ""
    width: parent.width
    wrapMode: Text.Wrap
    text: root.error
    font.pixelSize: Style.font.caption
    color: Commons.Color.urgent
  }
}
