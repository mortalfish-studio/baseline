import QtQuick
import qs.Commons
import qs.Commons as Commons

// An on/off switch: a pill with a knob that slides across and lights up.
Item {
  id: sw
  property bool on: false
  property color tone: Commons.Color.accent
  property color ink: Commons.Color.popups.text
  signal toggled()
  implicitWidth: 40
  implicitHeight: 22
  Rectangle {
    anchors.fill: parent
    radius: height / 2
    color: sw.on ? Qt.rgba(sw.tone.r, sw.tone.g, sw.tone.b, 0.32) : Qt.rgba(sw.ink.r, sw.ink.g, sw.ink.b, swHover.hovered ? 0.12 : 0.07)
    border.width: 1
    border.color: sw.on ? sw.tone : Qt.rgba(sw.ink.r, sw.ink.g, sw.ink.b, 0.22)
    Behavior on color { ColorAnimation { duration: Style.duration(180) } }
  }
  Rectangle {
    width: sw.height - 8; height: width
    radius: width / 2
    y: 4
    x: sw.on ? sw.width - width - 4 : 4
    color: sw.on ? sw.tone : Qt.rgba(sw.ink.r, sw.ink.g, sw.ink.b, 0.55)
    Behavior on x { NumberAnimation { duration: Style.duration(200); easing.type: Easing.OutCubic } }
    Behavior on color { ColorAnimation { duration: Style.duration(180) } }
  }
  HoverHandler { id: swHover; cursorShape: Qt.PointingHandCursor }
  TapHandler { onTapped: sw.toggled() }
}
