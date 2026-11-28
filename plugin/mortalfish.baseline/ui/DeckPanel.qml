import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Commons as Commons

// A Deck panel that opens under the controls (Mix, Auto-DJ, Shape): a lit
// badge, a title with a line saying what it does, an on/off switch when it
// has one, and its rows below. It eases in as it opens.
Rectangle {
  id: panel
  property string glyph: ""
  property string title: ""
  property string subtitle: ""
  property color tone: Commons.Color.accent
  property color ink: Commons.Color.popups.text
  property bool switchable: false
  property bool on: false
  property bool open: false
  signal toggled()
  signal closed()
  default property alias content: body.data
  // A label column all rows share, so the controls line up.
  readonly property int labelWidth: 150

  // Opens with a short ease (it closes at once: a panel is put away often).
  visible: open
  opacity: open ? 1 : 0
  scale: open ? 1 : 0.985
  transformOrigin: Item.Top
  Behavior on opacity { NumberAnimation { duration: Style.duration(180); easing.type: Easing.OutCubic } }
  Behavior on scale { NumberAnimation { duration: Style.duration(180); easing.type: Easing.OutCubic } }

  implicitHeight: column.implicitHeight + 2
  radius: Style.cornerRadius > 0 ? 12 : 0
  clip: true
  gradient: Gradient {
    GradientStop { position: 0; color: Qt.rgba(panel.tone.r, panel.tone.g, panel.tone.b, 0.075) }
    GradientStop { position: 0.45; color: Qt.rgba(panel.ink.r, panel.ink.g, panel.ink.b, 0.02) }
    GradientStop { position: 1; color: Qt.rgba(panel.ink.r, panel.ink.g, panel.ink.b, 0.015) }
  }
  border.width: 1
  border.color: Qt.rgba(panel.tone.r, panel.tone.g, panel.tone.b, 0.28)

  ColumnLayout {
    id: column
    x: 1; y: 1
    width: parent.width - 2
    spacing: 0
    // ---- The head
    RowLayout {
      Layout.fillWidth: true
      Layout.leftMargin: 20; Layout.rightMargin: 14
      Layout.topMargin: 16; Layout.bottomMargin: 14
      spacing: 14
      Rectangle {
        Layout.alignment: Qt.AlignTop
        implicitWidth: 34; implicitHeight: 34
        radius: 17
        color: Qt.rgba(panel.tone.r, panel.tone.g, panel.tone.b, panel.on || !panel.switchable ? 0.18 : 0.07)
        border.width: 1
        border.color: Qt.rgba(panel.tone.r, panel.tone.g, panel.tone.b, panel.on || !panel.switchable ? 0.6 : 0.25)
        Behavior on color { ColorAnimation { duration: Style.duration(180) } }
        Text {
          anchors.centerIn: parent
          text: panel.glyph
          textFormat: Text.PlainText
          font.family: "Iosevka Nerd Font Propo"
          font.pixelSize: Style.font.body + 1
          color: panel.tone
          opacity: panel.on || !panel.switchable ? 1 : 0.6
        }
      }
      ColumnLayout {
        Layout.fillWidth: true
        spacing: 3
        Text {
          text: panel.title.toUpperCase()
          textFormat: Text.PlainText
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          font.letterSpacing: 2.5
          font.bold: true
          color: panel.ink
        }
        Text {
          Layout.fillWidth: true
          visible: text !== ""
          text: panel.subtitle
          textFormat: Text.PlainText
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          color: panel.ink
          opacity: 0.55
          wrapMode: Text.Wrap
        }
      }
      OnOff {
        visible: panel.switchable
        Layout.alignment: Qt.AlignVCenter
        on: panel.on
        tone: panel.tone
        ink: panel.ink
        onToggled: panel.toggled()
      }
      // Close.
      Rectangle {
        Layout.alignment: Qt.AlignVCenter
        Layout.leftMargin: 4
        implicitWidth: 28; implicitHeight: 28
        radius: 14
        color: closeHover.hovered ? Qt.rgba(panel.ink.r, panel.ink.g, panel.ink.b, 0.08) : "transparent"
        Text {
          anchors.centerIn: parent
          text: "󰅖"
          textFormat: Text.PlainText
          font.family: "Iosevka Nerd Font Propo"
          color: panel.ink
          opacity: closeHover.hovered ? 1 : 0.5
        }
        HoverHandler { id: closeHover; cursorShape: Qt.PointingHandCursor }
        TapHandler { onTapped: panel.closed() }
      }
    }
    Rectangle {
      Layout.fillWidth: true
      Layout.leftMargin: 20; Layout.rightMargin: 20
      implicitHeight: 1
      color: Qt.rgba(panel.ink.r, panel.ink.g, panel.ink.b, 0.08)
    }
    // ---- The rows
    ColumnLayout {
      id: body
      Layout.fillWidth: true
      Layout.leftMargin: 20; Layout.rightMargin: 20
      Layout.topMargin: 16; Layout.bottomMargin: 18
      spacing: 14
    }
  }
}
