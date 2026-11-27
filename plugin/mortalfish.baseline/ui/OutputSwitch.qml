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
// Sonos, when speakers answer on the network, is one more tile: picking it
// (and a room) hands the slider, mute and the volume keys to that room and
// shows what it's playing. The laptop's own sound stays where it was.
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
  property var sonos: ({ available: false, on: false, rooms: [], room: null })
  readonly property bool sonosOn: !!sonos.on && !!sonos.room
  readonly property var sonosRoom: sonos.room
  // The tiles: the laptop's outputs, then Sonos when it's there.
  readonly property var tileModel: sonos.available
    ? outputs.concat([{ name: "__sonos", label: "Sonos", kind: "sonos", connected: true }]) : outputs

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("../i18n") }

  function refresh() { if (!reader.running) reader.running = true }

  function choose(name) {
    if (switcher.running) return
    switching = name
    if (name === "__sonos") {
      // The room you had, else one that's playing, else the first.
      const rooms = sonos.rooms || []
      const room = sonos.room ? sonos.room.id : (rooms.length ? rooms[0].id : "")
      if (!room) { switching = ""; return }
      switcher.command = [tool, "sonos", "use", room]
    } else if (sonosOn && current && current.name === name) {
      switcher.command = [tool, "sonos", "off"]
    } else if (sonosOn) {
      switcher.command = ["sh", "-c", '"$0" sonos off && "$0" audio use "$1"', tool, name]
    } else {
      switcher.command = [tool, "audio", "use", name]
    }
    switcher.running = true
  }
  function refreshSonos() { if (!sonosReader.running) sonosReader.running = true }

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
      : kind === "hdmi" ? "󰡁" : kind === "speaker" ? "󰓃" : kind === "sonos" ? "󰜟" : "󰕾"
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
    id: sonosReader
    command: [root.tool, "sonos", "state"]
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          const parsed = JSON.parse(text)
          if (parsed && Array.isArray(parsed.rooms)) root.sonos = parsed
        } catch (error) {}
      }
    }
  }

  Process {
    id: actor
    onExited: {
      if (root.pendingAct) { const next = root.pendingAct; root.pendingAct = null; root.act(next); return }
      root.refresh()
      root.refreshSonos()
    }
  }

  Process {
    id: switcher
    onExited: { root.switching = ""; root.refresh(); root.refreshSonos() }
  }

  // Devices come and go (Bluetooth, USB); look again while on show.
  Timer {
    interval: 4000
    repeat: true
    triggeredOnStart: true
    running: root.visible
    onTriggered: { root.refresh(); root.refreshSonos() }
  }

  Section { width: parent.width; title: strings.t("output.title"); amber: root.amber; teal: root.teal }

  Row {
    id: tiles
    width: parent.width
    spacing: Style.space(8)
    readonly property real cell: root.tileModel.length > 0
      ? (width - spacing * (root.tileModel.length - 1)) / root.tileModel.length : width

    Repeater {
      model: root.tileModel
      delegate: Rectangle {
        id: tile
        required property var modelData
        readonly property bool on: modelData.kind === "sonos" ? root.sonosOn : (modelData.default && !root.sonosOn)
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
              : tile.modelData.kind === "sonos" ? (tile.on && root.sonosRoom ? root.sonosRoom.name : strings.t("sonos.choose"))
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

  // Sonos: which room, and what it's playing.
  Flow {
    id: roomChips
    width: parent.width
    visible: root.sonosOn
    spacing: Style.space(6)
    Repeater {
      model: root.sonos.rooms || []
      delegate: Rectangle {
        id: chip
        required property var modelData
        readonly property bool picked: root.sonosRoom && root.sonosRoom.id === modelData.id
        width: chipText.implicitWidth + Style.space(16)
        height: chipText.implicitHeight + Style.space(8)
        radius: Style.cornerRadius > 0 ? height / 2 : 0
        color: picked ? Qt.rgba(root.teal.r, root.teal.g, root.teal.b, 0.18) : (chipHover.hovered ? Qt.rgba(1, 1, 1, 0.06) : "transparent")
        border.width: 1
        border.color: picked ? root.teal : Qt.rgba(root.teal.r, root.teal.g, root.teal.b, 0.3)
        Label {
          id: chipText
          anchors.centerIn: parent
          text: chip.modelData.name
          font.pixelSize: Style.font.caption
          font.bold: chip.picked
          color: chip.picked ? root.teal : Commons.Color.popups.text
        }
        HoverHandler { id: chipHover; cursorShape: Qt.PointingHandCursor }
        TapHandler { onTapped: if (!chip.picked) root.act([root.tool, "sonos", "use", chip.modelData.id]) }
      }
    }
  }

  Rectangle {
    id: sonosCard
    width: parent.width
    visible: root.sonosOn
    readonly property var track: root.sonosRoom ? root.sonosRoom.track : null
    readonly property bool hasTrack: !!track && track.title !== ""
    height: cardRow.implicitHeight + Style.space(16)
    radius: Style.cornerRadius > 0 ? Style.space(4) : 0
    color: Qt.rgba(1, 1, 1, 0.03)
    border.width: 1
    border.color: Qt.rgba(root.teal.r, root.teal.g, root.teal.b, 0.25)

    RowLayout {
      id: cardRow
      anchors.fill: parent
      anchors.margins: Style.space(8)
      spacing: Style.space(10)

      Rectangle {
        Layout.preferredWidth: Style.space(52)
        Layout.preferredHeight: Style.space(52)
        radius: Style.cornerRadius > 0 ? Style.space(3) : 0
        color: Qt.rgba(root.teal.r, root.teal.g, root.teal.b, 0.12)
        clip: true
        Label {
          anchors.centerIn: parent
          visible: cover.status !== Image.Ready
          text: sonosCard.hasTrack && sonosCard.track.title === "TV" ? "󰔂" : "󰎇"
          font.family: "Iosevka Nerd Font Propo"
          font.pixelSize: Style.font.iconLarge
          color: root.teal
        }
        Image {
          id: cover
          anchors.fill: parent
          fillMode: Image.PreserveAspectCrop
          asynchronous: true
          source: sonosCard.hasTrack && sonosCard.track.art ? "file://" + sonosCard.track.art : ""
        }
      }

      Column {
        Layout.fillWidth: true
        spacing: Style.space(2)
        Label {
          width: parent.width
          textFormat: Text.PlainText
          elide: Text.ElideRight
          font.bold: true
          text: sonosCard.hasTrack ? sonosCard.track.title : strings.t("sonos.nothing")
        }
        Label {
          width: parent.width
          textFormat: Text.PlainText
          elide: Text.ElideRight
          font.pixelSize: Style.font.caption
          opacity: 0.7
          text: sonosCard.hasTrack && sonosCard.track.artist ? sonosCard.track.artist : ""
          visible: text !== ""
        }
        Label {
          width: parent.width
          textFormat: Text.PlainText
          elide: Text.ElideRight
          font.pixelSize: Style.font.caption
          color: root.teal
          text: root.sonosRoom ? (root.sonosRoom.playing ? strings.t("sonos.playingIn").arg(root.sonosRoom.name)
                                                        : strings.t("sonos.pausedIn").arg(root.sonosRoom.name)) : ""
        }
      }

      Row {
        spacing: Style.space(2)
        Repeater {
          model: [
            { glyph: "󰒮", action: "previous", show: !!root.sonosRoom && root.sonosRoom.canSkip },
            { glyph: root.sonosRoom && root.sonosRoom.playing ? "󰏤" : "󰐊", action: "toggle", show: true },
            { glyph: "󰒭", action: "next", show: !!root.sonosRoom && root.sonosRoom.canSkip }
          ]
          delegate: Rectangle {
            id: transportButton
            required property var modelData
            visible: modelData.show
            width: Style.space(32)
            height: Style.space(32)
            radius: width / 2
            color: buttonHover.hovered ? Qt.rgba(root.teal.r, root.teal.g, root.teal.b, 0.18) : "transparent"
            Label {
              anchors.centerIn: parent
              text: transportButton.modelData.glyph
              font.family: "Iosevka Nerd Font Propo"
              font.pixelSize: Style.font.iconLarge
              color: root.teal
            }
            HoverHandler { id: buttonHover; cursorShape: Qt.PointingHandCursor }
            TapHandler { onTapped: root.act([root.tool, "sonos", transportButton.modelData.action]) }
          }
        }
      }
    }
  }

  // Volume of whichever output is in use (or the Sonos room); it commits on release.
  readonly property var volumeSource: sonosOn ? sonosRoom : current
  ThemedSlider {
    width: parent.width
    visible: !!root.volumeSource
    icon: root.volumeSource && root.volumeSource.muted ? "󰝟" : (root.sonosOn ? "󰜟" : "󰕾")
    label: root.sonosOn ? strings.t("sonos.volume").arg(root.sonosRoom.name) : strings.t("output.volume")
    valueText: root.volumeSource && root.volumeSource.muted ? strings.t("output.muted")
      : strings.t("percent").arg(Commons.I18n.formatNumber(Math.round(liveValue)))
    value: root.volumeSource && root.volumeSource.volume !== null ? root.volumeSource.volume : 0
    minimum: 0
    maximum: 100
    step: 5
    fromColor: root.amber
    toColor: root.teal
    onCommitted: function(v) {
      root.act(root.sonosOn ? [root.tool, "sonos", "volume", String(Math.round(v))]
                            : ["pactl", "set-sink-volume", "@DEFAULT_SINK@", Math.round(v) + "%"])
    }
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
      visible: !!root.volumeSource
      icon: "󰝟"
      title: strings.t("output.mute")
      detail: root.volumeSource && root.volumeSource.muted ? strings.t("output.muteOn") : strings.t("output.muteOff")
      checked: !!root.volumeSource && root.volumeSource.muted
      amber: root.amber; teal: root.teal
      onToggled: root.act(root.sonosOn ? [root.tool, "sonos", "volume", "mute-toggle"]
                                       : ["pactl", "set-sink-mute", "@DEFAULT_SINK@", "toggle"])
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
      visible: root.tuning.available && !root.sonosOn && !!root.current && root.current.kind === "speaker"
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
