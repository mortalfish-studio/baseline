import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Commons as Commons

// An outlined action in the theme: amber edge and text, filling faintly on hover.
Rectangle {
  id: action
  property string icon: ""
  property string text: ""
  property color tone: Commons.Color.accent
  property bool enabled: true
  signal clicked()
  implicitWidth: row.implicitWidth + Style.space(16)
  implicitHeight: row.implicitHeight + Style.space(9)
  radius: Style.cornerRadius > 0 ? Style.space(3) : 0
  color: hover.hovered && enabled ? Qt.rgba(tone.r, tone.g, tone.b, 0.14) : "transparent"
  border.width: 1
  border.color: Qt.rgba(tone.r, tone.g, tone.b, enabled ? 0.7 : 0.25)
  opacity: enabled ? 1 : 0.5
  Behavior on color { ColorAnimation { duration: Style.duration(140) } }

  RowLayout {
    id: row
    anchors.centerIn: parent
    spacing: Style.space(6)
    Label { visible: action.icon !== ""; text: action.icon; color: action.tone; font.family: "Iosevka Nerd Font Propo" }
    Label {
      visible: action.text !== ""
      text: action.text.toUpperCase()
      color: action.tone
      font.pixelSize: Style.font.caption
      font.letterSpacing: Style.space(1)
    }
  }
  HoverHandler { id: hover; cursorShape: action.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor }
  TapHandler { enabled: action.enabled; onTapped: action.clicked() }
}
