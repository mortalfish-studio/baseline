import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Commons as Commons

// One source on the Status tab. The header always shows (icon, title, one
// line of state, an optional count); tapping it opens the body and actions.
// A card that needs you starts open.
//
//   StatusCard {
//     icon: "󰊤"; title: "GitHub"; summary: "2 waiting"; level: "attention"; count: 2
//     StatusRow { ... }                         // body: any items
//     actions: [ ActionButton { ... } ]         // buttons along the bottom
//   }
Rectangle {
  id: card
  property string icon: ""
  property string title: ""
  property string summary: ""
  property string level: "ok"        // "attention" (amber), "ok" (teal), "off" (red), "idle" (plain)
  property int count: 0
  property bool expanded: level === "attention"
  property color amber: Commons.Color.accent
  property color teal: Commons.Color.foreground
  default property alias body: bodyColumn.data
  property alias actions: actionRow.data

  readonly property color tone: level === "attention" ? amber : level === "off" ? Commons.Color.urgent
    : level === "ok" ? teal : Commons.Color.popups.text
  readonly property bool hasBody: bodyColumn.children.length > 0 || actionRow.children.length > 0

  implicitHeight: inner.implicitHeight + Style.space(14)
  radius: Style.cornerRadius > 0 ? Style.space(4) : 0
  color: headerHover.hovered && !expanded ? Qt.rgba(1, 1, 1, 0.05) : Qt.rgba(1, 1, 1, 0.025)
  border.width: 1
  border.color: Qt.rgba(tone.r, tone.g, tone.b, level === "attention" || level === "off" ? 0.5 : 0.18)
  Behavior on color { ColorAnimation { duration: Style.duration(140) } }

  // A lit edge in the card's state colour.
  Rectangle {
    width: Style.space(3)
    height: parent.height - Style.space(10)
    anchors.left: parent.left
    anchors.leftMargin: Style.space(4)
    anchors.verticalCenter: parent.verticalCenter
    radius: width / 2
    color: card.tone
    opacity: card.level === "idle" ? 0.25 : 0.9
  }

  Column {
    id: inner
    x: Style.space(14)
    y: Style.space(7)
    width: parent.width - Style.space(22)
    spacing: Style.space(6)

    // Header
    Item {
      width: parent.width
      height: header.implicitHeight
      RowLayout {
        id: header
        width: parent.width
        spacing: Style.space(8)
        Label {
          text: card.icon
          font.family: "Iosevka Nerd Font Propo"
          font.pixelSize: Style.font.iconLarge
          color: card.tone
          Layout.preferredWidth: Style.font.iconLarge * 1.3
        }
        ColumnLayout {
          Layout.fillWidth: true
          spacing: 0
          Label {
            Layout.fillWidth: true
            text: card.title.toUpperCase()
            font.pixelSize: Style.font.caption
            font.letterSpacing: Style.space(2)
            font.bold: true
            color: card.level === "idle" ? Commons.Color.popups.text : card.tone
          }
          Label {
            Layout.fillWidth: true
            visible: card.summary !== ""
            text: card.summary
            opacity: 0.85
          }
        }
        Rectangle {
          visible: card.count > 0
          implicitWidth: Math.max(implicitHeight, countLabel.implicitWidth + Style.space(10))
          implicitHeight: countLabel.implicitHeight + Style.space(4)
          radius: implicitHeight / 2
          color: Qt.rgba(card.tone.r, card.tone.g, card.tone.b, 0.2)
          border.width: 1
          border.color: card.tone
          Label {
            id: countLabel
            anchors.centerIn: parent
            text: Commons.I18n.formatNumber(card.count)
            font.pixelSize: Style.font.caption
            font.bold: true
            color: card.tone
          }
        }
        Label {
          visible: card.hasBody
          text: card.expanded ? "󰅀" : "󰅂"
          font.family: "Iosevka Nerd Font Propo"
          opacity: headerHover.hovered ? 0.9 : 0.4
        }
      }
      HoverHandler { id: headerHover; cursorShape: card.hasBody ? Qt.PointingHandCursor : Qt.ArrowCursor }
      TapHandler { enabled: card.hasBody; onTapped: card.expanded = !card.expanded }
    }

    Column {
      id: bodyColumn
      width: parent.width
      spacing: Style.space(3)
      visible: card.expanded && children.length > 0
    }

    Flow {
      id: actionRow
      width: parent.width
      spacing: Style.space(8)
      visible: card.expanded && children.length > 0
    }
  }
}
