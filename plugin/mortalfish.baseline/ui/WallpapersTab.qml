import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Every wallpaper in the current look, with which periods may use it: Day lights amber,
// Night lights teal. Click a picture to put it up now; Night uses its
// darkened copy. Below, ways to add more.
Column {
  id: root
  property var host: null
  spacing: Style.space(18)

  readonly property var st: host ? host.afterState : null
  readonly property var items: st ? st.wallpapers : []
  readonly property int cycle: st ? st.settings.wallpapers.cycleMinutes : 0
  readonly property color amber: Commons.Color.accent
  readonly property color teal: host ? host.themeCyan : Commons.Color.foreground

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("../i18n") }

  Label { visible: !root.st; text: strings.t("wall.loading") }

  // A small lit chip: Day in amber, Night in teal.
  component PeriodChip: Rectangle {
    id: chip
    property string glyph: ""
    property string text: ""
    property bool on: false
    property color tone: root.amber
    signal clicked()
    implicitWidth: chipRow.implicitWidth + Style.space(10)
    implicitHeight: chipRow.implicitHeight + Style.space(4)
    radius: Style.space(3)
    color: on ? Qt.rgba(tone.r, tone.g, tone.b, chipHover.hovered ? 0.3 : 0.2) : (chipHover.hovered ? Qt.rgba(1, 1, 1, 0.06) : "transparent")
    border.width: 1
    border.color: on ? tone : Qt.rgba(1, 1, 1, 0.15)
    Row {
      id: chipRow
      anchors.centerIn: parent
      spacing: Style.space(3)
      Label { text: chip.glyph; font.family: "Iosevka Nerd Font Propo"; font.pixelSize: Style.font.caption; color: chip.on ? chip.tone : Commons.Color.popups.text; opacity: chip.on ? 1 : 0.5 }
      Label { text: chip.text; font.pixelSize: Style.font.caption; color: chip.on ? chip.tone : Commons.Color.popups.text; opacity: chip.on ? 1 : 0.5 }
    }
    HoverHandler { id: chipHover; cursorShape: Qt.PointingHandCursor }
    TapHandler { onTapped: chip.clicked() }
  }

  // ======================================================== Library
  Column {
    width: parent.width
    spacing: Style.space(8)
    visible: !!root.st

    RowLayout {
      width: parent.width
      spacing: Style.space(8)
      Section {
        Layout.fillWidth: true
        title: {
          const st = root.host ? root.host.afterState : null
          const look = st && st.looks ? st.looks.find(l => l.id === st.look) : null
          return strings.t("wall.library").arg(look ? look.name : "").arg(Commons.I18n.formatNumber(root.items.length))
        }
        amber: root.amber
        teal: root.teal
      }
      // Every picture across every look, and adding more: the Studio.
      ActionButton { icon: "󰉏"; text: strings.t("studio.open"); tone: root.teal; onClicked: root.host.openStudio("library") }
    }

    // Plain black instead of a picture, in every mode, until one is clicked.
    OptionTile {
      width: parent.width
      icon: "󰸉"
      title: strings.t("wall.black")
      detail: strings.t(checked ? "wall.blackOn" : "wall.blackOff")
      checked: !!root.st && !!root.st.settings.wallpapers.black
      amber: root.amber; teal: root.teal
      onToggled: root.host.afterlight(["wallpaper", "black", checked ? "off" : "on"])
    }

    RowLayout {
      width: parent.width
      spacing: Style.space(5)
      Label { text: "󰑓"; color: root.teal }
      Label { text: strings.t("wall.cycle"); font.pixelSize: Style.font.caption; opacity: 0.75 }
      Repeater {
        model: [
          { value: 0, label: strings.t("wall.cycleOff") },
          { value: 15, label: strings.t("wall.cycleShort").arg(Commons.I18n.formatNumber(15)) },
          { value: 30, label: strings.t("wall.cycleShort").arg(Commons.I18n.formatNumber(30)) },
          { value: 60, label: strings.t("wall.cycleHour") },
          { value: 120, label: strings.t("wall.cycleHours").arg(Commons.I18n.formatNumber(2)) }
        ]
        delegate: PeriodChip {
          required property var modelData
          text: modelData.label
          tone: root.teal
          on: root.cycle === modelData.value
          onClicked: root.host.afterlight(["set", "wallpapers.cycleMinutes", String(modelData.value)])
        }
      }
      Item { Layout.fillWidth: true }
      ActionButton {
        icon: "󰒭"
        text: strings.t("wall.next")
        onClicked: root.host.afterlight(["wallpaper", "next"])
      }
    }

    Flickable {
      width: parent.width
      height: Math.min(grid.implicitHeight, Style.space(500))
      contentHeight: grid.implicitHeight
      clip: true
      boundsBehavior: Flickable.StopAtBounds

      Grid {
        id: grid
        width: parent.width
        columns: 3
        spacing: Style.space(8)
        readonly property real cell: (width - spacing * (columns - 1)) / columns

        Repeater {
          model: root.items

          delegate: Column {
            id: tile
            required property var modelData
            readonly property bool current: root.st && root.st.currentWallpaper === modelData.id
            readonly property bool used: modelData.day || modelData.night
            width: grid.cell
            spacing: Style.space(4)

            // The picture, framed amber-to-teal when it's the one on screen.
            Rectangle {
              width: parent.width
              height: Math.round(width * 0.62)
              gradient: Gradient {
                orientation: Gradient.Horizontal
                GradientStop { position: 0; color: tile.current ? root.amber : Qt.rgba(1, 1, 1, hover.hovered ? 0.35 : 0.08) }
                GradientStop { position: 1; color: tile.current ? root.teal : Qt.rgba(1, 1, 1, hover.hovered ? 0.35 : 0.08) }
              }

              Rectangle {
                anchors.fill: parent
                anchors.margins: tile.current ? 2 : 1
                color: "black"
                clip: true
                SizedImage {
                  anchors.fill: parent
                  crop: true
                  url: tile.modelData.thumb ? "file://" + tile.modelData.thumb : ""
                  opacity: tile.used ? 1 : 0.3
                }
                // A thin strip along the bottom: amber half for Day, teal for Night.
                Row {
                  anchors.bottom: parent.bottom
                  width: parent.width
                  height: Style.space(3)
                  Rectangle { width: parent.width / 2; height: parent.height; color: root.amber; visible: tile.modelData.day }
                  Rectangle { width: parent.width / 2; height: parent.height; color: "transparent"; visible: !tile.modelData.day }
                  Rectangle { width: parent.width / 2; height: parent.height; color: root.teal; visible: tile.modelData.night }
                }
                Label {
                  visible: tile.modelData.video
                  anchors.right: parent.right
                  anchors.top: parent.top
                  anchors.margins: Style.space(4)
                  text: "󰕧"
                  color: "white"
                  style: Text.Outline
                  styleColor: "black"
                }
                Label {
                  visible: tile.current
                  anchors.left: parent.left
                  anchors.top: parent.top
                  anchors.margins: Style.space(4)
                  text: strings.t("wall.onScreen")
                  font.pixelSize: Style.font.caption
                  font.letterSpacing: Style.space(1)
                  color: root.amber
                  style: Text.Outline
                  styleColor: "black"
                }
              }

              HoverHandler { id: hover; cursorShape: Qt.PointingHandCursor }
              TapHandler { onTapped: root.host.afterlight(["wallpaper", "set", tile.modelData.id]) }
            }

            Label {
              width: parent.width
              text: tile.modelData.name.replace(/^\d+-/, "").replace(/-/g, " ")
              textFormat: Text.PlainText
              elide: Text.ElideRight
              font.pixelSize: Style.font.caption
              color: tile.current ? root.amber : Commons.Color.popups.text
              opacity: tile.current ? 1 : 0.75
            }

            RowLayout {
              width: parent.width
              spacing: Style.space(4)
              PeriodChip {
                Layout.fillWidth: true
                glyph: "󰖨"; text: strings.t("wall.day"); tone: root.amber
                on: tile.modelData.day
                onClicked: root.host.afterlight(["wallpaper", "toggle", tile.modelData.id, "day"])
              }
              PeriodChip {
                Layout.fillWidth: true
                glyph: "󰖔"; text: strings.t("wall.night"); tone: root.teal
                on: tile.modelData.night
                onClicked: root.host.afterlight(["wallpaper", "toggle", tile.modelData.id, "night"])
              }
              PeriodChip {
                visible: tile.modelData.id.indexOf("extra/") === 0
                glyph: "󰩺"; text: ""
                tone: Commons.Color.urgent
                onClicked: root.host.afterlight(["wallpaper", "remove", tile.modelData.id])
              }
            }
          }
        }
      }
    }
  }

  Label {
    width: parent.width
    visible: text !== ""
    wrapMode: Text.WordWrap
    elide: Text.ElideNone
    text: !root.host ? "" : root.host.afterBusy ? strings.t("wall.working") : root.host.afterError
    color: root.host && !root.host.afterBusy ? Commons.Color.urgent : root.teal
    font.pixelSize: Style.font.caption
  }

  // ======================================================== Adding
  Column {
    width: parent.width
    spacing: Style.space(8)
    visible: !!root.st

    Section { width: parent.width; title: strings.t("wall.addTitle"); amber: root.amber; teal: root.teal }

    // Drop a file or link here, paste one, or take a recent download.
    Rectangle {
      width: parent.width
      height: addColumn.implicitHeight + Style.space(20)
      radius: Style.cornerRadius > 0 ? Style.space(4) : 0
      color: drop.containsDrag ? Qt.rgba(root.teal.r, root.teal.g, root.teal.b, 0.1) : Qt.rgba(1, 1, 1, 0.025)
      Behavior on color { ColorAnimation { duration: Style.duration(140) } }
      border.width: 1
      border.color: drop.containsDrag ? root.teal : Qt.rgba(1, 1, 1, 0.12)

      DropArea {
        id: drop
        anchors.fill: parent
        keys: ["text/uri-list", "text/plain"]
        onDropped: function(event) {
          const sources = []
          for (const url of event.urls || []) sources.push(String(url))
          if (sources.length === 0 && event.hasText) {
            const text = event.text.trim()
            if (/^(https:|file:|\/)/.test(text)) sources.push(text.split("\n")[0].trim())
          }
          if (sources.length > 0) {
            root.host.afterlight(["wallpaper", "add"].concat(sources.slice(0, 12)))
            event.accept()
          }
        }
      }

      Column {
        id: addColumn
        x: Style.space(10)
        y: Style.space(10)
        width: parent.width - Style.space(20)
        spacing: Style.space(8)

        RowLayout {
          width: parent.width
          spacing: Style.space(8)
          Label { text: "󰉍"; color: root.teal; font.pixelSize: Style.font.icon }
          Label {
            Layout.fillWidth: true
            text: strings.t(drop.containsDrag ? "wall.dropNow" : "wall.dropHere")
            color: drop.containsDrag ? root.teal : Commons.Color.popups.text
          }
          ActionButton {
            icon: "󰆒"
            text: strings.t("wall.paste")
            onClicked: root.host.afterlight(["wallpaper", "paste"])
          }
          ActionButton {
            icon: "󰉋"
            tone: Commons.Color.popups.text
            onClicked: {
              root.host.close()
              Quickshell.execDetached(["xdg-open", root.st.extraFolder])
            }
          }
        }

        Label {
          width: parent.width
          wrapMode: Text.WordWrap
          elide: Text.ElideNone
          opacity: 0.6
          font.pixelSize: Style.font.caption
          text: strings.t("wall.addHint")
        }

        Label {
          visible: !!root.st && root.st.recent.length > 0
          text: strings.t("wall.recent").toUpperCase()
          font.pixelSize: Style.font.caption
          font.letterSpacing: Style.space(2)
          color: root.amber
        }

        Flow {
          width: parent.width
          spacing: Style.space(6)
          visible: !!root.st && root.st.recent.length > 0

          Repeater {
            model: root.st ? root.st.recent : []
            delegate: Rectangle {
              id: recentTile
              required property var modelData
              width: Style.space(92)
              height: Style.space(58)
              radius: Style.cornerRadius > 0 ? Style.space(3) : 0
              color: "black"
              border.width: 1
              border.color: recentHover.hovered ? root.amber : Qt.rgba(1, 1, 1, 0.12)
              clip: true

              SizedImage {
                anchors.fill: parent
                anchors.margins: 1
                crop: true
                url: recentTile.modelData.thumb ? "file://" + recentTile.modelData.thumb : ""
              }
              Label {
                anchors.centerIn: parent
                visible: recentHover.hovered
                text: "󰐕"
                font.pixelSize: Style.font.icon * 1.4
                color: root.amber
                style: Text.Outline
                styleColor: "black"
              }
              HoverHandler { id: recentHover; cursorShape: Qt.PointingHandCursor }
              TapHandler { onTapped: root.host.afterlight(["wallpaper", "add", recentTile.modelData.path]) }
              PanelToolTip { visible: recentHover.hovered; text: recentTile.modelData.name }
            }
          }
        }
      }
    }
  }
}
