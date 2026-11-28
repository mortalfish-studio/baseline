import QtQuick
import qs.Commons
import qs.Commons as Commons

// The close-up of a mix, as DJ software shows two decks: both songs flowing
// past a needle in the middle, each as a ribbon of its loudness, its top half
// the melody and its bottom half the bass, each scaled by what the mix lets
// through (so a bass swap shows as one song's lower half draining while the
// other's fills). The beats each song was heard to have tick across it; the
// two combs line up when the mix is in time. At the takeover the ribbons
// change places, the new song rising to the top row.
//
// Everything runs off the wall clock and the mix's own plan (deck.mixNow), so
// it moves smoothly every frame. `zoom` eases it in from the whole song (as the
// overview shows it) to `span` seconds across.
Canvas {
  id: view
  property var mix: ({})               // deck.mixNow: startMs, endMs, fromAt, entry, enter, rate, curves, grids
  property var envA: []                 // the song going out: its loudness, 0-1, evenly over it
  property var envB: []                 // the song coming in
  property real lenA: 1
  property real lenB: 1
  property real zoom: 0                 // 0: the whole song; 1: close up
  property real span: 24                // seconds across, close up
  property bool handedOver: false       // the new song has taken over (it's on top)
  property color outColor: Commons.Color.accent
  property color inColor: Commons.Color.foreground
  property color ink: Commons.Color.popups.text
  property real topHeight: 36
  property real seamHeight: 20
  property real bottomHeight: 30

  property real swapT: handedOver ? 1 : 0
  Behavior on swapT { NumberAnimation { duration: Style.duration(650); easing.type: Easing.OutCubic } }

  renderStrategy: Canvas.Cooperative
  FrameAnimation { running: view.visible && view.opacity > 0.01; onTriggered: view.requestPaint() }

  onPaint: {
    const g = getContext("2d")
    g.reset()
    const m = view.mix
    if (!m || !m.startMs || !(m.endMs > m.startMs)) return
    const W = width
    const lerp = (a, b, t) => a + (b - a) * t
    const rgba = (c, a) => Qt.rgba(c.r, c.g, c.b, a)
    const seconds = m.seconds || (m.endMs - m.startMs) / 1000
    const rate = m.rate || 1, entry = m.entry || 0, enter = m.enter || 0, from = m.fromAt || 0
    const u = (Date.now() - m.startMs) / 1000          // seconds into the mix (before it: negative)
    const tA = from + u                                 // where the old song is
    // The window, in the old song's own seconds: the whole song, easing in to `span` around now.
    const centre = lerp(view.lenA / 2, tA, view.zoom)
    const across = Math.exp(lerp(Math.log(Math.max(view.span, view.lenA)), Math.log(view.span), view.zoom))
    const a0 = centre - across / 2
    const xOf = a => (a - a0) / across * W
    const needle = xOf(tA)

    // How much of each song the mix lets through, `v` seconds into it.
    const curves = m.curves
    const level = (deck, lane, v) => {
      if (v < 0) return deck === "a" ? 1 : 0
      if (v > seconds) return deck === "a" ? 0 : 1
      const arr = curves && curves[deck] ? curves[deck][lane] : null
      if (!arr || arr.length < 2) return deck === "a" ? 1 - v / seconds : v / seconds
      const f = v / seconds * (arr.length - 1), i = Math.floor(f), k = f - i
      return arr[i] + (arr[Math.min(i + 1, arr.length - 1)] - arr[i]) * k
    }
    // A song's loudness at t seconds into it, eased between the points kept.
    const loud = (env, len, t) => {
      if (!env || env.length < 2 || t < 0 || t > len) return 0
      const f = t / len * (env.length - 1), i = Math.floor(f), k = f - i
      const w = (1 - Math.cos(k * Math.PI)) / 2
      return env[i] + (env[Math.min(i + 1, env.length - 1)] - env[i]) * w
    }
    // Rows: the old song on top until the takeover, then they change places.
    const rowTop = { y: 0, h: view.topHeight }
    const rowBottom = { y: view.topHeight + view.seamHeight, h: view.bottomHeight }
    const rowA = { y: lerp(rowTop.y, rowBottom.y, view.swapT), h: lerp(rowTop.h, rowBottom.h, view.swapT) }
    const rowB = { y: lerp(rowBottom.y, rowTop.y, view.swapT), h: lerp(rowBottom.h, rowTop.h, view.swapT) }

    // Each song as a function of the window's x: its own time, and whether it's heard.
    const songA = a => ({ t: a, v: a - from, on: a - from <= seconds, deck: "a", env: view.envA, len: view.lenA })
    const songB = a => { const v = a - from; return { t: entry + (v - enter) * rate, v: v, on: v >= enter, deck: "b", env: view.envB, len: view.lenB } }

    const ribbon = (row, color, env, len, deck, at) => {
      const mid = row.y + row.h / 2, half = row.h / 2 - 1
      const top = [], bottom = []
      for (let x = 0; x <= W + 3; x += 3) {
        const s = at(a0 + x / W * across)
        const e = s.on ? loud(env, len, s.t) : 0
        top.push([x, mid - Math.max(0.6, e * level(deck, "top", s.v) * half)])
        bottom.push([x, mid + Math.max(0.6, e * level(deck, "bass", s.v) * half)])
      }
      const shape = () => {
        g.beginPath()
        g.moveTo(top[0][0], top[0][1])
        for (let i = 1; i < top.length; i += 1) g.lineTo(top[i][0], top[i][1])
        for (let i = bottom.length - 1; i >= 0; i -= 1) g.lineTo(bottom[i][0], bottom[i][1])
        g.closePath()
      }
      // Heard so far: lit; to come: faint.
      g.save()
      g.beginPath(); g.rect(0, row.y - 2, Math.max(0, needle), row.h + 4); g.clip()
      const lit = g.createLinearGradient(0, row.y, 0, row.y + row.h)
      lit.addColorStop(0, rgba(color, 0.95))
      lit.addColorStop(0.5, rgba(color, 0.7))
      lit.addColorStop(1, rgba(color, 0.95))
      shape(); g.fillStyle = lit; g.fill()
      g.restore()
      g.save()
      g.beginPath(); g.rect(needle, row.y - 2, W - needle, row.h + 4); g.clip()
      shape(); g.fillStyle = rgba(color, 0.3); g.fill()
      g.restore()
    }
    // The beats each song was heard to have, across its ribbon (bars brighter).
    const comb = (row, color, grid, toWindow, fromWindow, at) => {
      if (!grid || !(grid[1] > 0) || view.zoom < 0.4) return
      const fade = Math.min(1, (view.zoom - 0.4) / 0.4)
      const [first, period] = grid
      const t0 = fromWindow(a0), t1 = fromWindow(a0 + across)
      const mid = row.y + row.h / 2, reach = row.h / 2 - 2
      for (let k = Math.ceil((Math.min(t0, t1) - first) / period); first + k * period <= Math.max(t0, t1); k += 1) {
        const a = toWindow(first + k * period)
        const s = at(a)
        if (!s.on) continue
        // As tall as the song is there, so a song barely in yet has small ticks.
        const e = loud(s.env, s.len, s.t)
        const up = Math.max(2, e * level(s.deck, "top", s.v) * reach), down = Math.max(2, e * level(s.deck, "bass", s.v) * reach)
        const x = xOf(a)
        const bar = ((k % 4) + 4) % 4 === 0
        g.fillStyle = rgba(bar ? view.ink : color, (bar ? 0.5 : 0.2) * fade)
        g.fillRect(x - 0.5, mid - up, 1, up + down)
      }
    }

    // The seam: the mix as a bar from the old song's colour to the new one's,
    // with a tick at the takeover.
    const seamY = view.topHeight + view.seamHeight / 2
    const mx0 = xOf(from), mx1 = xOf(from + seconds)
    g.fillStyle = rgba(view.ink, 0.06)
    g.fillRect(0, seamY - 0.5, W, 1)
    const band = g.createLinearGradient(mx0, 0, mx1, 0)
    band.addColorStop(0, rgba(view.outColor, 0.55))
    band.addColorStop(1, rgba(view.inColor, 0.55))
    g.fillStyle = band
    g.fillRect(mx0, seamY - 1.5, Math.max(1, mx1 - mx0), 3)
    if (m.takeover) {
      const sx = xOf(from + (m.takeover * 1000 - m.startMs) / 1000)
      g.fillStyle = rgba(view.ink, 0.7)
      g.fillRect(sx - 1, seamY - 5, 2, 10)
    }

    ribbon(rowA, view.outColor, view.envA, view.lenA, "a", songA)
    ribbon(rowB, view.inColor, view.envB, view.lenB, "b", songB)
    const grids = m.grids || {}
    comb(rowA, view.outColor, grids.a, t => t, a => a, songA)
    // The new song's beats, from its own seconds to the window's and back.
    comb(rowB, view.inColor, grids.b, t => from + enter + (t - entry) / rate, a => entry + (a - from - enter) * rate, songB)

    // The needle: now, through both decks.
    g.fillStyle = rgba(view.ink, 0.08)
    g.fillRect(needle - 3, 0, 6, height)
    g.fillStyle = rgba(view.ink, 0.9)
    g.fillRect(needle - 0.75, 0, 1.5, height)
  }
}
