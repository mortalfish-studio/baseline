import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Commons as Commons

// A slider whose track shows what it controls: either a gradient across the
// whole range (warm to cool, dark to bright), or an amber-to-teal fill up to
// the value. Commits on release, so a drag runs one change.
ColumnLayout {
  id: slider
  property string icon: ""
  property string label: ""
  property string valueText: ""
  property real value: 0
  property real minimum: 0
  property real maximum: 1
  property real step: 0.05
  property bool rangeGradient: false
  property color fromColor: Commons.Color.accent
  property color toColor: Commons.Color.foreground
  property real liveValue: value
  // Labels take the bright end of a range gradient, which may start at black.
  readonly property color tone: rangeGradient ? toColor : fromColor
  readonly property real fraction: Math.max(0, Math.min(1, (liveValue - minimum) / (maximum - minimum)))
  signal committed(real value)
  signal dragged(real value)
  spacing: Style.space(3)

  onValueChanged: if (!area.pressed) liveValue = value

  RowLayout {
    Layout.fillWidth: true
    visible: slider.label !== "" || slider.valueText !== ""
    spacing: Style.space(6)
    Label { visible: slider.icon !== ""; text: slider.icon; color: slider.tone; font.pixelSize: Style.font.body }
    Label { Layout.fillWidth: true; text: slider.label }
    Label { text: slider.valueText; font.bold: true; color: slider.tone }
  }

  Item {
    Layout.fillWidth: true
    Layout.preferredHeight: Style.space(16)

    // Whole-range gradient, or a faint groove.
    Rectangle {
      id: track
      anchors.verticalCenter: parent.verticalCenter
      width: parent.width
      height: slider.rangeGradient ? Style.space(6) : Style.space(3)
      radius: height / 2
      color: Qt.rgba(1, 1, 1, 0.08)
      gradient: slider.rangeGradient ? rangeFill : null
      Gradient {
        id: rangeFill
        orientation: Gradient.Horizontal
        GradientStop { position: 0; color: slider.fromColor }
        GradientStop { position: 1; color: slider.toColor }
      }
    }
    // Amber-to-teal fill up to the value.
    Rectangle {
      visible: !slider.rangeGradient
      anchors.verticalCenter: parent.verticalCenter
      width: Math.max(height, parent.width * slider.fraction)
      height: Style.space(3)
      radius: height / 2
      gradient: Gradient {
        orientation: Gradient.Horizontal
        GradientStop { position: 0; color: slider.fromColor }
        GradientStop { position: 1; color: slider.toColor }
      }
    }
    // The knob: a lit bar, like a gauge needle.
    Rectangle {
      x: Math.round(parent.width * slider.fraction - width / 2)
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(4)
      height: Style.space(area.pressed || area.containsMouse ? 16 : 13)
      radius: width / 2
      color: Commons.Color.popups.text
      border.width: 1
      border.color: Qt.rgba(0, 0, 0, 0.6)
      Behavior on height { NumberAnimation { duration: Style.duration(120); easing.type: Easing.OutCubic } }
    }

    MouseArea {
      id: area
      anchors.fill: parent
      anchors.margins: -Style.space(4)
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      function valueAt(x) {
        const f = Math.max(0, Math.min(1, (x - Style.space(4)) / (width - Style.space(8))))
        const raw = slider.minimum + f * (slider.maximum - slider.minimum)
        return Math.round(Math.round(raw / slider.step) * slider.step * 1000) / 1000
      }
      onPressed: function(mouse) { slider.liveValue = valueAt(mouse.x); slider.dragged(slider.liveValue) }
      onPositionChanged: function(mouse) {
        if (!pressed) return
        slider.liveValue = valueAt(mouse.x)
        slider.dragged(slider.liveValue)
      }
      onReleased: slider.committed(slider.liveValue)
    }
  }
}
