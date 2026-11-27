// Lets Baseline look at and press the page's own controls, for jobs like
// "add the playing track to <3". It can only list visible controls and click
// one; it never runs code it's sent.
(() => {
  // Loaded by the manifest and maybe again by background.js: listen once
  // per version (a reloaded extension brings a newer one).
  const VERSION = chrome.runtime.getManifest().version;
  if (window.__baselineBridge === VERSION) return;
  window.__baselineBridge = VERSION;
  const CLICKABLE = "button, a[href], [role=button], [role=menuitem], [role=option], [role=menuitemcheckbox], li, label, tp-yt-paper-icon-button, yt-button-shape, tp-yt-paper-item";
  // The words on the row a bare control sits in (a tick box beside a name).
  const rowText = (el) => {
    let node = el.parentElement;
    for (let depth = 0; node && depth < 4; depth += 1, node = node.parentElement) {
      const text = (node.innerText || "").trim().replace(/\s+/g, " ");
      if (text) return text.length <= 80 ? text : "";
    }
    return "";
  };
  const describe = (el, i) => {
    const r = el.getBoundingClientRect();
    return {
      row: rowText(el).slice(0, 80),
      i, tag: el.tagName.toLowerCase(),
      label: (el.getAttribute("aria-label") || el.getAttribute("title") || "").slice(0, 80),
      testid: (el.getAttribute("data-testid") || "").slice(0, 80),
      href: (el.getAttribute("href") || "").slice(0, 200),
      text: (el.innerText || el.textContent || "").trim().replace(/\s+/g, " ").slice(0, 60),
      x: Math.round(r.x), y: Math.round(r.y), w: Math.round(r.width), h: Math.round(r.height),
    };
  };
  // Shown on the page, though maybe scrolled out of view (a tall dialog in a
  // small background tab); clicking scrolls it in first.
  const visible = (el) => {
    const r = el.getBoundingClientRect();
    if (r.width <= 0 || r.height <= 0) return false;
    const style = getComputedStyle(el);
    return style.visibility !== "hidden" && style.display !== "none" && style.opacity !== "0";
  };
  const inRegion = (el, region) => {
    if (!region || region === "any") return true;
    const r = el.getBoundingClientRect();
    // The player bar: the band along the bottom of the window, not below it.
    const bar = r.top >= window.innerHeight - 160 && r.top <= window.innerHeight;
    return region === "bar" ? bar : !bar;
  };
  const regex = (source) => (source ? new RegExp(source, "i") : null);
  const matches = (el, op) => {
    const d = describe(el, 0);
    const test = (re, value) => !re || re.test(value);
    return test(regex(op.label), d.label) && test(regex(op.testid), d.testid) && test(regex(op.text), d.text)
      && test(regex(op.href), d.href)
      && test(regex(op.row), d.row)
      && (!op.not || !regex(op.not).test([d.label, d.testid, d.text].join(" ")));
  };
  const find = (op) => [...document.querySelectorAll(CLICKABLE)]
    .filter((el) => visible(el) && inRegion(el, op.region) && matches(el, op));
  const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

  async function clickWhenReady(op) {
    const until = Date.now() + Math.min(op.wait || 3000, 10000);
    for (;;) {
      const found = find(op);
      // On screen before scrolled away; then the smallest match, which is the
      // control itself rather than a list that holds it.
      const offscreen = (el) => { const r = el.getBoundingClientRect(); return r.bottom < 0 || r.top > window.innerHeight ? 1 : 0; };
      const area = (el) => el.getBoundingClientRect().width * el.getBoundingClientRect().height;
      found.sort((a, b) => offscreen(a) - offscreen(b) || area(a) - area(b));
      const el = found[op.nth || 0];
      if (el) {
        const d = describe(el, 0);
        el.scrollIntoView({ block: "center", inline: "nearest" });
        el.click();
        return { ok: true, clicked: d };
      }
      if (Date.now() > until) return { ok: false, missing: op };
      await sleep(150);
    }
  }

  // Your YouTube Music library (playlists and the like), asked for the way
  // the page asks: signed in with your own cookies, from this page. Only
  // fixed library pages (browse ids starting FEmusic_) can be read.
  async function ytmBrowse(browseId) {
    if (!/^FEmusic_[a-z_]+$/.test(String(browseId))) return { ok: false };
    const sapisid = (document.cookie.match(/(?:^|;\s*)(?:__Secure-3PAPISID|SAPISID)=([^;]+)/) || [])[1];
    if (!sapisid) return { ok: false, error: "signed out" };
    const html = document.documentElement.innerHTML;
    const version = (html.match(/"INNERTUBE_CLIENT_VERSION":"([^"]+)"/) || [])[1] || "1.20261118.01.00";
    const stamp = Math.floor(Date.now() / 1000);
    const digest = await crypto.subtle.digest("SHA-1", new TextEncoder().encode(`${stamp} ${sapisid} https://music.youtube.com`));
    const hash = [...new Uint8Array(digest)].map((x) => x.toString(16).padStart(2, "0")).join("");
    const response = await fetch("/youtubei/v1/browse?prettyPrint=false", {
      method: "POST",
      credentials: "include",
      headers: { "Content-Type": "application/json", "Authorization": `SAPISIDHASH ${stamp}_${hash}`,
                 "X-Origin": "https://music.youtube.com", "X-Goog-AuthUser": "0" },
      body: JSON.stringify({ context: { client: { clientName: "WEB_REMIX", clientVersion: version, hl: "en" } }, browseId }),
    });
    return { ok: response.ok, status: response.status, text: (await response.text()).slice(0, 3000000) };
  }

  async function run(op) {
    if (op.type === "probe") {
      const items = [...document.querySelectorAll(CLICKABLE)]
        .filter((el) => visible(el) && inRegion(el, op.region) && (!op.filter || matches(el, { text: op.filter }) || matches(el, { label: op.filter }) || matches(el, { testid: op.filter }) || matches(el, { href: op.filter })))
        .slice(0, 120).map(describe);
      return { ok: true, url: location.href, height: window.innerHeight, items };
    }
    if (op.type === "click") return clickWhenReady(op);
    if (op.type === "ytm-browse" && location.hostname === "music.youtube.com") return ytmBrowse(op.browseId);
    if (op.type === "steps") {
      const done = [];
      for (const step of (op.steps || []).slice(0, 8)) {
        if (step.type === "key" && step.key === "Escape") {
          document.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
          done.push({ ok: true, key: "Escape" });
          continue;
        }
        const result = await clickWhenReady(step);
        done.push(result);
        if (!result.ok && !step.optional) return { ok: false, steps: done };
        await sleep(step.pause || 300);
      }
      return { ok: true, steps: done };
    }
    return { ok: false };
  }

  chrome.runtime.onMessage.addListener((op, _sender, reply) => {
    if (!op || typeof op !== "object" || !op.type) return false;
    run(op).then(reply, (error) => reply({ ok: false, error: String(error) }));
    return true;
  });
})();
