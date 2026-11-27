import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import qs.Commons

// The Deck's equalizer, "the Skyline": bars from the look's accent (bass) to
// its cyan (treble), peak caps that hang and fall, a neon glow, a reflection on
// the floor and faint scanlines. With `live` it shows the laptop's real sound
// (cava, reading PipeWire's output); otherwise (a Sonos room, or no cava) a
// pulse that moves like music. Resting, it breathes. It does nothing at all
// while `active` is false.
Item {
  id: viz
  property bool active: false       // on screen
  property bool playing: false
  property bool live: false         // the sound is on this laptop
  property color amber: "#ff5aa5"
  property color teal: "#62b6ff"
  property color ground: "#130c15"
  readonly property int count: 28
  readonly property real floorY: Math.round(height * 0.72)

  property var levels: []
  property var peaks: []
  property var holds: []
  property bool haveCava: false
  readonly property bool listening: active && playing && live && haveCava

  function blank() { const a = []; for (let i = 0; i < count; i++) a.push(0); return a }
  Component.onCompleted: { levels = blank(); peaks = blank(); holds = blank(); probe.running = true }

  // Is cava there?
  Process {
    id: probe
    command: ["sh", "-c", "command -v cava"]
    onExited: function(code) { viz.haveCava = code === 0 }
  }
  Process {
    id: cava
    running: viz.listening
    command: ["cava", "-p", String(Qt.resolvedUrl("cava.conf")).replace(/^file:\/\//, "")]
    stdout: SplitParser {
      onRead: function(line) {
        const parts = line.split(";")
        if (parts.length < viz.count) return
        const next = []
        for (let i = 0; i < viz.count; i++) next.push(Math.max(0, Math.min(1, (parseInt(parts[i]) || 0) / 100)))
        viz.take(next)
      }
    }
  }

  // Peaks hang for a moment, then fall at a steady pace.
  function take(next) {
    const p = peaks.slice(), h = holds.slice()
    for (let i = 0; i < count; i++) {
      if (next[i] >= p[i]) { p[i] = next[i]; h[i] = 14 }
      else if (h[i] > 0) h[i]--
      else p[i] = Math.max(next[i], p[i] - 0.018)
    }
    peaks = p; holds = h; levels = next
  }

  // Without the real sound: a pulse with a beat, a bass-heavy shape and some
  // wander; resting, a slow wave.
  property real phase: 0
  property var wander: []
  Timer {
    interval: 33
    repeat: true
    running: viz.active && !viz.listening
    onTriggered: {
      viz.phase += 0.033
      const t = viz.phase
      const next = []
      if (!viz.wander.length) { const w = []; for (let i = 0; i < viz.count; i++) w.push(Math.random()); viz.wander = w }
      const w = viz.wander.slice()
      for (let i = 0; i < viz.count; i++) {
        const x = i / (viz.count - 1)
        if (viz.playing) {
          w[i] = Math.max(0, Math.min(1, w[i] + (Math.random() - 0.5) * 0.22))
          const beat = Math.pow(Math.max(0, Math.sin(t * Math.PI * 2 * 2.03)), 6)     // about 122 bpm
          const shape = 0.78 - 0.5 * x + 0.12 * Math.sin(x * 9 + t * 1.7)
          next.push(Math.max(0.04, Math.min(1, shape * (0.45 + 0.35 * w[i]) + beat * (0.4 - 0.3 * x))))
        } else {
          next.push(0.05 + 0.04 * (1 + Math.sin(t * 1.3 + x * 6.3)) / 2)
        }
      }
      viz.wander = w
      // Ease toward it, so the made-up pulse never looks jumpy.
      const eased = []
      for (let i = 0; i < viz.count; i++) eased.push(viz.levels[i] + (next[i] - viz.levels[i]) * (viz.playing ? 0.5 : 0.12))
      viz.take(eased)
    }
  }

  readonly property real gap: 3
  readonly property real barWidth: Math.max(2, (width - gap * (count - 1)) / count)
  function tone(i) { return Qt.tint(amber, Qt.rgba(teal.r, teal.g, teal.b, i / (count - 1))) }

  // ---- the bars, drawn once for the glow and once sharp on top
  Item {
    id: bars
    width: viz.width
    height: viz.floorY
    layer.enabled: true
    Repeater {
      model: viz.count
      delegate: Item {
        required property int index
        x: index * (viz.barWidth + viz.gap)
        width: viz.barWidth
        height: bars.height
        readonly property color c: viz.tone(index)
        Rectangle {
          anchors.bottom: parent.bottom
          width: parent.width
          height: Math.max(2, parent.height * (viz.levels[index] || 0))
          radius: Math.min(2, width / 2)
          gradient: Gradient {
            GradientStop { position: 0; color: Qt.lighter(c, 1.25) }
            GradientStop { position: 1; color: Qt.rgba(c.r, c.g, c.b, 0.35) }
          }
        }
        // The peak cap.
        Rectangle {
          width: parent.width
          height: 2
          radius: 1
          y: parent.height - parent.height * (viz.peaks[index] || 0) - 4
          visible: (viz.peaks[index] || 0) > 0.06
          color: Qt.lighter(c, 1.5)
          opacity: 0.9
        }
      }
    }
  }
  MultiEffect {
    source: bars
    anchors.fill: bars
    z: -1
    blurEnabled: true
    blur: 1.0
    blurMax: 24
    brightness: 0.15
    opacity: viz.playing ? 0.85 : 0.4
    Behavior on opacity { NumberAnimation { duration: Style.duration(240) } }
  }

  // ---- the floor and the reflection on it
  Rectangle {
    y: viz.floorY + 1
    width: viz.width
    height: 1
    gradient: Gradient {
      orientation: Gradient.Horizontal
      GradientStop { position: 0; color: Qt.rgba(viz.amber.r, viz.amber.g, viz.amber.b, 0.5) }
      GradientStop { position: 1; color: Qt.rgba(viz.teal.r, viz.teal.g, viz.teal.b, 0.5) }
    }
  }
  ShaderEffectSource {
    id: mirror
    sourceItem: bars
    y: viz.floorY + 3
    width: viz.width
    height: viz.height - viz.floorY - 3
    sourceRect: Qt.rect(0, viz.floorY - height, viz.width, height)
    transform: Scale { yScale: -1; origin.y: mirror.height / 2 }
    opacity: 0.28
  }
  // The reflection fades into the ground.
  Rectangle {
    y: viz.floorY + 3
    width: viz.width
    height: viz.height - viz.floorY - 3
    gradient: Gradient {
      GradientStop { position: 0; color: Qt.rgba(viz.ground.r, viz.ground.g, viz.ground.b, 0) }
      GradientStop { position: 1; color: viz.ground }
    }
  }

  // ---- scanlines over everything, very faint
  Column {
    anchors.fill: parent
    spacing: 3
    clip: true
    Repeater {
      model: Math.ceil(viz.height / 4)
      delegate: Rectangle { width: viz.width; height: 1; color: viz.ground; opacity: 0.35 }
    }
  }
}
