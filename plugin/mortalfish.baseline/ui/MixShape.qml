import QtQuick
import qs.Commons
import qs.Commons as Commons

// A mix, drawn: two lanes, the bass (kick and bass line) and the melody
// (everything above it), each with the song going out (amber) and the one
// coming in (teal) as filled curves, so you can see what hands over when.
// A tick marks the takeover (the bass swap); a playhead shows where a mix is.
Item {
  id: shape
  property var curves: null            // {a: {bass, top}, b: {bass, top}}, each 0-1, sampled evenly
  property real swap: -1               // 0-1: when the new song's bass takes over
  property real playhead: -1           // 0-1 while a mix is under way
  property color outColor: Commons.Color.accent
  property color inColor: Commons.Color.foreground
  property color ink: Commons.Color.popups.text
  property bool labels: true
  property string bassLabel: "BASS"
  property string topLabel: "MELODY"
  readonly property real gutter: labels ? 58 : 0
  implicitHeight: 64

  onCurvesChanged: lanes.requestPaint()
  onWidthChanged: lanes.requestPaint()
  onHeightChanged: lanes.requestPaint()
  onOutColorChanged: lanes.requestPaint()
  onInColorChanged: lanes.requestPaint()

  Text {
    visible: shape.labels
    width: shape.gutter - 12; horizontalAlignment: Text.AlignRight
    y: lanes.y + lanes.height * 0.25 - height / 2
    text: shape.bassLabel
    textFormat: Text.PlainText
    font.family: Style.font.family; font.pixelSize: 9; font.letterSpacing: 1.5
    color: shape.ink; opacity: 0.45
  }
  Text {
    visible: shape.labels
    width: shape.gutter - 12; horizontalAlignment: Text.AlignRight
    y: lanes.y + lanes.height * 0.75 - height / 2
    text: shape.topLabel
    textFormat: Text.PlainText
    font.family: Style.font.family; font.pixelSize: 9; font.letterSpacing: 1.5
    color: shape.ink; opacity: 0.45
  }

  Canvas {
    id: lanes
    x: shape.gutter
    width: shape.width - shape.gutter
    height: shape.height
    renderStrategy: Canvas.Cooperative
    onPaint: {
      const g = getContext("2d")
      g.reset()
      const c = shape.curves
      const lane = height / 2
      // Hairlines under each lane.
      g.fillStyle = Qt.rgba(shape.ink.r, shape.ink.g, shape.ink.b, 0.12)
      g.fillRect(0, lane - 1, width, 1)
      g.fillRect(0, height - 1, width, 1)
      if (!c || !c.a || !c.b) return
      const draw = (values, top, color) => {
        if (!values || values.length < 2) return
        const h = lane - 4
        g.beginPath()
        g.moveTo(0, top + lane - 1)
        for (let i = 0; i < values.length; i += 1)
          g.lineTo(i / (values.length - 1) * width, top + lane - 1 - Math.max(0, Math.min(1, values[i])) * h)
        g.lineTo(width, top + lane - 1)
        g.closePath()
        g.fillStyle = Qt.rgba(color.r, color.g, color.b, 0.28)
        g.fill()
        g.beginPath()
        for (let i = 0; i < values.length; i += 1) {
          const x = i / (values.length - 1) * width, y = top + lane - 1 - Math.max(0, Math.min(1, values[i])) * h
          if (i === 0) g.moveTo(x, y); else g.lineTo(x, y)
        }
        g.strokeStyle = Qt.rgba(color.r, color.g, color.b, 0.95)
        g.lineWidth = 1.5
        g.stroke()
      }
      draw(c.a.bass, 0, shape.outColor)
      draw(c.b.bass, 0, shape.inColor)
      draw(c.a.top, lane, shape.outColor)
      draw(c.b.top, lane, shape.inColor)
    }
  }
  // The takeover: where the new song's bass comes in.
  Rectangle {
    visible: shape.swap >= 0 && !!shape.curves
    x: lanes.x + lanes.width * shape.swap - 0.5
    width: 1; height: shape.height
    color: Qt.rgba(shape.ink.r, shape.ink.g, shape.ink.b, 0.35)
  }
  // Where the mix is now.
  Rectangle {
    visible: shape.playhead >= 0 && !!shape.curves
    x: lanes.x + lanes.width * Math.max(0, Math.min(1, shape.playhead)) - 1
    width: 2; height: shape.height
    radius: 1
    color: shape.ink
    Behavior on x { NumberAnimation { duration: Style.duration(240); easing.type: Easing.OutCubic } }
  }
}
