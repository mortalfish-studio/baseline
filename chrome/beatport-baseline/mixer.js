// The page's own players, for mixing one song into the next like a DJ.
// Runs in the page itself, from the start, so it sees players the page
// never puts on screen (Beatport's): each one that starts playing is noted.
// Baseline's bridge asks over a DOM event (baseline-mixer) and hears back
// on another (baseline-mixer-reply). It reads the players' state, finds
// where the beats fall, and shapes the sound (EQ, filters, level, tempo) on
// a schedule; it runs nothing it's sent.
(() => {
  if (window.__baselineMixer) return;
  window.__baselineMixer = true;
  const players = new Set();
  const play = HTMLMediaElement.prototype.play;
  // A page opened as the other deck (#baseline-quiet) is silent from its
  // first note, until a mix brings it in.
  const quiet = location.hash.includes("baseline-quiet");
  HTMLMediaElement.prototype.play = function (...args) {
    players.add(this);
    if (quiet && !strip) {
      try { arm(this).params.gain.value = 0; } catch (error) { /* plays as it is */ }
    }
    return play.apply(this, args);
  };
  const all = () => [...new Set([...players, ...document.querySelectorAll("audio, video")])];
  const player = () => all().find((m) => !m.paused) || all().find((m) => m.readyState > 0) || all()[0] || null;
  const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
  const wall = () => performance.timeOrigin + performance.now();       // ms, the same clock in every page
  const state = (el) => ({
    tag: el.tagName.toLowerCase(), paused: el.paused, time: Math.round(el.currentTime * 1000) / 1000,
    duration: Number.isFinite(el.duration) ? Math.round(el.duration * 10) / 10 : null, rate: el.playbackRate,
    src: String(el.currentSrc || "").slice(0, 12), ready: el.readyState, protected: !!el.mediaKeys,
    error: el.error ? el.error.code : null, attached: el.isConnected,
  });

  // ---- The channel strip: source → low, mid, high (dB) → high-pass, low-pass
  // (Hz) → level. A kick-band tap beside it hears where the beats fall.
  let strip = null;
  function arm(chosen) {
    const el = chosen || player();
    if (!el) throw new Error("no player");
    if (strip && strip.el === el) return strip;
    const ctx = (strip && strip.ctx) || new AudioContext({ latencyHint: "playback" });
    const node = (make, set) => { const n = make(); set(n); return n; };
    const source = ctx.createMediaElementSource(el);
    const low = node(() => ctx.createBiquadFilter(), (n) => { n.type = "lowshelf"; n.frequency.value = 110; });
    const mid = node(() => ctx.createBiquadFilter(), (n) => { n.type = "peaking"; n.frequency.value = 1000; n.Q.value = 0.7; });
    const high = node(() => ctx.createBiquadFilter(), (n) => { n.type = "highshelf"; n.frequency.value = 5500; });
    const hp = node(() => ctx.createBiquadFilter(), (n) => { n.type = "highpass"; n.frequency.value = 10; n.Q.value = 0.9; });
    const lp = node(() => ctx.createBiquadFilter(), (n) => { n.type = "lowpass"; n.frequency.value = 22000; n.Q.value = 0.9; });
    const gain = ctx.createGain();
    source.connect(low).connect(mid).connect(high).connect(hp).connect(lp).connect(gain).connect(ctx.destination);
    // An echo send, like a DJ mixer's: taken before the level, so the old
    // song's last beats can ring on, in time, after it's gone.
    const echoSend = ctx.createGain();
    echoSend.gain.value = 0;
    const delay = ctx.createDelay(4);
    delay.delayTime.value = 0.24;
    const feedback = ctx.createGain();
    feedback.gain.value = 0.5;
    const echoTone = node(() => ctx.createBiquadFilter(), (n) => { n.type = "bandpass"; n.frequency.value = 1400; n.Q.value = 0.5; });
    lp.connect(echoSend).connect(delay).connect(echoTone).connect(feedback).connect(delay);
    echoTone.connect(ctx.destination);
    // How loud the song is as it comes (before any of this), to match levels.
    const raw = ctx.createAnalyser();
    raw.fftSize = 2048;
    source.connect(raw);
    const kickFilter = node(() => ctx.createBiquadFilter(), (n) => { n.type = "lowpass"; n.frequency.value = 140; });
    const kick = ctx.createAnalyser();
    kick.fftSize = 512;
    source.connect(kickFilter).connect(kick);
    const level = ctx.createAnalyser();
    level.fftSize = 1024;
    gain.connect(level);
    strip = { el, ctx, source, gain, kick, kickFilter, level, raw, delay,
              params: { gain: gain.gain, low: low.gain, mid: mid.gain, high: high.gain, hp: hp.frequency, lp: lp.frequency,
                        hpq: hp.Q, lpq: lp.Q, echo: echoSend.gain } };
    return strip;
  }
  const NEUTRAL = { gain: 1, low: 0, mid: 0, high: 0, hp: 10, lp: 22000, hpq: 0.9, lpq: 0.9, echo: 0 };
  const LEVELS = new Set(["gain", "echo"]);
  const RANGE = { hpq: [0.5, 6], lpq: [0.5, 6] };
  const FREQ = new Set(["hp", "lp"]);

  // ---- Where the beats fall. The kick band's energy is taken block by block
  // with the audio clock's own timestamps, so a busy page can't smear it.
  // The catalogue's tempo is only a hint (it's often rounded): the real beat
  // length is the one whose 4, 8 and 16 beat echoes line up best within 6%
  // of it, and the beat's place is where the kicks fold onto it. Returns the
  // beat in media seconds and where one falls (`offset`, media time).
  const HOP = 128;
  function listen(s, seconds) {
    return new Promise((resolve) => {
      const tap = s.ctx.createScriptProcessor(1024, 1, 1);
      const mute = s.ctx.createGain();
      mute.gain.value = 0;
      const rows = [];                                    // [ctx time, energy] per HOP frames
      const maps = [];                                    // media time minus ctx time
      let tail = new Float32Array(0);
      tap.onaudioprocess = (event) => {
        if (s.el.paused) return;
        const input = event.inputBuffer.getChannelData(0);
        const t0 = event.playbackTime;
        for (let i = 0; i + HOP <= input.length; i += HOP) {
          let e = 0;
          for (let k = i; k < i + HOP; k += 1) e += input[k] * input[k];
          rows.push([t0 + i / s.ctx.sampleRate, e]);
        }
        maps.push(s.el.currentTime - t0 * s.el.playbackRate);
      };
      s.kickFilter.connect(tap).connect(mute).connect(s.ctx.destination);
      setTimeout(() => {
        tap.disconnect(); mute.disconnect(); try { s.kickFilter.disconnect(tap); } catch (error) { /* gone */ }
        resolve({ rows, maps, rate: s.el.playbackRate });
      }, seconds * 1000);
    });
  }
  // The kick's rises on an even timeline (gaps left at zero), smoothed over
  // ~12 ms: where each beat lands.
  function rises(rows, sampleRate) {
    const dt = HOP / sampleRate, t0 = rows[0][0];
    const n = Math.round((rows[rows.length - 1][0] - t0) / dt) + 1;
    const energy = new Float32Array(n);
    for (const [t, e] of rows) energy[Math.round((t - t0) / dt)] = e;
    const smooth = new Float32Array(n);
    for (let i = 0, run = 0; i < n; i += 1) { run += energy[i] - (i >= 4 ? energy[i - 4] : 0); smooth[i] = run; }
    const rise = new Float32Array(n);
    let top = 0;
    for (let i = 1; i < n; i += 1) { rise[i] = Math.max(0, smooth[i] - smooth[i - 1]); top = Math.max(top, rise[i]); }
    return { dt, t0, n, rise, top };
  }
  // The same rises on the shared clock, for lining two decks up against each
  // other: heard over the same moments, so nothing about either song's own
  // timing can come between them.
  async function envelope(op) {
    const s = arm();
    await s.ctx.resume().catch(() => {});
    const seconds = Math.max(3, Math.min(20, Number(op.seconds) || 10));
    const { rows } = await listen(s, seconds);
    if (rows.length < 100) return { ok: false, error: "silent" };
    const { dt, t0, n, rise, top } = rises(rows, s.ctx.sampleRate);
    if (!(top > 0)) return { ok: false, error: "silent" };
    const stamp = s.ctx.getOutputTimestamp();
    const toWall = (t) => performance.timeOrigin + stamp.performanceTime + (t - stamp.contextTime) * 1000;
    const out = new Array(n);
    for (let i = 0; i < n; i += 1) out[i] = Math.round(rise[i] / top * 999);
    return { ok: true, t0: toWall(t0), dt: dt * 1000, rise: out };
  }
  function median(values) {
    const v = [...values].sort((x, y) => x - y);
    return v.length ? v[Math.floor(v.length / 2)] : 0;
  }
  async function grid(op) {
    const s = arm();
    await s.ctx.resume().catch(() => {});
    const hint = 60 / Number(op.bpm);
    if (!(hint > 0.2 && hint < 2)) return { ok: false, error: "bpm" };
    const seconds = Math.max(6, Math.min(30, Number(op.seconds) || 12));
    // Loudness alongside: the mean power of the song as it comes, a few times a second.
    let power = 0, reads = 0;
    const buf = new Float32Array(s.raw.fftSize);
    const meter = setInterval(() => {
      if (s.el.paused) return;
      s.raw.getFloatTimeDomainData(buf);
      let sum = 0;
      for (const v of buf) sum += v * v;
      power += sum / buf.length; reads += 1;
    }, 150);
    const { rows, maps, rate } = await listen(s, seconds);
    clearInterval(meter);
    const loud = reads && power > 0 ? Math.round(10 * Math.log10(power / reads) * 10) / 10 : null;
    if (rows.length < 200 || maps.length < 5) return { ok: false, error: "silent" };
    const { dt, t0, n, rise, top } = rises(rows, s.ctx.sampleRate);
    if (!(top > 0)) return { ok: false, error: "silent" };
    const at = (x) => { const i = Math.floor(x), f = x - i; return i + 1 < n ? rise[i] * (1 - f) + rise[i + 1] * f : 0; };
    const echo = (period) => {
      let sum = 0;
      for (const beats of [4, 8, 16]) {
        const lag = beats * period / dt;
        if (lag > n * 0.6) continue;
        for (let i = 0; i + lag < n - 1; i += 1) if (rise[i]) sum += rise[i] * at(i + lag);
      }
      return sum;
    };
    // Coarse (0.2%) then fine (0.01%) search for the beat in real seconds.
    let best = hint, score = -1;
    for (let p = hint * 0.94; p <= hint * 1.06; p += hint * 0.002) { const v = echo(p); if (v > score) { score = v; best = p; } }
    const centre = best;
    for (let p = centre - hint * 0.002; p <= centre + hint * 0.002; p += hint * 0.0001) { const v = echo(p); if (v > score) { score = v; best = p; } }
    // Fold the rises onto that beat: 64 bins, lightly smoothed, the peak.
    const BINS = 64, bins = new Float64Array(BINS);
    let x = 0, y = 0, weight = 0;
    for (let i = 0; i < n; i += 1) {
      if (!rise[i]) continue;
      const ph = ((i * dt) / best) % 1;
      bins[Math.floor(ph * BINS) % BINS] += rise[i];
      x += rise[i] * Math.cos(2 * Math.PI * ph); y += rise[i] * Math.sin(2 * Math.PI * ph); weight += rise[i];
    }
    let peak = 0, peakValue = -1;
    const near = (k) => bins[(k + BINS) % BINS];
    for (let k = 0; k < BINS; k += 1) { const v = near(k - 1) + 2 * near(k) + near(k + 1); if (v > peakValue) { peakValue = v; peak = k; } }
    const l = near(peak - 1), c = near(peak), r = near(peak + 1);
    const shift = (l - 2 * c + r) ? 0.5 * (l - r) / (l - 2 * c + r) : 0;
    const phase = (peak + 0.5 + Math.max(-0.5, Math.min(0.5, shift))) / BINS;
    // The fold is in ctx time from t0; media time = ctx time × rate + map.
    const map = median(maps);
    const beat = best * rate;                                  // media seconds per beat
    let offset = ((t0 + phase * best) * rate + map) % beat;
    if (offset < 0) offset += beat;
    return {
      ok: true, offset: Math.round(offset * 10000) / 10000, period: Math.round(beat * 100000) / 100000,
      bpm: Math.round(6000 / beat) / 100, sure: Math.round(Math.hypot(x, y) / weight * 100) / 100, loud,
    };
  }

  // ---- A schedule: each lane a list of [ms on the shared clock, value].
  function automate(lanes, echoTime) {
    const s = arm();
    if (Number(echoTime) > 0.05) s.delay.delayTime.value = Math.min(2, Number(echoTime));
    const nowCtx = s.ctx.currentTime, nowWall = wall();
    const at = (ms) => Math.max(nowCtx, nowCtx + (ms - nowWall) / 1000);
    for (const [name, points] of Object.entries(lanes || {})) {
      const p = s.params[name];
      if (!p || !Array.isArray(points) || !points.length) continue;
      p.cancelScheduledValues(nowCtx);
      p.setValueAtTime(p.value, nowCtx);
      for (const [ms, raw] of points) {
        const value = Number(raw);
        if (!Number.isFinite(value) || !Number.isFinite(Number(ms))) continue;
        if (FREQ.has(name)) p.exponentialRampToValueAtTime(Math.max(10, Math.min(22000, value)), at(ms));
        else if (LEVELS.has(name)) p.linearRampToValueAtTime(Math.max(0, Math.min(1.5, value)), at(ms));
        else if (RANGE[name]) p.linearRampToValueAtTime(Math.max(RANGE[name][0], Math.min(RANGE[name][1], value)), at(ms));
        else p.linearRampToValueAtTime(Math.max(-40, Math.min(9, value)), at(ms));
      }
    }
  }

  // ---- Keeping in time: from `start` (ms on the shared clock) the song
  // should be at `time` + elapsed × rate. A small lead is put right by a
  // seek while it's silent, then by easing the tempo a touch (keylocked, so
  // nobody hears it), checked every quarter second until `until`.
  let follow = null;
  function lock(op) {
    const s = arm();
    const el = s.el;
    const rate = Math.max(0.9, Math.min(1.1, Number(op.rate) || 1));
    el.preservesPitch = true;
    if (follow) clearInterval(follow.timer);
    follow = { start: Number(op.start), time: Number(op.time), rate, until: Number(op.until), worst: 0, seeks: 0, errors: [], recent: [] };
    const want = () => follow.time + (wall() - follow.start) / 1000 * follow.rate;
    follow.timer = setInterval(() => {
      const now = wall();
      if (now > follow.until) { el.playbackRate = follow.rate; clearInterval(follow.timer); follow.timer = null; return; }
      if (el.paused || el.readyState < 3) return;
      // The element's clock reads a few ms either way each time, so the
      // error is the median of the last few readings.
      const raw = el.currentTime - want();            // + ahead, - behind
      follow.recent.push(raw);
      if (follow.recent.length > 7) follow.recent.shift();
      const error = median(follow.recent);
      const silent = s.params.gain.value < 0.02;
      if (Math.abs(raw) > (silent ? 0.03 : 0.25) && Math.abs(error) > (silent ? 0.03 : 0.25)) {
        el.currentTime = want() + 0.02;               // a seek lands a touch late
        follow.seeks += 1;
        follow.recent = [];
        return;
      }
      if (now > follow.start) {
        follow.worst = Math.max(follow.worst, Math.abs(error));
        follow.errors.push(Math.round(error * 1000));
        if (follow.errors.length > 40) follow.errors.shift();
      }
      // Ease towards it over about four seconds, never more than 1% off,
      // and leave it be inside 4 ms.
      const most = now < (follow.fastUntil || 0) ? 0.03 : 0.01;
      const nudge = Math.abs(error) < 0.004 ? 0 : Math.max(-most, Math.min(most, error / 4));
      el.playbackRate = follow.rate * (1 - nudge);
    }, 200);
  }

  // ---- Cue: ready at `time`, silent, at `rate`, not playing.
  async function cue(op) {
    const s = arm();
    await s.ctx.resume().catch(() => {});
    s.params.gain.cancelScheduledValues(s.ctx.currentTime);
    s.params.gain.setValueAtTime(0, s.ctx.currentTime);
    s.el.preservesPitch = true;
    s.el.playbackRate = Math.max(0.9, Math.min(1.1, Number(op.rate) || 1));
    s.el.pause();
    s.el.currentTime = Math.max(0, Number(op.time) || 0);
    for (let i = 0; i < 40 && s.el.readyState < 3; i += 1) await sleep(100);
    return { ok: s.el.readyState >= 3, time: s.el.currentTime, ready: s.el.readyState };
  }

  // ---- Go: start playing at `start` - preroll (silent), locked to the
  // schedule, with the lanes for the mix.
  async function go(op) {
    const s = arm();
    await s.ctx.resume().catch(() => {});
    const preroll = Math.max(1, Math.min(8, Number(op.preroll) || 3)) * 1000;
    const begin = Number(op.start) - preroll;
    while (wall() < begin) await sleep(5);
    lock(op);
    s.el.currentTime = Math.max(0, Number(op.time) - preroll / 1000 * (Number(op.rate) || 1));
    await s.el.play();
    automate(op.lanes || {}, op.echo);
    return { ok: true };
  }

  // Back to plain playing: EQ flat, filters open, full level, and the tempo
  // eased home over `seconds` (keylocked).
  function reset(op) {
    if (!strip) return { ok: true };
    const s = strip;
    const until = wall() + Math.max(0.05, Number(op.seconds) || 0.05) * 1000;
    const home = { ...NEUTRAL, gain: Math.max(0.3, Math.min(1.5, Number(op.gain) || 1)) };
    automate(Object.fromEntries(Object.entries(home).map(([k, v]) => [k, [[until, v]]])));
    if (follow) { clearInterval(follow.timer); follow.timer = null; }
    const from = s.el.playbackRate, start = wall(), span = until - start;
    const glide = setInterval(() => {
      const f = Math.min(1, (wall() - start) / span);
      s.el.playbackRate = from + (1 - from) * f;
      if (f >= 1) clearInterval(glide);
    }, 200);
    return { ok: true };
  }

  // How often a timer here really runs (a hidden page's are slowed): the
  // last few gaps, in ms, of one that asks for every 200.
  const tickGaps = [];
  let lastTick = performance.now();
  setInterval(() => {
    const now = performance.now();
    tickGaps.push(Math.round(now - lastTick));
    if (tickGaps.length > 12) tickGaps.shift();
    lastTick = now;
  }, 200);

  function look() {
    const el = player();
    const meta = navigator.mediaSession && navigator.mediaSession.metadata;
    const out = { ok: !!el, wall: wall(), ...(el ? state(el) : {}), title: meta ? String(meta.title || "").slice(0, 200) : "",
                  seen: document.visibilityState, ticks: tickGaps.slice(-6) };
    if (strip) {
      const buf = new Float32Array(strip.level.fftSize);
      strip.level.getFloatTimeDomainData(buf);
      let peak = 0;
      for (const v of buf) peak = Math.max(peak, Math.abs(v));
      out.peak = Math.round(peak * 1000) / 1000;
      out.eq = Object.fromEntries(Object.entries(strip.params).map(([k, p]) => [k, Math.round(p.value * 100) / 100]));
    }
    if (follow) out.sync = { worst: Math.round(follow.worst * 1000), seeks: follow.seeks, last: follow.errors.slice(-8) };
    return out;
  }

  window.addEventListener("baseline-mixer", async (event) => {
    const op = (event.detail && typeof event.detail === "string") ? JSON.parse(event.detail) : {};
    let reply;
    try {
      if (op.type === "state") reply = { ok: true, media: all().map(state) };
      else if (op.type === "look") reply = look();
      else if (op.type === "arm") { const s = arm(); await s.ctx.resume().catch(() => {}); reply = { ok: true, ctx: s.ctx.state }; }
      else if (op.type === "grid") reply = await grid(op);
      else if (op.type === "cue") reply = await cue(op);
      else if (op.type === "go") reply = await go(op);
      else if (op.type === "automate") { automate(op.lanes || {}, op.echo); reply = { ok: true }; }
      else if (op.type === "lock") { lock(op); reply = { ok: true }; }
      else if (op.type === "envelope") reply = await envelope(op);
      else if (op.type === "shift") {
        // Line the beats up anew: the schedule moves on by `seconds`, and the
        // tempo may lean a little harder for a few seconds to get there. With
        // `rate`, the tempo itself is put right (from where it is now on), when
        // the beats were drifting apart.
        if (follow) {
          follow.time += Math.max(-0.3, Math.min(0.3, Number(op.seconds) || 0));
          const rate = Number(op.rate);
          if (rate >= 0.9 && rate <= 1.1) {
            const now = wall();
            follow.time += (now - follow.start) / 1000 * follow.rate;
            follow.start = now;
            follow.rate = rate;
          }
          follow.fastUntil = wall() + 6000; follow.recent = [];
        }
        reply = { ok: !!follow };
      }
      else if (op.type === "reset") reply = reset(op);
      else if (op.type === "seek") { const el = player(); if (el) el.currentTime = Math.max(0, Number(op.time) || 0); reply = { ok: !!el }; }
      else if (op.type === "play") { const el = player(); if (el) await el.play(); reply = { ok: !!el }; }
      else if (op.type === "pause") { const el = player(); if (el) el.pause(); reply = { ok: !!el }; }
      else reply = { ok: false };
    } catch (error) {
      reply = { ok: false, error: String(error) };
    }
    window.dispatchEvent(new CustomEvent("baseline-mixer-reply", { detail: JSON.stringify({ id: op.id, ...reply }) }));
  });
})();
