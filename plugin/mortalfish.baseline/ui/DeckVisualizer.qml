import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons

// The Deck's equalizer, "the Skyline": bars from the look's accent (bass) to
// its cyan (treble), peak caps that hang and fall, a soft halo and a reflection
// on the floor. With `live` it shows the laptop's real sound
// (cava, reading PipeWire's output); in a Sonos room with `mic`, the room's
// sound through the laptop's microphone; otherwise (or with no cava) a pulse
// that moves like music. Resting, it breathes. It does nothing at all
// while `active` is false.
Item {
  id: viz
  property bool active: false       // on screen
  property bool playing: false
  property bool live: false         // the sound is on this laptop
  property bool mic: false          // not live: listen to the room through the microphone
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
  readonly property bool hearing: active && playing && !live && mic && haveCava
  // The real sound can go missing (too quiet to read, or cava stopped): then
  // the made-up pulse takes over, so the bars always show the music's shape.
  property real lastFrame: 0
  property real lastSound: 0
  property bool quiet: false
  property bool restarting: false
  function heard(next) {
    const now = Date.now()
    lastFrame = now
    if (Math.max.apply(null, next) > 0.06) lastSound = now
    if (!quiet) take(next)
  }
  onListeningChanged: { lastFrame = lastSound = Date.now(); quiet = false }
  onHearingChanged: { lastFrame = lastSound = Date.now(); quiet = false }
  Timer {
    interval: 500; repeat: true
    running: viz.listening || viz.hearing
    onTriggered: {
      const now = Date.now()
      viz.quiet = now - viz.lastSound > 2000
      if (now - viz.lastFrame > 3000 && !viz.restarting) {       // cava's stopped: start it again
        viz.restarting = true
        viz.lastFrame = now
        restartDone.start()
      }
    }
  }
  Timer { id: restartDone; interval: 400; onTriggered: viz.restarting = false }

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
    running: viz.listening && !viz.restarting
    command: ["cava", "-p", String(Qt.resolvedUrl("cava.conf")).replace(/^file:\/\//, "")]
    stdout: SplitParser {
      onRead: function(line) {
        const parts = line.split(";")
        if (parts.length < viz.count) return
        const next = []
        for (let i = 0; i < viz.count; i++) next.push(Math.max(0, Math.min(1, (parseInt(parts[i]) || 0) / 100)))
        viz.heard(next)
      }
    }
  }

  Process {
    id: cavaMic
    running: viz.hearing && !viz.restarting
    // The default microphone's PipeWire name goes into the config as it starts.
    command: ["sh", "-c", "src=$(pactl get-default-source) || exit 1; conf=${XDG_RUNTIME_DIR:-/tmp}/baseline-cava-mic.conf; "
              + "sed \"s|@DEFAULT_SOURCE@|$src|\" \"$1\" > \"$conf\" && exec cava -p \"$conf\"", "sh",
              String(Qt.resolvedUrl("cava-mic.conf")).replace(/^file:\/\//, "")]
    stdout: SplitParser {
      onRead: function(line) {
        const parts = line.split(";")
        if (parts.length < viz.count) return
        const next = []
        for (let i = 0; i < viz.count; i++) next.push(Math.max(0, Math.min(1, (parseInt(parts[i]) || 0) / 100)))
        viz.heard(next)
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
    running: viz.active && ((!viz.listening && !viz.hearing) || viz.quiet)
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
          // Resting: a slow, clearly visible swell, higher in the bass.
          next.push(0.1 + 0.08 * (1 - x) + 0.07 * (1 + Math.sin(t * 1.1 + x * 5.5)) / 2)
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

  // ---- the bars: each with a soft halo behind it, a peak cap above it and
  // its reflection below the floor. Drawn plainly (no blur effects), so
  // nothing spills outside the Skyline or sits in front of it.
  clip: true
  Repeater {
    model: viz.count
    delegate: Item {
      required property int index
      readonly property color c: viz.tone(index)
      readonly property real level: viz.levels[index] || 0
      readonly property real barHeight: Math.max(2, (viz.floorY - 8) * level)
      x: index * (viz.barWidth + viz.gap)
      width: viz.barWidth
      height: viz.height
      // The halo: wider, faint, fading upward.
      Rectangle {
        x: -viz.gap
        width: parent.width + viz.gap * 2
        height: parent.barHeight + 10
        y: viz.floorY - height
        radius: 4
        opacity: viz.playing ? 0.35 : 0.15
        gradient: Gradient {
          GradientStop { position: 0; color: Qt.rgba(c.r, c.g, c.b, 0) }
          GradientStop { position: 1; color: Qt.rgba(c.r, c.g, c.b, 0.55) }
        }
      }
      // The bar.
      Rectangle {
        width: parent.width
        height: parent.barHeight
        y: viz.floorY - height
        radius: Math.min(2, width / 2)
        gradient: Gradient {
          GradientStop { position: 0; color: Qt.lighter(c, 1.25) }
          GradientStop { position: 1; color: Qt.rgba(c.r, c.g, c.b, 0.45) }
        }
      }
      // The peak cap.
      Rectangle {
        width: parent.width
        height: 2
        radius: 1
        y: viz.floorY - (viz.floorY - 8) * (viz.peaks[index] || 0) - 4
        visible: (viz.peaks[index] || 0) > 0.06
        color: Qt.lighter(c, 1.5)
        opacity: 0.9
      }
      // The reflection: the bar upside down, fading into the floor.
      Rectangle {
        width: parent.width
        y: viz.floorY + 3
        height: Math.min(viz.height - viz.floorY - 3, parent.barHeight * 0.6)
        radius: Math.min(2, width / 2)
        gradient: Gradient {
          GradientStop { position: 0; color: Qt.rgba(c.r, c.g, c.b, 0.3) }
          GradientStop { position: 1; color: Qt.rgba(c.r, c.g, c.b, 0) }
        }
      }
    }
  }

  // ---- the floor
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
}
