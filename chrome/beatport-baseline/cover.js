// Beatport tells Chrome the playing track's name but not its cover, so the
// desktop's media popup shows Chrome's logo. This runs in the page itself
// (where Beatport's media details live) and adds the player bar's cover, at
// a size that looks sharp. It only reads the page; it sends nothing anywhere.
(() => {
  if (window.__baselineCover || !("mediaSession" in navigator)) return;
  window.__baselineCover = true;
  // Pinned along the bottom of the window (the player bar), or just below a
  // short window, where Beatport keeps it.
  const pinned = (el) => {
    for (let node = el, depth = 0; node && node !== document.body && depth < 14; node = node.parentElement, depth += 1) {
      const position = getComputedStyle(node).position;
      if (position === "fixed" || position === "sticky") return true;
    }
    return false;
  };
  const inBar = (el) => {
    const r = el.getBoundingClientRect();
    return r.top >= window.innerHeight - 160 && r.top < window.innerHeight + 400 && pinned(el);
  };
  const barCover = () => {
    let best = null, size = 0;
    for (const img of document.querySelectorAll("img[src]")) {
      const w = img.getBoundingClientRect().width;
      if (w < 24 || w > 160 || w <= size || !inBar(img)) continue;
      best = img; size = w;
    }
    return best ? best.src.replace(/\/image_size\/\d+x\d+\//, "/image_size/500x500/") : "";
  };
  setInterval(() => {
    const m = navigator.mediaSession.metadata;
    if (!m || !m.title) return;
    const src = barCover();
    if (!src || (m.artwork || []).some((a) => a.src === src)) return;
    navigator.mediaSession.metadata = new MediaMetadata({
      title: m.title, artist: m.artist, album: m.album,
      artwork: [{ src, sizes: "500x500" }],
    });
  }, 1500);
})();
