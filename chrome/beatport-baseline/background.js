// The bridge between Baseline and Beatport. A small local helper
// (afterlight's native host, repo chrome/native) passes Baseline's requests
// in and the page's playlists out; the open port also keeps this worker awake.
// Every request carries an id, and its reply comes back with the same id.
const HOST = "com.mortalfish.baseline_beatport";
const BEATPORT = /^https:\/\/www\.beatport\.com\//;
let port = null;

function connect() {
  try {
    port = chrome.runtime.connectNative(HOST);
  } catch (error) {
    port = null;
    setTimeout(() => { if (!port) connect(); }, 10000);
    return;
  }
  port.onMessage.addListener((message) => {
    handle(message)
      .then((reply) => port && port.postMessage({ id: message.id, type: "reply", ...reply }))
      .catch((error) => port && port.postMessage({ id: message.id, type: "reply", error: String(error) }));
  });
  port.onDisconnect.addListener(() => { port = null; setTimeout(() => { if (!port) connect(); }, 10000); });
  port.postMessage({ type: "hello" });
}

async function beatportTabs() {
  const tabs = await chrome.tabs.query({ url: "https://www.beatport.com/*" });
  const rank = async (t) => {
    let app = false;
    try { app = (await chrome.windows.get(t.windowId)).type === "app"; } catch (error) { /* window gone */ }
    // The player: the tab playing audio, then the Beatport app window.
    return (t.audible ? 2 : 0) + (app ? 1 : 0);
  };
  const scored = await Promise.all(tabs.map(async (t) => [await rank(t), t]));
  return scored.sort((a, b) => b[0] - a[0]).map(([, t]) => t);
}

const YTMUSIC = /^https:\/\/music\.youtube\.com\//;
async function ytmusicTab() {
  const tabs = (await chrome.tabs.query({ url: "https://music.youtube.com/*" })).filter((t) => t.id !== scratchId);
  const scored = await Promise.all(tabs.map(async (t) => {
    let app = false;
    try { app = (await chrome.windows.get(t.windowId)).type === "app"; } catch (error) { /* gone */ }
    return [(t.audible ? 2 : 0) + (app ? 1 : 0), t];
  }));
  return scored.sort((a, b) => b[0] - a[0]).map(([, t]) => t)[0] || null;
}

const APPLEMUSIC = /^https:\/\/music\.apple\.com\//;
async function appleMusicTab() {
  const tabs = await chrome.tabs.query({ url: "https://music.apple.com/*" });
  const scored = await Promise.all(tabs.map(async (t) => {
    let app = false;
    try { app = (await chrome.windows.get(t.windowId)).type === "app"; } catch (error) { /* gone */ }
    return [(t.audible ? 2 : 0) + (app ? 1 : 0), t];
  }));
  return scored.sort((a, b) => b[0] - a[0]).map(([, t]) => t)[0] || null;
}

// Apple Music's web player is Apple's own MusicKit, which lives in the page's
// world, out of reach of a content script. This one fixed function runs
// there: it reads what's playing, queues a catalog album, playlist or songs
// by id, and plays, pauses, skips or seeks. Only checked ids and actions go in.
const AM_ID = /^(\d{1,15}|pl\.[A-Za-z0-9.-]{1,80})$/;
// A catalogue playlist (pl.…) or one of yours in your library (p.…).
const AM_PLAYLIST = /^(pl\.[A-Za-z0-9.-]{1,80}|p\.[A-Za-z0-9]{1,40})$/;
async function appleMusic(op, tab) {
  tab = tab || await appleMusicTab();
  if (!tab) return { ok: false, error: "no Apple Music tab" };
  const actions = ["now", "queue", "play", "pause", "toggle", "next", "previous", "seek", "playlists", "tracks"];
  if (!op || !actions.includes(op.action)) return { ok: false };
  const clean = { action: op.action };
  if (op.action === "queue") {
    if (!["song", "album", "playlist", "songs"].includes(op.kind)) return { ok: false };
    clean.kind = op.kind;
    if (op.kind === "songs") {
      clean.ids = (Array.isArray(op.ids) ? op.ids : []).filter((i) => AM_ID.test(String(i))).slice(0, 50).map(String);
      if (!clean.ids.length) return { ok: false };
    } else {
      if (!AM_ID.test(String(op.id))) return { ok: false };
      clean.id = String(op.id);
    }
    if (op.start !== undefined) {
      if (!AM_ID.test(String(op.start))) return { ok: false };
      clean.start = String(op.start);
    }
  }
  if (op.action === "playlists") {
    clean.term = String(op.term || "").slice(0, 100);
    if (!clean.term.trim()) return { ok: false };
  }
  if (op.action === "tracks") {
    if (!AM_PLAYLIST.test(String(op.id))) return { ok: false };
    clean.id = String(op.id);
  }
  if (op.action === "seek") {
    clean.seconds = Number(op.seconds);
    if (!Number.isFinite(clean.seconds) || clean.seconds < 0 || clean.seconds > 86400) return { ok: false };
  }
  const [result] = await chrome.scripting.executeScript({
    target: { tabId: tab.id },
    world: "MAIN",
    args: [clean],
    func: async (op) => {
      const kit = window.MusicKit && window.MusicKit.getInstance && window.MusicKit.getInstance();
      if (!kit) return { ok: false, error: "not ready" };
      const now = () => {
        const n = kit.nowPlayingItem;
        if (!n) return null;
        const a = n.attributes || {};
        return { id: String(n.id || ""), title: a.name || n.title || "", artist: a.artistName || n.artistName || "",
                 album: a.albumName || n.albumName || "",
                 container: n.container ? { type: String(n.container.type || ""), id: String(n.container.id || "") } : null };
      };
      const state = () => ({ ok: true, signedIn: !!kit.isAuthorized, playing: !!kit.isPlaying,
                             time: Math.floor(kit.currentPlaybackTime || 0),
                             duration: Math.floor(kit.currentPlaybackDuration || 0), item: now() });
      if (op.action === "now") return state();
      // Reading only: playlists for a search (yours, then the catalogue's),
      // and a playlist's songs as catalogue songs (what Sonos can play).
      const art = (a) => (a && a.url ? String(a.url).replace("{w}", "300").replace("{h}", "300") : "");
      const api = async (path, query) => ((await kit.api.music(path, query)) || {}).data || {};
      const sf = kit.storefrontId || "us";
      if (op.action === "playlists") {
        const items = [];
        const words = op.term.toLowerCase().split(/\s+/).filter(Boolean);
        if (kit.isAuthorized) {
          try {
            let next = "/v1/me/library/playlists", pages = 0;
            while (next && pages++ < 4) {
              const page = await api(next, next.includes("?") ? {} : { limit: 100 });
              for (const p of page.data || []) {
                const name = String((p.attributes || {}).name || "");
                if (words.every((w) => name.toLowerCase().includes(w)))
                  items.push({ id: p.id, name, curator: "Your playlist", art: art((p.attributes || {}).artwork), library: true });
              }
              next = page.next || "";
            }
          } catch (error) { /* library not available */ }
        }
        try {
          const found = await api(`/v1/catalog/${sf}/search`, { term: op.term, types: "playlists", limit: 12 });
          for (const p of ((found.results || {}).playlists || {}).data || []) {
            const a = p.attributes || {};
            items.push({ id: p.id, name: a.name || "", curator: a.curatorName || "Apple Music", art: art(a.artwork), library: false });
          }
        } catch (error) { /* search failed */ }
        return { ok: true, items: items.slice(0, 30) };
      }
      if (op.action === "tracks") {
        const mine = op.id.startsWith("p.");
        if (mine && !kit.isAuthorized) return { ok: false, error: "signed out" };
        const items = [];
        let next = mine ? `/v1/me/library/playlists/${op.id}/tracks` : `/v1/catalog/${sf}/playlists/${op.id}/tracks`;
        let pages = 0;
        try {
          while (next && pages++ < 4 && items.length < 300) {
            const page = await api(next, next.includes("?") ? {} : { limit: 100 });
            for (const t of page.data || []) {
              const a = t.attributes || {};
              const id = mine ? String((a.playParams || {}).catalogId || "") : String(t.id || "");
              if (/^\d{1,15}$/.test(id))
                items.push({ id, title: a.name || "", artist: a.artistName || "", album: a.albumName || "", art: art(a.artwork) });
            }
            next = page.next || "";
          }
        } catch (error) { if (!items.length) return { ok: false, error: String(error) }; }
        return { ok: true, items };
      }
      if (op.action === "queue") {
        if (!kit.isAuthorized) return { ok: false, error: "signed out" };
        const what = op.kind === "songs" ? { songs: op.ids } : { [op.kind]: op.id };
        await kit.setQueue({ ...what, startPlaying: false });
        const items = (kit.queue && kit.queue.items) || [];
        const at = op.start ? items.findIndex((i) => String(i.id) === op.start) : -1;
        if (at > 0) await kit.changeToMediaAtIndex(at); else await kit.play();
        return state();
      }
      if (op.action === "play" || (op.action === "toggle" && !kit.isPlaying)) await kit.play();
      else if (op.action === "pause" || op.action === "toggle") await kit.pause();
      else if (op.action === "next") await kit.skipToNextItem();
      else if (op.action === "previous") await kit.skipToPreviousItem();
      else if (op.action === "seek") await kit.seekToTime(op.seconds);
      return state();
    },
  }).catch((error) => [{ result: { ok: false, error: String(error) } }]);
  return (result && result.result) || { ok: false };
}

async function beatportTab() {
  return (await beatportTabs())[0] || null;
}

// Ask the page's bridge.js; if the page was open before the extension
// loaded, put bridge.js in first, so the page never needs a reload.
async function askPage(tab, op) {
  try {
    return await chrome.tabs.sendMessage(tab.id, op);
  } catch (error) {
    await chrome.scripting.executeScript({ target: { tabId: tab.id }, files: ["bridge.js"] });
    return await chrome.tabs.sendMessage(tab.id, op);
  }
}

// ---- Background tab for jobs that mustn't touch the player.
let scratchId = null;

function loaded(tabId, timeout = 20000) {
  return new Promise((resolve) => {
    const done = (ok) => { chrome.tabs.onUpdated.removeListener(listen); clearTimeout(timer); resolve(ok); };
    const listen = (id, info) => { if (id === tabId && info.status === "complete") done(true); };
    const timer = setTimeout(() => done(false), timeout);
    chrome.tabs.onUpdated.addListener(listen);
    chrome.tabs.get(tabId).then((t) => { if (t.status === "complete" && !t.pendingUrl) done(true); }, () => done(false));
  });
}

async function scratchTab(url) {
  if (typeof url !== "string" || !(BEATPORT.test(url) || YTMUSIC.test(url))) return null;
  let tab = null;
  if (scratchId !== null) tab = await chrome.tabs.get(scratchId).catch(() => null);
  if (tab && tab.url.split("#")[0] !== url.split("#")[0]) {
    tab = await chrome.tabs.update(tab.id, { url });
  } else if (!tab) {
    const normal = (await chrome.windows.getAll({ windowTypes: ["normal"] }))[0];
    if (normal) {
      tab = await chrome.tabs.create({ windowId: normal.id, url, active: false });
    } else {
      const win = await chrome.windows.create({ url, focused: false, state: "minimized" });
      tab = win.tabs[0];
    }
    scratchId = tab.id;
    // Never let it make a sound.
    await chrome.tabs.update(tab.id, { muted: true }).catch(() => {});
  }
  await loaded(tab.id);
  await new Promise((r) => setTimeout(r, 1500));   // Beatport fills the page in after load
  return tab;
}

// ---- One thing playing at a time: when a Beatport or YouTube tab starts
// making sound, pause the others.
const MEDIA = /^https:\/\/(www\.beatport\.com|www\.youtube\.com|music\.youtube\.com|music\.apple\.com)\//;
function pauseIn(tab) {
  if (APPLEMUSIC.test(tab.url)) return appleMusic({ action: "pause" }, tab);
  const beatport = /beatport\.com/.test(tab.url);
  return chrome.scripting.executeScript({
    target: { tabId: tab.id },
    args: [beatport],
    func: (isBeatport) => {
      if (isBeatport) {
        // Beatport's own Pause in the player bar keeps its UI in step.
        const bar = [...document.querySelectorAll("button[aria-label=Pause]")]
          .filter((b) => b.getBoundingClientRect().top > window.innerHeight - 160);
        if (bar[0]) { bar[0].click(); return "bar"; }
      }
      document.querySelectorAll("video, audio").forEach((m) => { if (!m.paused) m.pause(); });
      return "media";
    },
  }).catch(() => {});
}
let lastAudible = null;
async function mediaAction(action) {
  const tabs = (await chrome.tabs.query({})).filter((t) => MEDIA.test(t.url || "") && t.id !== scratchId);
  const tab = tabs.find((t) => t.audible) || tabs.find((t) => t.id === lastAudible) || tabs[0];
  if (!tab || !["play", "pause", "toggle", "next", "previous"].includes(action)) return { ok: false };
  if (APPLEMUSIC.test(tab.url)) {
    const reply = await appleMusic({ action }, tab);
    return { ok: !!reply.ok, site: reply.ok ? "applemusic" : "", title: tab.title };
  }
  const [result] = await chrome.scripting.executeScript({
    target: { tabId: tab.id },
    args: [action],
    func: (act) => {
      const host = location.hostname;
      const press = (selectors) => {
        for (const s of selectors) {
          const el = document.querySelector(s);
          if (el && el.getBoundingClientRect().width > 0) { el.click(); return true; }
        }
        return false;
      };
      if (host === "www.beatport.com") {
        const label = { play: "Play", pause: "Pause", next: "Next track", previous: "Previous track" }[act];
        const bar = [...document.querySelectorAll("button[aria-label]")].filter((b) =>
          b.getBoundingClientRect().top > window.innerHeight - 160
          && (act === "toggle" ? /^(Play|Pause)$/.test(b.getAttribute("aria-label")) : b.getAttribute("aria-label") === label));
        if (bar[0]) { bar[0].click(); return "beatport"; }
        return "";
      }
      if (host === "music.youtube.com") {
        const ok = { next: () => press(["tp-yt-paper-icon-button.next-button", ".next-button"]),
                     previous: () => press(["tp-yt-paper-icon-button.previous-button", ".previous-button"]) }[act];
        if (ok) return ok() ? "ytmusic" : "";
      }
      if (act === "next" && press([".ytp-next-button"])) return "youtube";
      if (act === "previous") { history.back(); return "youtube"; }
      const media = [...document.querySelectorAll("video, audio")].find((m) => m.currentSrc) ;
      if (!media) return "";
      if (act === "play" || (act === "toggle" && media.paused)) media.play(); else media.pause();
      return "media";
    },
  });
  return { ok: !!(result && result.result), site: result && result.result, title: tab.title };
}

chrome.tabs.onUpdated.addListener(async (tabId, info, tab) => {
  if (info.audible === true && MEDIA.test(tab.url || "")) {
    lastAudible = tabId;
    // Tell Baseline where the music is coming from.
    const site = /beatport\.com/.test(tab.url) ? "beatport" : /music\.youtube\.com/.test(tab.url) ? "ytmusic"
      : APPLEMUSIC.test(tab.url) ? "applemusic" : "youtube";
    if (tabId !== scratchId && port) port.postMessage({ type: "source", site });
  }
  if (info.audible !== true || !MEDIA.test(tab.url || "") || tabId === scratchId) return;
  const others = await chrome.tabs.query({ audible: true });
  for (const other of others) {
    if (other.id !== tabId && MEDIA.test(other.url || "")) pauseIn(other);
  }
});

async function handle(message) {
  if (!message || typeof message !== "object") return { ok: false };
  if (message.type === "open") {
    if (typeof message.url !== "string" || !(BEATPORT.test(message.url) || YTMUSIC.test(message.url))) return { ok: false };
    const tab = YTMUSIC.test(message.url) ? await ytmusicTab() : await beatportTab();
    if (!tab) return { inPlace: false };
    const url = message.url.split("#")[0] + (message.play ? "#baseline-play" : "");
    await chrome.tabs.update(tab.id, { url });
    return { inPlace: true };
  }
  if (message.type === "check") {
    // Fetch pages without showing them: does each link exist, and what's it called?
    const urls = (Array.isArray(message.urls) ? message.urls : []).filter((u) => BEATPORT.test(u)).slice(0, 40);
    const results = [];
    for (const url of urls) {
      try {
        const response = await fetch(url, { credentials: "include", redirect: "follow" });
        const html = await response.text();
        const title = (html.match(/<title[^>]*>([^<]*)<\/title>/i) || [, ""])[1].trim();
        results.push({ url, status: response.status, finalUrl: response.url, title: title.slice(0, 120) });
      } catch (error) {
        results.push({ url, status: 0, error: String(error) });
      }
    }
    return { results };
  }
  if (message.type === "page") {
    // Read or press something on the open Beatport (or, with site
    // "ytmusic", YouTube Music) page (see bridge.js).
    const tab = message.site === "ytmusic" ? await ytmusicTab() : await beatportTab();
    if (!tab) return { ok: false, error: "no Beatport tab" };
    return await askPage(tab, message.op || {});
  }
  if (message.type === "fetch") {
    // A Beatport page's HTML (search results, say), fetched without showing it.
    if (typeof message.url !== "string" || !BEATPORT.test(message.url)) return { ok: false };
    const response = await fetch(message.url, { credentials: "include" });
    const text = await response.text();
    return { ok: response.ok, status: response.status, text: text.slice(0, 3000000) };
  }
  if (message.type === "scratch") {
    // Do something on a Beatport page in a background tab, leaving the
    // player alone: open (or reuse) the tab at url, then run op there.
    const tab = await scratchTab(message.url);
    if (!tab) return { ok: false, error: "couldn't open a background tab" };
    return message.op ? await askPage(tab, message.op) : { ok: true };
  }
  if (message.type === "scratch-close") {
    if (scratchId !== null) await chrome.tabs.remove(scratchId).catch(() => {});
    scratchId = null;
    return { ok: true };
  }
  if (message.type === "media") {
    // Play, pause or skip in whichever Beatport / YouTube / YouTube Music tab
    // is playing (or was last), for when the system's media controls miss it.
    return await mediaAction(String(message.action || ""));
  }
  if (message.type === "applemusic") {
    // Apple Music's own player: what's playing, or queue and play by id.
    return await appleMusic(message.op || {});
  }
  if (message.type === "tabs") {
    return { tabs: (await beatportTabs()).map((t) => ({ id: t.id, url: t.url, audible: !!t.audible, title: t.title })) };
  }
  return { ok: false };
}

chrome.runtime.onMessage.addListener((message) => {
  // Any Beatport page saying hello wakes this worker; make sure the bridge is up.
  if (!port) connect();
  if (message && message.type === "playlists" && port) port.postMessage(message);
});

// Wake with Chrome (after a reboot nothing else would), and after an update.
chrome.runtime.onStartup.addListener(() => { if (!port) connect(); });
chrome.runtime.onInstalled.addListener(() => { if (!port) connect(); });

connect();
