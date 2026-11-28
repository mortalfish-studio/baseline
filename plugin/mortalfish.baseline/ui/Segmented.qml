import QtQuick
import qs.Commons
import qs.Commons as Commons

// One choice out of a few, as a single control: the segments sit in one
// rounded track and a lit pill slides to the one chosen. `model` is a list
// of {key, label, glyph?}; `hoveredKey` says which one is under the pointer.
Item {
  id: seg
  property var model: []
  property string current: ""
  property color tone: Commons.Color.accent
  property color ink: Commons.Color.popups.text
  property bool dim: false                 // the whole choice is off for now (still pickable)
  property string hoveredKey: ""
  signal picked(string key)
  implicitWidth: track.implicitWidth
  implicitHeight: 32
  opacity: dim ? 0.5 : 1
  Behavior on opacity { NumberAnimation { duration: Style.duration(180); easing.type: Easing.OutCubic } }

  readonly property int index: {
    for (let i = 0; i < model.length; i += 1) if (model[i].key === current) return i
    return -1
  }

  Rectangle {
    anchors.fill: parent
    radius: height / 2
    color: Qt.rgba(seg.ink.r, seg.ink.g, seg.ink.b, 0.035)
    border.width: 1
    border.color: Qt.rgba(seg.ink.r, seg.ink.g, seg.ink.b, 0.12)
  }
  // The lit pill, sliding to the choice.
  Rectangle {
    id: lit
    // Read again as the segments are made (itemAt alone wouldn't be).
    readonly property Item at: seg.index >= 0 && cells.count > seg.index && track.width > 0 ? cells.itemAt(seg.index) : null
    visible: !!at
    x: at ? track.x + at.x + 2 : 0
    y: 2
    width: at ? at.width - 4 : 0
    height: seg.height - 4
    radius: height / 2
    color: Qt.rgba(seg.tone.r, seg.tone.g, seg.tone.b, 0.2)
    border.width: 1
    border.color: Qt.rgba(seg.tone.r, seg.tone.g, seg.tone.b, 0.85)
    Behavior on x { NumberAnimation { duration: Style.duration(220); easing.type: Easing.OutCubic } }
    Behavior on width { NumberAnimation { duration: Style.duration(220); easing.type: Easing.OutCubic } }
  }
  Row {
    id: track
    height: parent.height
    Repeater {
      id: cells
      model: seg.model
      delegate: Item {
        id: cell
        required property var modelData
        required property int index
        readonly property bool on: index === seg.index
        width: cellRow.implicitWidth + 30
        height: seg.height
        Row {
          id: cellRow
          anchors.centerIn: parent
          spacing: 7
          Text {
            visible: !!cell.modelData.glyph
            anchors.verticalCenter: parent.verticalCenter
            text: cell.modelData.glyph || ""
            textFormat: Text.PlainText
            font.family: "Iosevka Nerd Font Propo"
            font.pixelSize: Style.font.caption + 1
            color: cell.on ? seg.tone : seg.ink
            opacity: cell.on ? 1 : cellHover.hovered ? 0.85 : 0.5
          }
          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: cell.modelData.label
            textFormat: Text.PlainText
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            font.bold: cell.on
            color: seg.ink
            opacity: cell.on ? 1 : cellHover.hovered ? 0.95 : 0.62
          }
        }
        // Hairline between two unlit neighbours.
        Rectangle {
          visible: cell.index > 0 && !cell.on && cell.index - 1 !== seg.index
          anchors.verticalCenter: parent.verticalCenter
          width: 1; height: 14
          color: Qt.rgba(seg.ink.r, seg.ink.g, seg.ink.b, 0.12)
        }
        HoverHandler {
          id: cellHover
          cursorShape: Qt.PointingHandCursor
          onHoveredChanged: seg.hoveredKey = hovered ? cell.modelData.key : (seg.hoveredKey === cell.modelData.key ? "" : seg.hoveredKey)
        }
        TapHandler { onTapped: seg.picked(cell.modelData.key) }
      }
    }
  }
}
