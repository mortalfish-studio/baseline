// Tell Baseline which playlists are in Beatport's sidebar (name and link).
(() => {
  const collect = () => {
    const seen = new Map();
    for (const a of document.querySelectorAll("a[href]")) {
      const href = a.href.split("?")[0].split("#")[0].replace(/\/$/, "");
      if (!/^https:\/\/www\.beatport\.com\/library\/playlists\/\d+$/.test(href)) continue;
      const name = (a.textContent || "").trim().replace(/\s+/g, " ");
      // Skip links and other page furniture can point at the same playlist.
      if (!name || name.length > 60 || /^skip to\b/i.test(name) || a.closest("[class*=skip i]")) continue;
      if (!seen.has(href)) seen.set(href, name);
    }
    return [...seen].map(([url, name]) => ({ name, url })).slice(0, 30);
  };
  let last = "";
  const send = () => {
    const items = collect();
    const key = JSON.stringify(items);
    // Pages without the library sidebar report nothing; keep the last list.
    if (items.length && key !== last) {
      last = key;
      chrome.runtime.sendMessage({ type: "playlists", items }).catch(() => {});
    }
  };
  // Wake the extension's bridge as soon as Beatport opens.
  chrome.runtime.sendMessage({ type: "hello" }).catch(() => {});
  setTimeout(send, 3000);
  setInterval(send, 60000);
})();
