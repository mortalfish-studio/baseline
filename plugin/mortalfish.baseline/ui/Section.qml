import QtQuick
import qs.Commons
import qs.Commons as Commons

// A section title in the hover card's style: spaced capitals in amber over a
// hairline that fades from amber to teal.
Column {
  id: section
  property string title: ""
  property color amber: Commons.Color.accent
  property color teal: Commons.Color.foreground
  spacing: Style.space(3)

  Label {
    text: section.title.toUpperCase()
    font.pixelSize: Style.font.caption
    font.letterSpacing: Style.space(3)
    color: section.amber
  }
  Rectangle {
    width: parent.width
    height: 1
    gradient: Gradient {
      orientation: Gradient.Horizontal
      GradientStop { position: 0; color: section.amber }
      GradientStop { position: 1; color: Qt.rgba(section.teal.r, section.teal.g, section.teal.b, 0.1) }
    }
  }
}
