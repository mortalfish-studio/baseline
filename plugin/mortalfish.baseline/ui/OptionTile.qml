import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Commons as Commons

// An on/off tile: an icon that lights amber when on, a title and a line on
// what it does. The whole tile is the switch.
Rectangle {
  id: tile
  property string icon: ""
  property string title: ""
  property string detail: ""
  property bool checked: false
  property bool wrap: false        // let the detail run onto more lines
  property color amber: Commons.Color.accent
  property color teal: Commons.Color.foreground
  signal toggled()

  implicitHeight: row.implicitHeight + Style.space(12)
  radius: Style.cornerRadius > 0 ? Style.space(4) : 0
  color: checked ? Qt.rgba(amber.r, amber.g, amber.b, hover.hovered ? 0.16 : 0.1)
                 : Qt.rgba(1, 1, 1, hover.hovered ? 0.06 : 0.03)
  border.width: 1
  border.color: checked ? Qt.rgba(amber.r, amber.g, amber.b, 0.55) : Qt.rgba(1, 1, 1, 0.08)
  Behavior on color { ColorAnimation { duration: Style.duration(160) } }

  RowLayout {
    id: row
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    anchors.leftMargin: Style.space(8)
    anchors.rightMargin: Style.space(8)
    spacing: Style.space(8)

    Label {
      text: tile.icon
      font.family: "Iosevka Nerd Font Propo"
      font.pixelSize: Style.font.iconLarge
      color: tile.checked ? tile.amber : Commons.Color.popups.text
      opacity: tile.checked ? 1 : 0.45
    }
    ColumnLayout {
      Layout.fillWidth: true
      spacing: 0
      Label { Layout.fillWidth: true; text: tile.title; opacity: tile.checked ? 1 : 0.7 }
      Label {
        Layout.fillWidth: true
        visible: tile.detail !== ""
        text: tile.detail
        wrapMode: tile.wrap ? Text.Wrap : Text.NoWrap
        font.pixelSize: Style.font.caption
        opacity: 0.55
      }
    }
    // A small indicator lamp: amber on, hollow off.
    Rectangle {
      width: Style.space(8)
      height: width
      radius: width / 2
      color: tile.checked ? tile.amber : "transparent"
      border.width: 1
      border.color: tile.checked ? tile.amber : Qt.rgba(1, 1, 1, 0.3)
    }
  }

  HoverHandler { id: hover; cursorShape: Qt.PointingHandCursor }
  TapHandler { onTapped: tile.toggled() }
}
