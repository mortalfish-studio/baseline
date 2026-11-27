// Lets Baseline look at and press the page's own controls, for jobs like
// "add the playing track to <3". It can list visible controls and click one,
// set the player's volume, and make a new playlist from checked ids; it
// never runs code it's sent.
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
      // first: the first on the page instead (a track page's own Play, above
      // the recommendations, even when scrolled away from it).
      if (!op.first) found.sort((a, b) => offscreen(a) - offscreen(b) || area(a) - area(b));
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
  async function ytmCall(endpoint, body) {
    const sapisid = (document.cookie.match(/(?:^|;\s*)(?:__Secure-3PAPISID|SAPISID)=([^;]+)/) || [])[1];
    if (!sapisid) return { ok: false, error: "signed out" };
    const html = document.documentElement.innerHTML;
    const version = (html.match(/"INNERTUBE_CLIENT_VERSION":"([^"]+)"/) || [])[1] || "1.20261118.01.00";
    const stamp = Math.floor(Date.now() / 1000);
    const digest = await crypto.subtle.digest("SHA-1", new TextEncoder().encode(`${stamp} ${sapisid} https://music.youtube.com`));
    const hash = [...new Uint8Array(digest)].map((x) => x.toString(16).padStart(2, "0")).join("");
    const response = await fetch(`/youtubei/v1/${endpoint}?prettyPrint=false`, {
      method: "POST",
      credentials: "include",
      headers: { "Content-Type": "application/json", "Authorization": `SAPISIDHASH ${stamp}_${hash}`,
                 "X-Origin": "https://music.youtube.com", "X-Goog-AuthUser": "0" },
      body: JSON.stringify({ context: { client: { clientName: "WEB_REMIX", clientVersion: version, hl: "en" } }, ...body }),
    });
    return { ok: response.ok, status: response.status, text: (await response.text()).slice(0, 3000000) };
  }
  async function ytmBrowse(browseId) {
    if (!/^FEmusic_[a-z_]+$/.test(String(browseId))) return { ok: false };
    return ytmCall("browse", { browseId });
  }

  // A new private playlist in your YouTube Music library, with these songs
  // (checked video ids only). Only ever creates; never changes or deletes.
  async function ytmExport(op) {
    const title = String(op.title || "").replace(/[\u0000-\u001f]/g, "").slice(0, 150);
    const ids = (Array.isArray(op.ids) ? op.ids : []).map(String).filter((v) => /^[\w-]{11}$/.test(v)).slice(0, 300);
    if (!title || !ids.length) return { ok: false };
    const reply = await ytmCall("playlist/create", { title, description: "Saved from Baseline's Deck", privacyStatus: "PRIVATE", videoIds: ids });
    let playlistId = "";
    try { playlistId = String(JSON.parse(reply.text || "{}").playlistId || ""); } catch (error) { /* not JSON */ }
    return { ok: reply.ok && !!playlistId, status: reply.status, playlistId };
  }

  // A new playlist in your Beatport library, with these tracks (checked ids
  // only), through Beatport's own API as the page is signed in. The sign-in
  // stays in this page. Only ever creates; never changes or deletes.
  async function beatportExport(op) {
    const name = String(op.name || "").replace(/[\u0000-\u001f]/g, "").slice(0, 100);
    const ids = (Array.isArray(op.ids) ? op.ids : []).map(Number).filter((n) => Number.isInteger(n) && n > 0 && n < 1e12).slice(0, 300);
    if (!name || !ids.length) return { ok: false };
    const session = await (await fetch("/api/auth/session", { credentials: "include" })).json().catch(() => ({}));
    const token = session && session.token && !session.token.anon ? session.token.accessToken : "";
    if (!token) return { ok: false, error: "signed out" };
    const api = (path, body) => fetch(`https://api.beatport.com/v4/my/playlists/${path}`, {
      method: "POST", headers: { "Content-Type": "application/json", "Authorization": `Bearer ${token}` }, body: JSON.stringify(body) });
    const made = await api("", { name });
    const playlist = await made.json().catch(() => ({}));
    if (!made.ok || !playlist.id) return { ok: false, status: made.status };
    const added = await api(`${playlist.id}/tracks/bulk/`, { track_ids: ids });
    return { ok: added.ok, status: added.status, id: playlist.id };
  }

  // The page's own player volume (0-1): Beatport's and YouTube Music's are
  // audio and video elements. Returns what it was, so it can be put back.
  function volume(op) {
    const media = [...document.querySelectorAll("audio, video")];
    const was = media.length ? media[0].volume : null;
    const level = Number(op.level);
    if (op.level !== undefined && op.level !== null && Number.isFinite(level)) {
      for (const el of media) el.volume = Math.max(0, Math.min(1, level));
    }
    return { ok: media.length > 0, level: was };
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
    if (op.type === "ytm-export" && location.hostname === "music.youtube.com") return ytmExport(op);
    if (op.type === "bp-export" && location.hostname === "www.beatport.com") return beatportExport(op);
    if (op.type === "volume") return volume(op);
    if (op.type === "pause-media") {
      // Pause this page's own players (not another tab's); dry only says it can.
      const media = [...document.querySelectorAll("audio, video")];
      if (!op.dry) for (const el of media) el.pause();
      return { ok: true, count: media.length };
    }
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
