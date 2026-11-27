import QtQuick
import qs.Commons
import qs.Commons as Commons

// Fills a PopupCard inside its border, so the card reads near-solid however
// see-through the shell's popups are set.
Rectangle {
  property int pad: 0
  anchors.fill: parent
  anchors.margins: -pad
  radius: Math.max(0, Style.cornerRadius - 2)
  color: Qt.rgba(Commons.Color.popups.background.r, Commons.Color.popups.background.g,
                 Commons.Color.popups.background.b, 1.0)
}
