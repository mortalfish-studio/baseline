import QtQuick
import QtQuick.Shapes
import qs.Commons

// The agents at work: while Grok, Claude or Codex is answering one of the
// Deck's questions, a soft waveform runs across the header, one line per
// agent in its own colour, with who's doing what under it. Idle, it settles
// into a faint flat line. Tapping it opens the agents card. It only draws
// while something is working (or settling), and not at all off screen.
Item {
  id: wave
  property var working: []          // [{agent, tier, job, since}] from agents-now.json
  property bool active: true        // on screen
  property color amber: "#ff5aa5"
  property color teal: "#62b6ff"
  property color ink: "#f2e9f5"
  property var jobText: (job) => job
  property var agentName: (agent) => agent
  signal tapped()

  // The questions being worked on, oldest first: one line each (up to four).
  readonly property var agents: (working || []).slice().sort((a, b) => (a.since || 0) - (b.since || 0)).slice(0, 4)
  // Who's at it, each once.
  readonly property var who: {
    const out = []
    for (const item of agents) if (out.indexOf(item.agent) < 0) out.push(item.agent)
    return out
  }
  readonly property bool busy: agents.length > 0
  function colorOf(agent) { return agent === "claude" ? amber : agent === "codex" ? teal : ink }

  // How much it moves: rises as work starts, settles when it's done.
  property real level: busy ? 1 : 0
  Behavior on level { NumberAnimation { duration: busy ? 600 : 1400; easing.type: Easing.OutCubic } }
  property real t: 0
  property double now: Date.now() / 1000      // double: a float would lose the seconds
  // In step with the screen while agents work (even with animations off:
  // it's the only sign they're at it), moving by the real time between frames.
  FrameAnimation {
    running: wave.active && (wave.busy || wave.level > 0.01)
    // 30 frames a second is plenty for waves this slow, at half the work.
    property real gathered: 0
    onTriggered: {
      gathered += Math.min(frameTime, 0.1)
      if (gathered < 1 / 31) return
      wave.t += gathered; gathered = 0
      wave.now = Date.now() / 1000
    }
  }
  onBusyChanged: now = Date.now() / 1000

  // Drawn by the GPU (Qt Quick Shapes): each frame only works out ~100
  // points a line, 30 times a second; a Canvas repainted in JavaScript took a
  // whole CPU core.
  readonly property int steps: 72
  readonly property real mid: (height - caption.height - 2) / 2
  function points(n) {
    const w = width, h = height - caption.height - 2
    const out = []
    if (w <= 0) return out
    const f1 = 0.018 + n * 0.007, f2 = 0.047 + n * 0.011
    const s1 = 2.1 + n * 0.6, s2 = 3.3 - n * 0.4
    const ph = n * 1.9
    const amp = h * 0.38 * level / (1 + n * 0.25)
    for (let i = 0; i <= steps; i++) {
      const x = w * i / steps
      const taper = Math.sin(Math.PI * i / steps)          // quiet at both ends
      out.push(Qt.point(x, mid + amp * taper * taper * (0.62 * Math.sin(x * f1 + t * s1 + ph)
                                                        + 0.38 * Math.sin(x * f2 - t * s2 + ph * 0.5))))
    }
    return out
  }

  // Idle: one faint line.
  Rectangle {
    x: 0; width: parent.width; y: wave.mid; height: 1
    color: wave.ink
    opacity: 0.12 + 0.1 * (1 - wave.level)
  }
  Repeater {
    model: wave.level > 0.01 ? (wave.agents.length ? wave.agents : [{ agent: "grok" }]) : []
    delegate: Shape {
      id: line
      required property var modelData
      required property int index
      anchors.fill: parent
      preferredRendererType: Shape.GeometryRenderer
      layer.enabled: true; layer.samples: 4          // smooth edges, on the GPU
      readonly property color tone: wave.colorOf(modelData.agent)
      readonly property var pts: { wave.t; wave.level; wave.width; return wave.points(index) }
      // A soft glow under a fine line.
      ShapePath {
        strokeColor: Qt.rgba(line.tone.r, line.tone.g, line.tone.b, 0.18 * wave.level)
        strokeWidth: 4; fillColor: "transparent"
        capStyle: ShapePath.RoundCap; joinStyle: ShapePath.RoundJoin
        PathPolyline { path: line.pts }
      }
      ShapePath {
        strokeColor: Qt.rgba(line.tone.r, line.tone.g, line.tone.b, 0.9 * wave.level)
        strokeWidth: 1.3; fillColor: "transparent"
        capStyle: ShapePath.RoundCap; joinStyle: ShapePath.RoundJoin
        PathPolyline { path: line.pts }
      }
    }
  }

  // Who's doing what: "Claude · finding songs · 0:12", or each agent's name
  // when several are at it.
  Text {
    id: caption
    anchors.horizontalCenter: parent.horizontalCenter
    anchors.bottom: parent.bottom
    textFormat: Text.PlainText
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
    font.letterSpacing: 1
    color: wave.who.length === 1 ? wave.colorOf(wave.who[0]) : wave.ink
    opacity: wave.busy ? 0.85 : (hover.hovered ? 0.5 : 0)
    Behavior on opacity { NumberAnimation { duration: Style.duration(220) } }
    text: {
      // "Grok + Claude · digging for songs · 0:42" (from the first to start).
      const a = wave.agents[0]
      if (!wave.busy || !a) return wave.agentName("")
      const jobs = wave.agents.map(x => x.job)
      const job = jobs.every(j => j === a.job) ? wave.jobText(a.job) : ""
      const secs = Math.max(0, Math.floor(wave.now - (a.since || wave.now)))
      return wave.who.map(x => wave.agentName(x)).join(" + ")
             + (wave.agents.length > wave.who.length ? " ×" + wave.agents.length : "")
             + (job ? "  ·  " + job : "") + "  ·  "
             + Math.floor(secs / 60) + ":" + String(secs % 60).padStart(2, "0")
    }
  }

  HoverHandler { id: hover; cursorShape: Qt.PointingHandCursor }
  TapHandler { onTapped: wave.tapped() }
}
