import QtQuick
import qs.Commons

// The agents at work: while Grok, Claude or Codex is answering one of the
// Deck's questions, a soft waveform runs across the header, one line per
// agent in its own colour, with who's doing what under it. Idle, it settles
// into a faint flat line. Tapping it opens the agents card. It only draws
// while something is working (or settling), and not at all off screen; with
// animations off it steps once a second instead of moving smoothly.
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
  readonly property bool still: Style.duration(1000) === 0     // animations off: draw it, don't move it
  function colorOf(agent) { return agent === "claude" ? amber : agent === "codex" ? teal : ink }

  // How much it moves: rises as work starts, settles when it's done.
  property real level: busy ? 1 : 0
  Behavior on level { NumberAnimation { duration: Style.duration(busy ? 600 : 1400); easing.type: Easing.OutCubic } }
  property real t: 0
  property double now: Date.now() / 1000      // double: a float would lose the seconds
  // Smooth at 30 frames a second; with animations off, a calm step once a
  // second (still plainly at work, and next to nothing to draw).
  Timer {
    interval: wave.still ? 1000 : 33
    repeat: true
    running: wave.active && (wave.busy || (!wave.still && wave.level > 0.01))
    onTriggered: { wave.t += wave.still ? 0.35 : 0.033; wave.now = Date.now() / 1000; canvas.requestPaint() }
  }
  onBusyChanged: now = Date.now() / 1000
  onLevelChanged: canvas.requestPaint()
  onWidthChanged: canvas.requestPaint()
  onAgentsChanged: canvas.requestPaint()

  Canvas {
    id: canvas
    anchors.left: parent.left; anchors.right: parent.right
    anchors.top: parent.top
    height: parent.height - caption.height - 2
    renderStrategy: Canvas.Cooperative
    onPaint: {
      const ctx = getContext("2d")
      ctx.reset()
      const w = width, h = height, mid = h / 2
      // Idle: one faint line.
      ctx.globalAlpha = 0.12 + 0.1 * (1 - wave.level)
      ctx.strokeStyle = wave.ink
      ctx.lineWidth = 1
      ctx.beginPath(); ctx.moveTo(0, mid); ctx.lineTo(w, mid); ctx.stroke()
      if (wave.level < 0.01) return
      const lines = wave.agents.length ? wave.agents : [{ agent: "grok" }]
      for (let n = 0; n < lines.length; n++) {
        const c = wave.colorOf(lines[n].agent)
        const f1 = 0.018 + n * 0.007, f2 = 0.047 + n * 0.011
        const s1 = 2.1 + n * 0.6, s2 = 3.3 - n * 0.4
        const ph = n * 1.9
        const amp = h * 0.38 * wave.level / (1 + n * 0.25)
        const path = () => {
          ctx.beginPath()
          for (let x = 0; x <= w; x += 3) {
            const taper = Math.sin(Math.PI * x / w)          // quiet at both ends
            const y = mid + amp * taper * taper * (0.62 * Math.sin(x * f1 + wave.t * s1 + ph)
                                                   + 0.38 * Math.sin(x * f2 - wave.t * s2 + ph * 0.5))
            if (x === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y)
          }
        }
        // A soft glow under a fine line.
        ctx.strokeStyle = c
        ctx.globalAlpha = 0.18 * wave.level
        ctx.lineWidth = 4
        path(); ctx.stroke()
        ctx.globalAlpha = 0.9 * wave.level
        ctx.lineWidth = 1.3
        path(); ctx.stroke()
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
