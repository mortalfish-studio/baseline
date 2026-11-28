import QtQuick
import qs.Commons
import qs.Commons as Commons

// The close-up of a mix, as DJ software shows two decks: both songs flowing
// past a needle in the middle, each as a ribbon of its loudness, its top half
// the melody and its bottom half the bass, each scaled by what the mix lets
// through (so a bass swap shows as one song's lower half draining while the
// other's fills). The beats each song was heard to have tick across it; the
// two combs line up when the mix is in time. Once the old song has drained
// away at the mix's end, the new one glides up into the top row, taking on
// the playing song's colour as it goes.
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
  property color outColor: Commons.Color.accent
  property color inColor: Commons.Color.foreground
  property color ink: Commons.Color.popups.text
  property real topHeight: 36
  property real seamHeight: 20
  property real bottomHeight: 30
  // "split": the two songs share one strip, cut in half along the seam: the old
  // song growing up from it, the new one hanging down, each with its bass as the
  // solid inner band and its melody as the lighter outer one. At the end the new
  // song turns over into the top half.
  property bool split: false

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
    // Rows: the old song on top through the mix; as it ends it fades out, then
    // the new song glides up into its row.
    const clamp01 = x => Math.max(0, Math.min(1, x))
    const gone = clamp01((u - seconds) / 0.8)
    const rise = clamp01((u - seconds - 0.5) / 1.1)
    const swapT = rise * rise * (3 - 2 * rise)
    const rowTop = { y: 0, h: view.topHeight }
    const rowBottom = { y: view.topHeight + view.seamHeight, h: view.bottomHeight }
    const rowA = { y: lerp(rowTop.y, rowBottom.y, swapT), h: lerp(rowTop.h, rowBottom.h, swapT) }
    const rowB = { y: lerp(rowBottom.y, rowTop.y, swapT), h: lerp(rowBottom.h, rowTop.h, swapT) }

    // Each song as a function of the window's x: its own time, and whether it's heard.
    const songA = a => ({ t: a, v: a - from, on: a - from <= seconds, deck: "a", env: view.envA, len: view.lenA })
    const songB = a => { const v = a - from; return { t: entry + (v - enter) * rate, v: v, on: v >= enter, deck: "b", env: view.envB, len: view.lenB } }

    // Split: one song as a mirror-half from the middle line, `dir` -1 up, +1 down
    // (in between as it turns over): bass inside, melody outside.
    const H = view.topHeight + view.seamHeight + view.bottomHeight, mid0 = H / 2, reach0 = H / 2 - 1
    const half = (color, env, len, deck, at, dir) => {
      const inner = [], outer = []
      for (let x = 0; x <= W + 3; x += 3) {
        const s = at(a0 + x / W * across)
        const e = s.on ? loud(env, len, s.t) : 0
        const b = e * level(deck, "bass", s.v) * 0.5, t = e * level(deck, "top", s.v) * 0.5
        inner.push([x, mid0 + dir * Math.max(0.3, b * reach0)])
        outer.push([x, mid0 + dir * Math.max(0.6, (b + t) * reach0)])
      }
      const band = (edge, base) => {
        g.beginPath()
        g.moveTo(edge[0][0], edge[0][1])
        for (let i = 1; i < edge.length; i += 1) g.lineTo(edge[i][0], edge[i][1])
        for (let i = base.length - 1; i >= 0; i -= 1) g.lineTo(base[i][0], base[i][1])
        g.closePath()
      }
      const flat = inner.map(p => [p[0], mid0])
      for (const [x0, w, lit] of [[0, Math.max(0, needle), true], [needle, W - needle, false]]) {
        g.save()
        g.beginPath(); g.rect(x0, 0, w, H); g.clip()
        band(outer, inner); g.fillStyle = rgba(color, lit ? 0.55 : 0.18); g.fill()
        band(inner, flat); g.fillStyle = rgba(color, lit ? 0.95 : 0.32); g.fill()
        g.restore()
      }
    }
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
    const seamY = view.split ? mid0 : view.topHeight + view.seamHeight / 2
    const mx0 = xOf(from), mx1 = xOf(from + seconds)
    g.fillStyle = rgba(view.ink, 0.06)
    g.fillRect(0, seamY - 0.5, W, 1)
    const band = g.createLinearGradient(mx0, 0, mx1, 0)
    band.addColorStop(0, rgba(view.outColor, 0.55))
    band.addColorStop(1, rgba(view.inColor, 0.55))
    g.fillStyle = band
    g.fillRect(mx0, seamY - 1, Math.max(1, mx1 - mx0), 2)
    if (m.takeover) {
      const sx = xOf(from + (m.takeover * 1000 - m.startMs) / 1000)
      g.fillStyle = rgba(view.ink, 0.7)
      g.fillRect(sx - 1, seamY - 3, 2, 6)
    }

    if (view.split) {
      // The two halves, and between them the middle line; then the beats and the needle.
      const colorB = Qt.rgba(lerp(view.inColor.r, view.outColor.r, swapT), lerp(view.inColor.g, view.outColor.g, swapT),
                             lerp(view.inColor.b, view.outColor.b, swapT), 1)
      g.globalAlpha = 1 - gone
      half(view.outColor, view.envA, view.lenA, "a", songA, -1)
      g.globalAlpha = 1
      half(colorB, view.envB, view.lenB, "b", songB, lerp(1, -1, swapT))
      g.fillStyle = rgba(view.ink, 0.12)
      g.fillRect(0, mid0 - 0.5, W, 1)
      const grids = m.grids || {}
      const fade = Math.min(1, Math.max(0, (view.zoom - 0.4) / 0.4))
      const ticks = (grid, toWindow, fromWindow, dir, color, alpha) => {
        if (!grid || !(grid[1] > 0) || fade <= 0) return
        const [first, period] = grid
        const t0 = fromWindow(a0), t1 = fromWindow(a0 + across)
        for (let k = Math.ceil((Math.min(t0, t1) - first) / period); first + k * period <= Math.max(t0, t1); k += 1) {
          const x = xOf(toWindow(first + k * period))
          const bar = ((k % 4) + 4) % 4 === 0
          g.fillStyle = rgba(bar ? view.ink : color, (bar ? 0.5 : 0.22) * fade * alpha)
          const len = bar ? 7 : 4
          g.fillRect(x - 0.5, dir < 0 ? mid0 - len : mid0, 1, len)
        }
      }
      ticks(grids.a, t => t, a => a, -1, view.outColor, 1 - gone)
      ticks(grids.b, t => from + enter + (t - entry) / rate, a => entry + (a - from - enter) * rate, swapT > 0.5 ? -1 : 1, colorB, Math.abs(1 - 2 * swapT))
      g.fillStyle = rgba(view.ink, 0.08)
      g.fillRect(needle - 3, 0, 6, height)
      g.fillStyle = rgba(view.ink, 0.9)
      g.fillRect(needle - 0.75, 0, 1.5, height)
      return
    }
    g.globalAlpha = 1 - gone
    ribbon(rowA, view.outColor, view.envA, view.lenA, "a", songA)
    g.globalAlpha = 1
    // As it rises it takes on the playing song's colour, so the hand-back to the overview doesn't flash.
    const colorB = Qt.rgba(lerp(view.inColor.r, view.outColor.r, swapT), lerp(view.inColor.g, view.outColor.g, swapT),
                           lerp(view.inColor.b, view.outColor.b, swapT), 1)
    ribbon(rowB, colorB, view.envB, view.lenB, "b", songB)
    const grids = m.grids || {}
    g.globalAlpha = 1 - gone
    comb(rowA, view.outColor, grids.a, t => t, a => a, songA)
    g.globalAlpha = 1
    // The new song's beats, from its own seconds to the window's and back.
    comb(rowB, colorB, grids.b, t => from + enter + (t - entry) / rate, a => entry + (a - from - enter) * rate, songB)

    // The needle: now, through both decks.
    g.fillStyle = rgba(view.ink, 0.08)
    g.fillRect(needle - 3, 0, 6, height)
    g.fillStyle = rgba(view.ink, 0.9)
    g.fillRect(needle - 0.75, 0, 1.5, height)
  }
}
