import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Commons as Commons

// One line inside a Status card: an icon, the text, a note on the right
// (a time, a repo). Clickable when something listens to clicked().
Rectangle {
  id: row
  property string icon: ""
  property string text: ""
  property string note: ""
  property color tone: Commons.Color.accent
  property bool dim: false
  property bool clickable: true
  signal clicked()
  width: parent ? parent.width : implicitWidth
  implicitHeight: line.implicitHeight + Style.space(8)
  radius: Style.cornerRadius > 0 ? Style.space(3) : 0
  color: hover.hovered && clickable ? Qt.rgba(1, 1, 1, 0.06) : "transparent"
  opacity: dim ? 0.55 : 1
  RowLayout {
    id: line
    anchors.verticalCenter: parent.verticalCenter
    x: Style.space(4)
    width: parent.width - Style.space(8)
    spacing: Style.space(8)
    Label { text: row.icon; font.family: "Iosevka Nerd Font Propo"; color: row.tone }
    Label { Layout.fillWidth: true; text: row.text }
    Label { visible: row.note !== ""; text: row.note; font.pixelSize: Style.font.caption; opacity: 0.55 }
  }
  HoverHandler { id: hover; cursorShape: row.clickable ? Qt.PointingHandCursor : Qt.ArrowCursor }
  TapHandler { enabled: row.clickable; onTapped: row.clicked() }
}
