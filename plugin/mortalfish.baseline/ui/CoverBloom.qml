import QtQuick
import QtQuick.Effects
import QtQuick.Shapes
import qs.Commons

// The new song's cover blooming in over the old one through a mix: a soft
// circle of it spreading from the bottom-right corner, surging forward on
// each bar's downbeat and settling between, until it covers the square on
// the mix's last bar. The picture itself stretches out with it, from the
// corner card's size to the full square, so the card seems to open up into
// the cover. Runs off the wall clock and the mix's own times.
Item {
  id: bloom
  // The picture to bloom in (the new song's cover), given as the child.
  default property alias content: body.data
  property real size: 176
  property real startMs: 0             // the mix: when it starts and ends (wall clock, ms)
  property real endMs: 0
  property int bars: 16
  property real from: 0.42             // how far it has spread when the mix starts (of the side)
  property real card: 0.36              // the picture's size when it starts (the corner card's)
  readonly property bool running: endMs > startMs

  // How far it has spread, 0-1: a step on each bar, eased in over the bar's first beat.
  function spread() {
    const p = Math.max(0, Math.min(1, (Date.now() - startMs) / (endMs - startMs)))
    const n = Math.max(1, bars), f = p * n, i = Math.floor(f), k = Math.min(1, (f - i) / 0.25)
    const step = 1 - Math.pow(1 - k, 3)
    return Math.min(1, (i + step) / n)
  }

  // The picture stays "visible" (a hidden item's own effects, like a cover's
  // rounded corners, never draw), drawn only through the texture below.
  Item {
    id: picture
    anchors.fill: parent
    Item {
      id: body
      width: parent.width; height: parent.height
      transformOrigin: Item.BottomRight
    }
  }
  // The mask: a soft-edged disc from the corner. (A Shape, not a Canvas: a
  // hidden Canvas never paints, so it would mask everything away.)
  Shape {
    id: disc
    anchors.fill: parent
    visible: false
    layer.enabled: true
    preferredRendererType: Shape.CurveRenderer
    property real reach: 0
    ShapePath {
      strokeWidth: -1
      fillGradient: RadialGradient {
        centerX: disc.width; centerY: disc.height; centerRadius: Math.max(1, disc.reach)
        focalX: disc.width; focalY: disc.height; focalRadius: 0
        GradientStop { position: 0; color: "white" }
        GradientStop { position: 0.6; color: "white" }
        GradientStop { position: 1; color: "transparent" }
      }
      startX: 0; startY: 0
      PathLine { x: disc.width; y: 0 }
      PathLine { x: disc.width; y: disc.height }
      PathLine { x: 0; y: disc.height }
      PathLine { x: 0; y: 0 }
    }
  }
  FrameAnimation {
    running: bloom.visible && bloom.running
    onTriggered: {
      const s = bloom.spread()
      // From a corner card's worth until even its soft edge (the outer 40%) is past the far corner,
      // slow at first, so the old cover has gone only by the last bar or two.
      disc.reach = bloom.size * (bloom.from + (2.45 - bloom.from) * Math.pow(s, 1.6))
      // The picture: from the corner card's size, stretching out to the full square
      // a little ahead of the circle, so it has settled by the time it covers.
      const g = Math.min(1, s * 1.35)
      body.scale = bloom.card + (1 - bloom.card) * (1 - Math.pow(1 - g, 2))
    }
  }
  ShaderEffectSource {
    id: pictureTexture
    anchors.fill: parent
    sourceItem: picture
    hideSource: true
    live: true
    visible: false
  }
  MultiEffect {
    anchors.fill: parent
    source: pictureTexture
    maskEnabled: true
    maskSource: disc
    maskThresholdMin: 0.5
    maskSpreadAtMin: 1.0
  }
}
