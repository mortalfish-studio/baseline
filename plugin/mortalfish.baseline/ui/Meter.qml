import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Commons as Commons

// A gauge line: name, a thin bar lit teal (fine), amber (nearing its limit) or
// red (past it), a tick at the limit, and the reading.
RowLayout {
  id: meter
  property string name: ""
  property real value: -1        // 0..100 on the bar
  property real limit: -1        // where the tick sits; -1 for none
  property bool low: false       // the limit is a floor (battery, disk free)
  property string reading: ""
  property string detail: ""
  property bool alarm: false
  property color teal: Commons.Color.foreground
  property color amber: Commons.Color.accent
  property color red: Commons.Color.urgent
  property real nameWidth: Style.space(38)
  readonly property bool near: limit >= 0 && !alarm && (low ? value <= limit * 2 : value >= limit * 0.75)
  readonly property color tone: alarm ? red : near ? amber : teal
  spacing: Style.space(8)
  visible: value >= 0

  Label {
    Layout.preferredWidth: meter.nameWidth
    text: meter.name
    font.pixelSize: Style.font.caption
    font.letterSpacing: Style.space(1)
    opacity: 0.75
  }
  Item {
    Layout.fillWidth: true
    Layout.preferredHeight: Style.space(8)
    Rectangle {
      anchors.verticalCenter: parent.verticalCenter
      width: parent.width
      height: Style.space(3)
      color: Qt.rgba(1, 1, 1, 0.08)
    }
    Rectangle {
      anchors.verticalCenter: parent.verticalCenter
      width: parent.width * Math.max(0, Math.min(100, meter.value)) / 100
      height: Style.space(3)
      color: meter.tone
      Behavior on width { NumberAnimation { duration: Style.duration(240); easing.type: Easing.OutCubic } }
      Behavior on color { ColorAnimation { duration: Style.duration(240) } }
    }
    Rectangle {
      visible: meter.limit >= 0
      x: parent.width * Math.max(0, Math.min(100, meter.limit)) / 100 - width / 2
      anchors.verticalCenter: parent.verticalCenter
      width: Math.max(1, Style.space(1))
      height: parent.height
      color: Commons.Color.popups.text
      opacity: 0.45
    }
  }
  Label {
    visible: meter.detail !== ""
    text: meter.detail
    font.pixelSize: Style.font.caption
    opacity: 0.55
  }
  Label {
    Layout.preferredWidth: Style.space(44)
    horizontalAlignment: Text.AlignRight
    text: meter.reading
    font.pixelSize: Style.font.caption
    font.bold: meter.alarm
    color: meter.alarm ? meter.red : Commons.Color.popups.text
  }
}
