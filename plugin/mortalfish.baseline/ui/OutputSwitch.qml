import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons

// Where sound goes: one lit tile per output (Speaker, Headphones, and any
// Bluetooth or USB device while it's there). Picking one moves what's playing
// too. The headphone jack on this laptop never reports a plug, so a wired
// pair shows "jack not sensed" but can still be chosen.
Column {
  id: root
  property var host: null
  spacing: Style.space(6)

  readonly property color amber: Commons.Color.accent
  readonly property color teal: host ? host.themeCyan : Commons.Color.foreground
  readonly property string tool: host ? host.afterlightPath : ""
  property var outputs: []
  property string switching: ""
  property var mic: ({ present: false, muted: false })
  property var tuning: ({ available: false, tuned: false })
  readonly property var current: {
    for (const o of outputs) if (o.default) return o
    return null
  }

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("../i18n") }

  function refresh() { if (!reader.running) reader.running = true }

  function choose(name) {
    if (switcher.running) return
    switching = name
    switcher.command = [tool, "audio", "use", name]
    switcher.running = true
  }

  // One-off commands (mute, mic, volume, tuning), then a fresh look.
  // One at a time; an action asked for meanwhile runs right after.
  property var pendingAct: null
  function act(argv) {
    if (actor.running) { pendingAct = argv; return }
    actor.command = argv
    actor.running = true
  }

  function glyph(kind) {
    return kind === "headphones" ? "󰋋" : kind === "bluetooth" ? "󰂰" : kind === "usb" ? "󰕓"
      : kind === "hdmi" ? "󰡁" : kind === "speaker" ? "󰓃" : "󰕾"
  }

  Process {
    id: reader
    command: [root.tool, "audio", "list"]
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          const parsed = JSON.parse(text)
          if (parsed && Array.isArray(parsed.outputs)) root.outputs = parsed.outputs
          if (parsed && parsed.mic) root.mic = parsed.mic
          if (parsed && parsed.tuning) root.tuning = parsed.tuning
        } catch (error) {}
      }
    }
  }

  Process {
    id: actor
    onExited: {
      if (root.pendingAct) { const next = root.pendingAct; root.pendingAct = null; root.act(next); return }
      root.refresh()
    }
  }

  Process {
    id: switcher
    onExited: { root.switching = ""; root.refresh() }
  }

  // Devices come and go (Bluetooth, USB); look again while on show.
  Timer {
    interval: 4000
    repeat: true
    triggeredOnStart: true
    running: root.visible
    onTriggered: root.refresh()
  }

  Section { width: parent.width; title: strings.t("output.title"); amber: root.amber; teal: root.teal }

  Row {
    id: tiles
    width: parent.width
    spacing: Style.space(8)
    readonly property real cell: root.outputs.length > 0
      ? (width - spacing * (root.outputs.length - 1)) / root.outputs.length : width

    Repeater {
      model: root.outputs
      delegate: Rectangle {
        id: tile
        required property var modelData
        readonly property bool on: modelData.default
        readonly property bool busy: root.switching === modelData.name
        readonly property color tone: modelData.kind === "headphones" || modelData.kind === "bluetooth" ? root.teal : root.amber
        width: tiles.cell
        height: tileColumn.implicitHeight + Style.space(14)
        radius: Style.cornerRadius > 0 ? Style.space(4) : 0
        color: on ? Qt.rgba(tone.r, tone.g, tone.b, 0.16) : (hover.hovered ? Qt.rgba(1, 1, 1, 0.06) : Qt.rgba(1, 1, 1, 0.02))
        border.width: on ? 2 : 1
        border.color: on ? tone : Qt.rgba(tone.r, tone.g, tone.b, hover.hovered ? 0.6 : 0.25)
        Behavior on color { ColorAnimation { duration: Style.duration(140) } }

        Column {
          id: tileColumn
          anchors.centerIn: parent
          width: parent.width - Style.space(12)
          spacing: Style.space(2)
          Label {
            anchors.horizontalCenter: parent.horizontalCenter
            text: root.glyph(tile.modelData.kind)
            font.family: "Iosevka Nerd Font Propo"
            font.pixelSize: Style.font.iconLarge * 1.2
            color: tile.on ? tile.tone : Commons.Color.popups.text
            opacity: tile.on ? 1 : 0.7
          }
          Label {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: tile.modelData.label
            font.bold: tile.on
            color: tile.on ? tile.tone : Commons.Color.popups.text
          }
          Label {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            font.pixelSize: Style.font.caption
            opacity: 0.6
            text: tile.busy ? strings.t("output.switching")
              : tile.on ? (tile.modelData.muted ? strings.t("output.muted")
                : strings.t("output.inUse").arg(Commons.I18n.formatNumber(tile.modelData.volume || 0)))
              : !tile.modelData.connected && tile.modelData.kind === "headphones" ? strings.t("output.notSensed")
              : strings.t("output.choose")
          }
        }
        HoverHandler { id: hover; cursorShape: Qt.PointingHandCursor }
        TapHandler { onTapped: if (!tile.on) root.choose(tile.modelData.name) }
      }
    }
  }

  // Volume of whichever output is in use; it commits on release.
  ThemedSlider {
    width: parent.width
    visible: !!root.current
    icon: root.current && root.current.muted ? "󰝟" : "󰕾"
    label: strings.t("output.volume")
    valueText: root.current && root.current.muted ? strings.t("output.muted")
      : strings.t("percent").arg(Commons.I18n.formatNumber(Math.round(liveValue)))
    value: root.current && root.current.volume !== null ? root.current.volume : 0
    minimum: 0
    maximum: 100
    step: 5
    fromColor: root.amber
    toColor: root.teal
    onCommitted: function(v) { root.act(["pactl", "set-sink-volume", "@DEFAULT_SINK@", Math.round(v) + "%"]) }
  }

  Grid {
    id: toggles
    width: parent.width
    columns: 2
    columnSpacing: Style.space(8)
    rowSpacing: Style.space(8)
    readonly property real cell: (width - columnSpacing) / 2

    OptionTile {
      width: toggles.cell
      visible: !!root.current
      icon: "󰝟"
      title: strings.t("output.mute")
      detail: root.current && root.current.muted ? strings.t("output.muteOn") : strings.t("output.muteOff")
      checked: !!root.current && root.current.muted
      amber: root.amber; teal: root.teal
      onToggled: root.act(["pactl", "set-sink-mute", "@DEFAULT_SINK@", "toggle"])
    }
    OptionTile {
      width: toggles.cell
      visible: root.mic.present
      icon: "󰍭"
      title: strings.t("output.mic")
      detail: root.mic.muted ? strings.t("output.micOff") : strings.t("output.micOn")
      checked: root.mic.muted
      amber: root.amber; teal: root.teal
      onToggled: root.act(["omarchy-audio-input-mute"])
    }
    OptionTile {
      width: toggles.cell
      visible: root.tuning.available && !!root.current && root.current.kind === "speaker"
      icon: "󰝚"
      title: strings.t("output.tuning")
      detail: root.tuning.tuned ? strings.t("output.tuningOn") : strings.t("output.tuningOff")
      checked: root.tuning.tuned
      amber: root.amber; teal: root.teal
      onToggled: root.act(["python3", "-I", "-B", decodeURIComponent(Qt.resolvedUrl("../tuning/speaker.py").toString().replace(/^file:\/\//, "")),
                           root.tuning.tuned ? "original" : "tuned"])
    }
  }
}
