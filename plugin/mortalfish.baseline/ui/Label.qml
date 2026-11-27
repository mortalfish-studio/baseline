import QtQuick
import qs.Commons
import qs.Commons as Commons

// Plain text in the popup's colours. Plain, so nothing read from a file or a
// player is ever treated as markup.
Text {
  textFormat: Text.PlainText
  color: Commons.Color.popups.text
  font.family: Style.font.family
  font.pixelSize: Style.font.body
  elide: Text.ElideRight
}
