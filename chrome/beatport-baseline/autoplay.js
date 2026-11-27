// Baseline opens Beatport pages with #baseline-play when you ask it to start
// a chart or playlist. Find that page's own Play button (the big one by the
// title, not the player bar's) and press it, once.
(() => {
  let timer = null;
  const run = () => {
  if (!location.hash.includes("baseline-play")) return;
  history.replaceState(null, "", location.pathname + location.search);

  const isPlayish = (el) => {
    const text = [el.getAttribute("aria-label"), el.getAttribute("title"), el.getAttribute("data-testid"),
                  el.className && el.className.baseVal === undefined ? el.className : ""]
      .filter(Boolean).join(" ").toLowerCase();
    // "play" as a word ("Play", "Play playlist", "play-button"), never
    // "add to playlist", the queue or the player bar's own controls.
    return /\bplay\b/.test(text) && !/pause|player-bar|add[- ]to|queue/.test(text);
  };
  const visibleInPage = (el) => {
    const r = el.getBoundingClientRect();
    // The player bar is fixed along the bottom; the page's button sits up top.
    return r.width > 0 && r.height > 0 && r.top >= 0 && r.bottom < window.innerHeight - 140;
  };
  // Beatport's own Play for the chart or playlist first; guess only without it.
  const candidates = () => {
    const exact = [...document.querySelectorAll('[data-testid="play-button"]')].filter(visibleInPage);
    if (exact.length) return exact;
    return [...document.querySelectorAll("button, [role=button]")].filter((el) => isPlayish(el) && visibleInPage(el));
  };

  let tries = 0;
  clearInterval(timer);
  timer = setInterval(() => {
    tries += 1;
    const found = candidates();
    if (found.length) {
      clearInterval(timer);
      console.info("[Baseline] pressing", found[0]);
      found[0].click();
    } else if (tries > 60) {
      clearInterval(timer);
      console.warn("[Baseline] no Play button found");
    }
  }, 250);
  };
  run();
  // Asking for the page that's already open only changes the hash.
  window.addEventListener("hashchange", run);
})();
