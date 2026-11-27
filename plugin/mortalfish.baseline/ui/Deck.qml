import QtQuick
import QtQuick.Effects
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// The Deck: a set of songs you arrange by hand. Find songs on the left (or
// have Grok build a whole set from a brief), drag them into the set, drag
// them around it, onto a room along the bottom to play them there, or back
// from what's played. The set itself lives in `afterlight deck` (deck.json);
// this window shows it and sends every change there.
Item {
  id: root
  property var host: null
  signal closed()

  readonly property string tool: host ? host.afterlightPath : ""
  readonly property color amber: Commons.Color.accent
  readonly property color teal: host ? host.themeCyan : Commons.Color.foreground
  readonly property color ground: Commons.Color.background
  readonly property color ink: Commons.Color.popups.text

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("../i18n") }

  // ------------------------------------------------------------ where it sits
  // Its home is workspace 7, where it fills the screen. Opened from anywhere
  // else it pops up there, floating over the windows, and goes home again with
  // Escape or when you switch workspace. `silent` opens it at home without
  // taking you there (at login).
  readonly property int homeWorkspace: 7
  property bool popped: false
  property int poppedOn: -1
  readonly property int currentWorkspace: Hyprland.focusedWorkspace ? Hyprland.focusedWorkspace.id : -1
  // Only work (poll rooms, animate) while it can be seen.
  readonly property bool seen: window.visible && (popped || currentWorkspace === homeWorkspace)

  function show(silent) {
    window.visible = true
    read()
    if (root.host && root.host.refreshAfterlight) root.host.refreshAfterlight()
    if (silent) return
    placeTries = 0
    place.restart()
  }
  function target() {
    for (const t of Hyprland.toplevels.values) {
      if (t.title !== "Baseline Deck") continue
      let address = String(t.address || "")
      if (address && address.indexOf("0x") !== 0) address = "0x" + address
      if (/^0x[0-9a-f]+$/i.test(address)) return "window = \"address:" + address + "\""
    }
    return ""
  }
  function popHere() {
    const t = target()
    if (!t) return false
    const ws = currentWorkspace
    if (ws === homeWorkspace || ws < 1) {
      if (popped) goHome()
      Hyprland.dispatch("hl.dsp.focus({ workspace = \"" + homeWorkspace + "\" })")
    } else {
      Hyprland.dispatch("hl.dsp.window.move({ workspace = \"" + ws + "\", follow = false, " + t + " })")
      Hyprland.dispatch("hl.dsp.window.float({ action = \"on\", " + t + " })")
      Hyprland.dispatch("hl.dsp.window.resize({ x = 1240, y = 820, " + t + " })")
      Hyprland.dispatch("hl.dsp.window.center({ " + t + " })")
      Hyprland.dispatch("hl.dsp.focus({ " + t + " })")
      Hyprland.dispatch("hl.dsp.window.alter_zorder({ mode = \"top\", " + t + " })")
      poppedOn = ws
      popped = true
    }
    query.forceActiveFocus()
    return true
  }
  function goHome() {
    const t = target()
    popped = false
    if (!t) return
    Hyprland.dispatch("hl.dsp.window.float({ action = \"off\", " + t + " })")
    Hyprland.dispatch("hl.dsp.window.move({ workspace = \"" + homeWorkspace + "\", follow = false, " + t + " })")
  }
  // The window may still be on its way (just made, or shown again): try a few times.
  property int placeTries: 0
  Timer {
    id: place
    interval: 120
    onTriggered: if (!root.popHere() && ++root.placeTries < 20) restart()
  }
  onCurrentWorkspaceChanged: if (popped && currentWorkspace !== poppedOn) goHome()

  // ------------------------------------------------------------ the set
  property var deck: ({ now: null, set: [], played: [], pinned: [], where: { kind: "laptop" }, playing: false, rooms: [] })
  property var pos: ({ time: 0, length: 0, playing: false })
  property real shownTime: 0
  readonly property var now: deck.now
  readonly property string whereId: deck.where && deck.where.kind === "sonos" ? deck.where.room : "laptop"
  readonly property string whereName: {
    if (whereId === "laptop") return strings.t("deck.laptop")
    for (const r of deck.rooms || []) if (r.id === whereId) return r.name
    return "Sonos"
  }
  function pinned(uid) { return (deck.pinned || []).indexOf(uid) >= 0 }

  // ------------------------------------------------------------ rooms
  // Every Sonos room on its own, its group, its volume, and whether it's busy
  // with something else (the TV); `afterlight deck rooms`, every few seconds.
  readonly property bool inSonos: whereId !== "laptop"
  readonly property real tileWidth: strip.tileWidth
  readonly property bool open: seen
  readonly property Item stageItem: stage
  // One quiet tooltip for the whole Deck: a word under a glyph you rest on.
  property Item tipFor: null
  property string tipText: ""
  property point tipAt: Qt.point(0, 0)
  property bool tipShown: false
  function hint(item, text, on) {
    if (on && text !== "") {
      tipFor = item; tipText = text
      const at = item.mapToItem(stage, item.width / 2, item.height + 6)
      tipAt = Qt.point(at.x, at.y)
      tipDelay.restart()
    } else if (tipFor === item) { tipDelay.stop(); tipShown = false; tipFor = null }
  }
  Timer { id: tipDelay; interval: 450; onTriggered: root.tipShown = true }
  property var roomList: []
  property string roomText: ""
  readonly property var partyRooms: roomList.filter(r => r.here).sort((a, b) => (b.lead ? 1 : 0) - (a.lead ? 1 : 0))
  readonly property var otherRooms: roomList.filter(r => !r.here)
  // The laptop's output (speaker, headphones), while the Deck plays there.
  readonly property var laptopOut: root.deck.laptopOut || null
  readonly property string outGlyph: !laptopOut ? "󰕾" : laptopOut.kind === "headphones" ? "󰋋"
                                     : laptopOut.kind === "bluetooth" ? "󰂰" : laptopOut.muted ? "󰝟" : "󰕾"
  readonly property var hereVolume: root.inSonos
      ? (root.deck.roomVolume !== undefined && root.deck.roomVolume !== null ? root.deck.roomVolume : null)
      : (laptopOut && laptopOut.volume !== null && laptopOut.volume !== undefined ? laptopOut.volume : null)
  property bool roomHeld: false            // a volume being dragged: hold the list still
  function roomById(id) { for (const r of roomList) if (r.id === id) return r; return null }
  function readRooms() { if (!roomReader.running) roomReader.running = true }
  Process {
    id: roomReader
    command: [root.tool, "deck", "rooms"]
    stdout: StdioCollector {
      onStreamFinished: {
        // Only a real change rebuilds the tiles (a hover or a drag survives a poll).
        if (text === root.roomText || root.roomHeld || root.dragging) return
        try { root.roomList = JSON.parse(text).rooms || []; root.roomText = text } catch (error) {}
      }
    }
  }
  Timer {
    interval: 5000
    repeat: true
    running: root.seen
    triggeredOnStart: true
    onTriggered: root.readRooms()
  }

  function read() { if (!reader.running) reader.running = true; else readAgain = true }
  property bool readAgain: false
  Process {
    id: reader
    command: [root.tool, "deck", "state"]
    stdout: StdioCollector {
      onStreamFinished: {
        try { root.deck = JSON.parse(text); root.syncSet() } catch (error) {}
      }
    }
    onExited: if (root.readAgain) { root.readAgain = false; running = true }
  }
  Commons.WatchedFile {
    path: Quickshell.env("HOME") + "/.local/state/afterlight/deck.json"
    onTextChanged: if (window.visible) root.read()
  }
  Commons.WatchedFile {
    path: Quickshell.env("HOME") + "/.local/state/afterlight/deck-details.json"
    onTextChanged: if (window.visible) detailsSettle.restart()
  }
  // Details land a few at a time: read once they settle.
  Timer { id: detailsSettle; interval: 600; onTriggered: root.read() }
  Commons.WatchedFile {
    path: Quickshell.env("HOME") + "/.local/state/afterlight/deck-now.json"
    onTextChanged: {
      try {
        const v = JSON.parse(text)
        root.pos = v
        root.shownTime = v.time || 0
      } catch (error) {}
    }
  }
  // The watcher reports every couple of seconds while music plays; if it's
  // gone quiet, reading the state starts it again.
  Timer {
    interval: 15000
    repeat: true
    running: root.seen && root.deck.playing
    onTriggered: if (Date.now() / 1000 - (root.pos.at || 0) > 20) root.read()
  }
  // Between the watcher's reports, the clock keeps moving.
  Timer {
    interval: 1000
    repeat: true
    running: root.seen && root.deck.playing && root.pos.playing
    onTriggered: root.shownTime = Math.min(root.shownTime + 1, root.pos.length || root.shownTime + 1)
  }

  // The set as a ListModel kept in step with deck.set by moves, inserts and
  // removals, so reordering and shuffling animate instead of jumping.
  ListModel { id: setModel }
  function rowOf(song) {
    return { uid: song.uid, title: song.title || "", artist: song.artist || "", thumb: song.thumb || "",
             service: song.service || "", why: song.why || "", chapter: song.chapter || "",
             bpm: song.bpm || 0, key: song.key || "", energy: song.energy || 0, length: song.length || 0,
             from: song.from || "",
             warn: (song.warn || []).join(",") }
  }
  function sameRow(a, b) {
    for (const k in b) if (a[k] !== b[k]) return false
    return true
  }
  function syncSet() {
    const want = deck.set || []
    const ids = want.map(s => s.uid)
    for (let i = setModel.count - 1; i >= 0; i--) if (ids.indexOf(setModel.get(i).uid) < 0) setModel.remove(i)
    for (let i = 0; i < want.length; i++) {
      let at = -1
      for (let j = i; j < setModel.count; j++) if (setModel.get(j).uid === want[i].uid) { at = j; break }
      if (at < 0) setModel.insert(i, rowOf(want[i]))
      else if (at !== i) setModel.move(at, i, 1)
    }
    // Details arrive later (lengths, tempo, key): update the rows in place.
    for (let i = 0; i < want.length && i < setModel.count; i++) {
      const row = rowOf(want[i])
      if (!sameRow(setModel.get(i), row)) setModel.set(i, row)
    }
  }

  // One queue for every change, so a drag never races the one before it.
  property var queue: []
  property string status: ""
  readonly property bool busy: runner.running
  // Play, pause and next show at once, before the command (and the speaker)
  // answers; the next read puts in what really happened.
  function playPause() {
    const on = !deck.playing
    deck = Object.assign({}, deck, { playing: on, paused: !on })
    run(["deck", on ? "play" : "pause"])
  }
  function skip() {
    const set = deck.set || []
    if (set.length === 0) return
    deck = Object.assign({}, deck, { now: set[0], set: set.slice(1), playing: true,
                                     played: (deck.played || []).concat(deck.now ? [deck.now] : []) })
    syncSet()
    run(["deck", "next"])
  }
  function run(args) {
    queue = queue.concat([args])
    if (!runner.running) next()
  }
  function next() {
    if (queue.length === 0) { read(); readRooms(); return }
    const args = queue[0]
    queue = queue.slice(1)
    runner.command = [tool].concat(args)
    runner.running = true
  }
  Process {
    id: runner
    stderr: StdioCollector { id: runErr }
    onExited: function(code) {
      root.status = code !== 0 ? (runErr.text.trim().split("\n").pop() || strings.t("deck.failed")) : ""
      Qt.callLater(root.next)
    }
  }
  // Grok's jobs (fill, build) take a while: they run on their own.
  function runLong(args) { Quickshell.execDetached([tool].concat(args)) }

  // ------------------------------------------------------------ finding songs
  readonly property string savedService: host && host.afterState && host.afterState.settings.music
    ? host.afterState.settings.music.service || "ytmusic" : "ytmusic"
  property string pickedService: ""
  readonly property string service: pickedService !== "" ? pickedService : savedService
  function serviceName(id) { return id === "applemusic" ? "Apple Music" : id === "beatport" ? "Beatport" : "YouTube Music" }
  property var results: []
  property bool searching: finder.running
  Process {
    id: finder
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          const v = JSON.parse(text)
          root.results = (Array.isArray(v) ? v : []).filter(i => ["song", "video", "album", "playlist"].indexOf(i.kind) >= 0)
        } catch (error) { root.results = [] }
      }
    }
  }
  // An album or playlist opened in the crate, to pick songs out of it.
  property var openList: null
  property var listSongs: []
  readonly property bool listLoading: opener.running
  Process {
    id: opener
    stdout: StdioCollector {
      onStreamFinished: {
        try { const v = JSON.parse(text); root.listSongs = Array.isArray(v) ? v : [] } catch (error) { root.listSongs = [] }
      }
    }
  }
  function openPlaylist(item) {
    if (opener.running) return
    openList = item
    listSongs = []
    opener.command = [tool, "deck", "songs", service, JSON.stringify(item)]
    opener.running = true
  }
  function closePlaylist() { openList = null; listSongs = [] }
  function find(words) {
    openList = null
    if (words.trim() === "" || finder.running) return
    finder.command = [tool, "deck", "search", service, words.trim()]
    finder.running = true
  }

  // ------------------------------------------------------------ dragging
  // One ghost for every drag: from the results, the set or what's played.
  // It's dropped on a row of the set (goes before it), the end of the set,
  // the cover (plays now) or a room (plays there).
  property bool dragging: false
  property string dragFrom: ""          // "set" | "played" | "found"
  property string dragUid: ""
  property var dragItem: null           // a search result, when dragFrom is "found"
  property string dragTitle: ""
  property string dragThumb: ""
  property int dropIndex: -1
  // The crate (Build a set and search) folds away to give the music room;
  // remembered in settings (deck.crate).
  property bool crateFolded: false
  // A song picked in the crate to grow a set (or Auto-DJ) from.
  property var seed: null
  // The Build card stays a single line until you open it (or pick a seed).
  property bool buildOpen: false
  readonly property bool buildShown: buildOpen || !!seed
  property string seedService: ""
  readonly property bool crateOpen: !crateFolded
  function applyCrate() {
    const d = root.host && root.host.afterState ? root.host.afterState.settings.deck : null
    if (d && typeof d.crate === "boolean") root.crateFolded = !d.crate
  }
  Component.onCompleted: applyCrate()
  Connections {
    target: root.host
    function onAfterStateChanged() { root.applyCrate() }
  }
  function setCrate(open) {
    crateFolded = !open
    Quickshell.execDetached([tool, "set", "deck.crate", open ? "true" : "false"])
  }

  // ------------------------------------------------------------ the Bloom
  // Where should this go? Four petals around the pointer: Now (up), Next
  // (right), Later, at the end (down), and Somewhere (left: one song at a
  // random spot, an album or playlist mixed through the set). For a song
  // already in the set the left petal removes it. Tap a petal, or hold, flick
  // toward one and let go; the cover then flies to where it landed.
  property bool bloomOpen: false
  property bool bloomFlick: false
  property string bloomFrom: ""            // "found" | "set"
  property var bloomItem: null
  property string bloomUid: ""
  property int bloomPick: -1
  property point bloomAt: Qt.point(0, 0)
  readonly property bool bloomMany: !!bloomItem && (bloomItem.kind === "album" || bloomItem.kind === "playlist")
  readonly property var savePetals: [
    { key: "applemusic", glyph: "󰀵", label: "Apple Music", angle: 0 },
    { key: "ytmusic", glyph: "󰗃", label: "YouTube Music", angle: 90 },
    { key: "beatport", glyph: "󰋋", label: "Beatport", angle: 180 }
  ]
  // Save and Export use the same flower: where to (here, or a new playlist on a service).
  readonly property var petals: bloomFrom === "save" ? [{ key: "baseline", glyph: "󰆓", label: strings.t("deck.saveHere"), angle: -90 }].concat(savePetals)
    : bloomFrom === "export" ? savePetals.map((p, i) => Object.assign({}, p, { angle: [-90, 30, 150][i] }))
    : [
    { key: "now", glyph: "󰐊", label: strings.t("deck.bloomNow"), angle: -90 },
    { key: "next", glyph: "󰒭", label: strings.t("deck.bloomNext"), angle: 0 },
    { key: "later", glyph: "󰐒", label: strings.t("deck.bloomLater"), angle: 90 },
    bloomFrom === "set" ? { key: "remove", glyph: "󰅖", label: strings.t("deck.remove"), angle: 180 }
                        : { key: "somewhere", glyph: "󰒝", label: strings.t(bloomMany ? "deck.bloomMix" : "deck.bloomSomewhere"), angle: 180 }
  ]
  function tapFound(item, at) {
    if (!deck.playing) run(["deck", "add", service, JSON.stringify(item), "--play"])     // nothing to interrupt
    else openBloom("found", item, "", at)
  }
  function openBloom(from, item, uid, at) {
    if (dragging) return
    bloomFrom = from; bloomItem = item; bloomUid = uid; bloomPick = -1; bloomFlick = false
    const m = 120
    bloomAt = Qt.point(Math.max(m, Math.min(stage.width - m, at.x)), Math.max(m, Math.min(stage.height - m, at.y)))
    bloomOpen = true
  }
  function closeBloom() { bloomOpen = false; bloomFlick = false; bloomPick = -1 }
  function aimBloom(at) {
    const dx = at.x - bloomAt.x, dy = at.y - bloomAt.y
    if (Math.hypot(dx, dy) < 28) { bloomPick = -1; return }
    const angle = Math.atan2(dy, dx) * 180 / Math.PI
    let best = -1, gap = 999
    for (let i = 0; i < petals.length; i++) {
      const d = Math.abs(((angle - petals[i].angle + 540) % 360) - 180)
      if (d < gap) { gap = d; best = i }
    }
    bloomPick = best
  }
  function releaseFlick() {
    bloomFlick = false
    if (bloomPick >= 0) chooseBloom(bloomPick)
  }
  function chooseBloom(i) {
    const key = petals[i].key
    const item = bloomItem
    const count = (deck.set || []).length
    if (bloomFrom === "save") {
      saveTo = key
      saveAs(item.title)
      closeBloom()
      return
    }
    if (bloomFrom === "export") {
      runLong(["deck", "export", key, item.title, "--saved"])
      closeBloom()
      return
    }
    if (bloomFrom === "found") {
      const json = JSON.stringify(item)
      if (key === "now") run(["deck", "add", service, json, "--play"])
      else if (key === "next") run(["deck", "add", service, json, "--next"])
      else if (key === "later") run(["deck", "add", service, json])
      else run(["deck", "add", service, json, "--scatter"])
    } else if (selectedUids.length > 1 && selected[bloomUid]) {
      placePicked(key === "later" ? "end" : key)
    } else {
      if (key === "now") run(["deck", "play", bloomUid])
      else if (key === "next") run(["deck", "move", bloomUid, "0"])
      else if (key === "later") run(["deck", "move", bloomUid, String(count)])
      else run(["deck", "remove", bloomUid])
    }
    fly(key, item ? item.thumb || "" : "")
    closeBloom()
  }

  // The cover's flight to where it landed, and a glow there.
  function fly(key, thumb) {
    const top = setList.mapToItem(stage, 0, 0)
    const listBottom = Math.min(setList.contentHeight, setList.height)
    let to, glow
    if (key === "now") {
      const c = nowCover.mapToItem(stage, 0, 0)
      to = Qt.point(c.x + 88, c.y + 88); glow = Qt.rect(c.x - 6, c.y - 6, 188, 188)
    } else if (key === "next") {
      to = Qt.point(top.x + 80, top.y + 30); glow = Qt.rect(top.x, top.y, setList.width, 62)
    } else if (key === "later") {
      to = Qt.point(top.x + 80, top.y + Math.max(30, listBottom - 30)); glow = Qt.rect(top.x, top.y + Math.max(0, listBottom - 62), setList.width, 62)
    } else if (key === "somewhere") {
      to = Qt.point(top.x + 80, top.y + Math.max(30, listBottom / 2)); glow = Qt.rect(top.x, top.y, setList.width, Math.max(62, listBottom))
    } else {
      to = Qt.point(bloomAt.x, bloomAt.y + 40); glow = Qt.rect(0, 0, 0, 0)
    }
    flyer.thumb = thumb
    flyer.removing = key === "remove"
    flyer.fromX = bloomAt.x - 24; flyer.fromY = bloomAt.y - 24
    flyer.toX = to.x - 24; flyer.toY = to.y - 24
    landing.x = glow.x; landing.y = glow.y; landing.width = glow.width; landing.height = glow.height
    flight.restart()
  }

  function beginDrag(from, uid, item, title, thumb) {
    dragFrom = from; dragUid = uid; dragItem = item; dragTitle = title; dragThumb = thumb
    dropIndex = -1
    dragging = true
  }
  function moveGhost(point) {
    ghost.x = point.x + 14
    ghost.y = point.y - ghost.height / 2
    const p = setList.mapFromItem(stage, point.x, point.y)
    const edge = 56
    edgeSpeed = (p.x < 0 || p.x > setList.width || root.wall) ? 0
              : p.y < edge && p.y > -40 ? -Math.ceil((edge - p.y) / 4)
              : p.y > setList.height - edge && p.y < setList.height + 40 ? Math.ceil((p.y - setList.height + edge) / 4) : 0
  }
  function endDrag() {
    edgeSpeed = 0
    ghost.Drag.drop()
    dragging = false
    dropIndex = -1
  }
  function dropInSet(index) {
    if (dragFrom === "chapter") {
      run(["deck", "move-chapter", dragUid, String(Math.max(0, index))])
      return
    }
    if (dragFrom === "found") {
      run(["deck", "add", service, JSON.stringify(dragItem), "--at", String(Math.max(0, index))])
      return
    }
    let target = index
    if (dragFrom === "set") {
      const from = (deck.set || []).findIndex(s => s.uid === dragUid)
      if (from >= 0 && from < index) target = index - 1
      if (from === target) return
      // Move it here at once; the engine catches up.
      if (from >= 0) setModel.move(from, Math.min(target, setModel.count - 1), 1)
    }
    run(["deck", "move", dragUid, String(Math.max(0, target))])
  }
  function playDropped(roomId) {
    if (roomId && roomId !== whereId) run(["deck", "where", roomId])
    if (dragFrom === "found") run(["deck", "add", service, JSON.stringify(dragItem), "--play"])
    else run(["deck", "play", dragUid])
  }


  // ------------------------------------------------------------ the set in time
  // When each song starts (from now), the chapters, what's folded, picked or
  // filtered. A song whose length isn't known yet counts as 3:30.
  function lengthOf(song) { return song && song.length ? song.length : 210 }
  readonly property real nowLeft: now ? Math.max(0, (pos.length || lengthOf(now)) - shownTime) : 0
  readonly property var startsAt: {
    const out = []
    let t = nowLeft
    for (const s of (deck.set || [])) { out.push(t); t += lengthOf(s) }
    out.push(t)
    return out
  }
  readonly property real setSeconds: startsAt.length ? startsAt[startsAt.length - 1] : 0
  function clockAt(secondsFromNow) {
    return new Date(Date.now() + secondsFromNow * 1000).toLocaleTimeString(Qt.locale(Commons.I18n.formatLocale), Locale.ShortFormat)
  }
  function span(seconds) {
    const m = Math.round(seconds / 60)
    return m >= 60 ? strings.t("deck.spanHours").arg(Math.floor(m / 60)).arg(m % 60) : strings.t("deck.spanMinutes").arg(m)
  }
  // Each row's place in its chapter: where the chapter starts, whether this
  // row opens it, how many songs and minutes it holds.
  readonly property var chapters: {
    const set = deck.set || []
    const out = []
    let prev = now ? (now.chapter || "") : null
    let head = -1
    for (let i = 0; i < set.length; i++) {
      const c = set[i].chapter || ""
      if (c !== prev && c !== "") head = i
      else if (c === "") head = -1
      out.push({ name: c, opens: c !== "" && c !== prev, head: head, count: 0, seconds: 0 })
      if (head >= 0) { out[head].count++; out[head].seconds += lengthOf(set[i]) }
      prev = c
    }
    return out
  }
  property var folded: ({})                  // the uid a chapter starts at → folded
  function foldChapter(uid) {
    const f = Object.assign({}, folded)
    if (f[uid]) delete f[uid]; else f[uid] = true
    folded = f
  }
  function hiddenAt(index) {
    const c = chapters[index]
    if (!c || c.head < 0 || c.opens) return false
    const head = (deck.set || [])[c.head]
    return !!head && !!folded[head.uid]
  }
  property string renaming: ""               // the chapter being named
  function newChapter(uid) {
    run(["deck", "chapter", uid, strings.t("deck.chapterNew")])
    renaming = uid
  }

  // Several songs at once: Ctrl-click picks one more, Shift-click a run.
  property var selected: ({})
  property string selectedLast: ""
  readonly property var selectedUids: (deck.set || []).filter(s => !!selected[s.uid]).map(s => s.uid)
  function pick(uid, mods) {
    const f = Object.assign({}, selected)
    if ((mods & Qt.ShiftModifier) && selectedLast !== "") {
      const ids = (deck.set || []).map(s => s.uid)
      const a = ids.indexOf(selectedLast), b = ids.indexOf(uid)
      if (a >= 0 && b >= 0) for (let i = Math.min(a, b); i <= Math.max(a, b); i++) f[ids[i]] = true
    } else if (f[uid]) delete f[uid]
    else f[uid] = true
    selected = f
    selectedLast = uid
  }
  function clearPicked() { selected = ({}); selectedLast = "" }
  function placePicked(where) {
    const uids = selectedUids
    if (!uids.length) return
    if (where === "remove") run(["deck", "remove"].concat(uids))
    else run(["deck", "place", where].concat(uids))
    clearPicked()
  }

  // Finding a song in the set ("/").
  property string filter: ""
  function matches(title, artist) {
    if (filter === "") return true
    const f = filter.toLowerCase()
    return title.toLowerCase().indexOf(f) >= 0 || artist.toLowerCase().indexOf(f) >= 0
  }

  // Getting around: the top (what's playing), the end, smoothly.
  function scrollTo(y) {
    const list = root.wall ? wallView : setList
    const top = list.originY, bottom = list.originY + Math.max(0, list.contentHeight - list.height)
    scroller.target = list
    scroller.to = Math.max(top, Math.min(bottom, y))
    scroller.restart()
  }
  function toTop() { scrollTo(-1e9) }
  function toEnd() { scrollTo(1e9) }
  NumberAnimation { id: scroller; property: "contentY"; duration: Style.duration(320); easing.type: Easing.OutCubic }

  // Dragging near the list's top or bottom edge scrolls it.
  property real edgeSpeed: 0
  Timer {
    interval: 16
    repeat: true
    running: root.dragging && root.edgeSpeed !== 0
    onTriggered: {
      const top = setList.originY, bottom = setList.originY + Math.max(0, setList.contentHeight - setList.height)
      setList.contentY = Math.max(top, Math.min(bottom, setList.contentY + root.edgeSpeed))
      const p = setList.mapFromItem(stage, ghost.x - 14, ghost.y + ghost.height / 2)
      const i = setList.indexAt(20, p.y + setList.contentY)
      if (i >= 0) root.dropIndex = i
    }
  }

  // A cover wall instead of the list.
  property bool wall: false
  property bool filterOpen: false
  property bool shapeOpen: false
  property bool autodjOpen: false
  readonly property var shapes: [
    { key: "bumps", glyph: "◆", label: strings.t("deck.shapeBumps") },
    { key: "shuffle", glyph: "󰒝", label: strings.t("deck.shuffle") },
    { key: "arc", glyph: "󱗿", label: strings.t("deck.shapeArc") },
    { key: "harmonic", glyph: "󰽰", label: strings.t("deck.shapeHarmonic") },
    { key: "smooth", glyph: "󰾆", label: strings.t("deck.shapeSmooth") },
    { key: "tempo", glyph: "󰓅", label: strings.t("deck.shapeTempo") },
    { key: "energy", glyph: "󱐋", label: strings.t("deck.shapeEnergy") }
  ]
  property bool playedOpen: false
  // ---- party: the stage (the playing song, big, for the room), guests'
  // requests from their phones, and a lock so guests can't undo the night.
  property bool stageOn: false
  property bool guestsOpen: false
  property bool guestsAll: false
  property bool forgetArmed: false
  property bool clearArmed: false
  property string dropArmed: ""
  // The way Auto-DJ takes the night: the last shape picked (until Auto-DJ is turned off).
  readonly property string directionLabel: {
    const k = deck.direction || ""
    return k === "" ? "" : strings.t("deck.direction" + k.charAt(0).toUpperCase() + k.slice(1))
  }
  // Somewhere for Auto-DJ to head: a name for the chip, and what Grok is told.
  readonly property var towardPresets: [
    { label: strings.t("deck.towardWindDown"), brief: "a gentle wind-down to end the night: slower, warmer, softer" },
    { label: strings.t("deck.towardPeak"), brief: "peak time: the biggest, highest-energy floor-fillers" },
    { label: strings.t("deck.towardThrowbacks"), brief: "throwbacks: 80s and 90s dance and pop classics everyone knows" },
    { label: strings.t("deck.towardHouse"), brief: "deep house: warm, groovy, around 120 BPM" },
    { label: strings.t("deck.towardLatin"), brief: "Latin heat: reggaeton, salsa and Latin pop" },
    { label: strings.t("deck.towardChill"), brief: "chill-out: downtempo, mellow and easy" }
  ]
  function towardName(brief) {
    const preset = towardPresets.find(p => p.brief === brief)
    return preset ? preset.label.toLowerCase() : String(brief || "").split(":")[0]
  }
  // Auto-DJ at work (asking Grok, finding the songs): shown until it's done.
  readonly property var djBusy: deck.autodjBusy && Date.now() / 1000 - (deck.autodjBusy.at || 0) < 300 ? deck.autodjBusy : null
  readonly property string djBusyText: !djBusy ? ""
    : (djBusy.toward || "") !== "" ? strings.t("deck.autodjFindingToward").arg(towardName(djBusy.toward))
    : (djBusy.seed || "") !== "" ? strings.t("deck.autodjFindingSeed").arg(djBusy.seed)
    : strings.t("deck.autodjFindingNext")
  // Where Auto-DJ is heading (a sound you named), and how far it's got.
  readonly property string towardLabel: {
    const t = deck.toward
    if (!t || !t.brief) return ""
    const name = towardName(t.brief)
    return (t.done || 0) < (t.steps || 6) ? strings.t("deck.towardNow").arg(name).arg(t.done || 0).arg(t.steps || 6)
                                          : strings.t("deck.towardThere").arg(name)
  }
  // Something the room should know: the music stopped by itself, or the battery's low.
  readonly property var battery: deck.battery || null
  readonly property bool batteryLow: !!battery && !battery.charging && battery.level <= 20
  readonly property string alertText: deck.silent && !deck.playing ? strings.t("deck.silent").arg(deck.silent.why)
    : batteryLow ? strings.t("deck.batteryLow").arg(battery.level) : ""
  readonly property string alertGlyph: deck.silent && !deck.playing ? "󰝛" : "󰂃"
  // Does a song mix with the one before it? Keys: the same, one step round
  // the Camelot wheel, or its relative. Tempo: within 8%, counting half and
  // double time. (The same rules Auto-DJ and Shape use.)
  function keysFit(a, b) {
    if (!a || !b || a === b) return true
    const na = parseInt(a), nb = parseInt(b)
    const d = ((na - nb) % 12 + 12) % 12
    return (a.slice(-1) === b.slice(-1) && (d === 1 || d === 11)) || na === nb
  }
  function tempoStep(from, to) {
    // How the tempo moves from one song to the next: the plain difference in
    // BPM ("−11"), or "½×" / "2×" when it only mixes at half or double time;
    // fits is whether it mixes at all (within 8%). null when either isn't known.
    if (!from || !to) return null
    const near = (a, b) => Math.abs(a - b) / b <= 0.08
    const straight = near(to, from)
    const halfTime = !straight && (near(to, from * 2) || near(to, from / 2))
    const diff = Math.round(to - from)
    return { text: halfTime ? (to > from ? "2×" : "½×") : diff === 0 ? "" : (diff > 0 ? "+" : "−") + Math.abs(diff),
             fits: straight || halfTime }
  }
  // The set's columns, the same on every row and the Now row.
  readonly property int keyColumn: 40
  readonly property int bpmColumn: 48
  readonly property int timeColumn: 66
  readonly property int actionsColumn: 84
  function serviceGlyph(service) {
    return service === "applemusic" ? "" : service === "ytmusic" ? "󰗃" : service === "beatport" ? "󰎆" : "󰝚"
  }
  function keyTempo(song) {
    if (!song) return ""
    return [song.key || "", song.bpm > 0 ? Math.round(song.bpm) + " BPM" : ""].filter(x => x !== "").join(" · ")
  }
  // The set ran out: the song that played last (for the stage's goodbye).
  readonly property var lastPlayed: (deck.played || []).length ? deck.played[deck.played.length - 1] : null
  readonly property bool setDone: !now && (deck.set || []).length === 0 && !!lastPlayed
  // Two songs or fewer left and nobody topping it up.
  readonly property bool runningLow: !!now && !deck.autodj && (deck.set || []).length <= 2 && !djBusy
  // Seconds left in the playing song (for the stage's countdown).
  readonly property real songLeft: (pos.length || 0) > 0 ? Math.max(0, pos.length - shownTime) : -1
  property bool readyAsked: false
  property real readyAskedAt: 0
  readonly property bool readyFresh: !!deck.ready && deck.ready.at >= readyAskedAt - 1
  onGuestsOpenChanged: if (!guestsOpen) { guestsAll = false; forgetArmed = false; dropArmed = ""; readyAsked = false }
  // A recap just started (requests closed, or Recap pressed): show the stage.
  property real recapSeen: 0
  onDeckChanged: {
    const at = deck.recapAt || 0
    if (at > recapSeen) { if (recapSeen > 0 || Date.now() / 1000 - at < 30) stageOn = true; recapSeen = at }
  }
  function view(name) {
    stageOn = name === "stage"
    guestsOpen = name === "requests"
    autodjOpen = name === "autodj"
    shapeOpen = false
    qrBig = false
  }
  property bool qrBig: false
  readonly property bool showQr: !!guests && (guests.qr || "") !== ""
  readonly property bool locked: !!deck.lock
  readonly property var requests: deck.requests || []
  readonly property var guests: deck.guests || null
  readonly property var people: deck.people || []
  readonly property var nowVotes: {
    const v = (deck.votes || {})[now ? now.uid : ""] || {}
    let up = 0, down = 0
    for (const k in v) { if (v[k] === 1) up++; else if (v[k] === -1) down++ }
    return { up: up, down: down }
  }
  // Hold the lock for a second to open it again (a tap does nothing).
  property real unlockHeld: 0
  function hourOf(t) {
    return t ? new Date(t * 1000).toLocaleTimeString(Qt.locale(Commons.I18n.formatLocale), "h AP").replace(":00", "") : ""
  }

  // Saved sets, and your own playlists, for the crate before you search.
  property var savedSets: []
  property var myPlaylists: []
  function readShelf() {
    if (!setsReader.running) setsReader.running = true
    mineReader.command = [tool, "deck", "mine", service]
    if (!mineReader.running) mineReader.running = true
  }
  Process {
    id: setsReader
    command: [root.tool, "deck", "sets"]
    stdout: StdioCollector { onStreamFinished: { try { root.savedSets = JSON.parse(text) } catch (error) {} } }
  }
  Process {
    id: mineReader
    stdout: StdioCollector { onStreamFinished: { try { root.myPlaylists = JSON.parse(text) } catch (error) {} } }
  }
  onServiceChanged: if (seen) readShelf()
  onSeenChanged: if (seen) readShelf()
  property bool saving: false
  property string savePart: "next"          // what's to come, what's played, or the whole night
  property string saveTo: "baseline"        // or a service: a new playlist there, with the songs it has
  function saveAs(name) {
    if (name.trim() === "") return
    const part = savePart === "next" ? [] : ["--" + savePart]
    if (saveTo === "baseline") run(["deck", "save", name.trim()].concat(part))
    else runLong(["deck", "export", saveTo, name.trim()].concat(part))
    saving = false
    savePart = "next"
    saveTo = "baseline"
    shelfAgain.start()
  }
  Timer { id: shelfAgain; interval: 800; onTriggered: root.readShelf() }

  // Sleep: off, 15, 30, 60 minutes, the end of this song.
  readonly property var sleep: deck.sleep || null
  function nextSleep() {
    const order = ["off", "15", "30", "60", "song"]
    const at = sleep ? (sleep.song ? 4 : sleepMinutes <= 15 ? 1 : sleepMinutes <= 30 ? 2 : 3) : 0
    run(["deck", "sleep", order[(at + 1) % order.length]])
  }
  property int sleepMinutes: 0
  Timer {
    interval: 15000
    repeat: true
    triggeredOnStart: true
    running: root.seen && !!root.sleep && !!root.sleep.at
    onTriggered: root.sleepMinutes = Math.max(1, Math.ceil((root.sleep.at * 1000 - Date.now()) / 60000))
  }

  FloatingWindow {
    id: window
    title: "Baseline Deck"
    visible: false
    color: root.ground
    implicitWidth: 1240
    implicitHeight: 820
    minimumSize: Qt.size(980, 640)
    onVisibleChanged: if (!visible) { root.popped = false; root.closed() }

    Item {
      id: stage
      anchors.fill: parent
      focus: true
      Keys.onEscapePressed: {
        if (root.qrBig) root.qrBig = false
        else if (root.stageOn) root.stageOn = false
        else if (root.guestsOpen) root.guestsOpen = false
        else if (root.bloomOpen) root.closeBloom()
        else if (root.openList) root.closePlaylist()
        else if (root.selectedUids.length) root.clearPicked()
        else if (root.filterOpen || root.saving) { root.filterOpen = false; root.saving = false; root.filter = "" }
        else if (root.popped) root.goHome()
      }
      Keys.onSpacePressed: root.playPause()
      // Home and End, N for what's playing, / to find a song, Ctrl+Z to undo,
      // Delete for the picked songs, W for the wall.
      Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Home || (event.key === Qt.Key_N && !event.modifiers)) { root.toTop(); event.accepted = true }
        else if (event.key === Qt.Key_End) { root.toEnd(); event.accepted = true }
        else if (event.key === Qt.Key_Slash) { root.saving = false; root.filterOpen = true; event.accepted = true }
        else if (event.key === Qt.Key_P && !event.modifiers) { root.stageOn = !root.stageOn; event.accepted = true }
        else if (event.key === Qt.Key_Z && (event.modifiers & Qt.ControlModifier)) { if (!root.locked) root.run(["deck", "undo"]); event.accepted = true }
        else if (event.key === Qt.Key_Delete && root.selectedUids.length) { if (!root.locked) root.placePicked("remove"); event.accepted = true }
        else if (event.key === Qt.Key_W && !event.modifiers) { root.wall = !root.wall; event.accepted = true }
        else if (event.key === Qt.Key_A && (event.modifiers & Qt.ControlModifier)) {
          const f = {}; for (const x of (root.deck.set || [])) f[x.uid] = true
          root.selected = f; event.accepted = true
        }
      }

      // ---- the cover's glow: the song's own colours, softly, behind it all
      Item {
        id: glow
        anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
        height: parent.height * 0.62
        clip: true          // the blur spreads past its edges; keep it inside, under the fade
        readonly property string url: root.now && /^https:\/\//.test(root.now.thumb || "") ? root.now.thumb : ""
        property bool showA: false
        onUrlChanged: { if (showA) glowB.source = url; else glowA.source = url; showA = !showA }
        Component.onCompleted: { glowA.source = url; showA = true }
        Image { id: glowA; anchors.fill: parent; fillMode: Image.PreserveAspectCrop; sourceSize: Qt.size(48, 48); visible: false; asynchronous: true }
        Image { id: glowB; anchors.fill: parent; fillMode: Image.PreserveAspectCrop; sourceSize: Qt.size(48, 48); visible: false; asynchronous: true }
        MultiEffect {
          source: glowA; anchors.fill: parent
          blurEnabled: true; blur: 1.0; blurMax: 64; saturation: 0.25
          opacity: glow.showA && glow.url !== "" ? 0.2 : 0
          Behavior on opacity { NumberAnimation { duration: Style.duration(900); easing.type: Easing.OutCubic } }
        }
        MultiEffect {
          source: glowB; anchors.fill: parent
          blurEnabled: true; blur: 1.0; blurMax: 64; saturation: 0.25
          opacity: !glow.showA && glow.url !== "" ? 0.2 : 0
          Behavior on opacity { NumberAnimation { duration: Style.duration(900); easing.type: Easing.OutCubic } }
        }
        Rectangle {
          anchors.fill: parent
          gradient: Gradient {
            GradientStop { position: 0; color: Util.alpha(root.ground, 0.15) }
            GradientStop { position: 0.55; color: Util.alpha(root.ground, 0.55) }
            GradientStop { position: 1; color: root.ground }
          }
        }
      }

      // The accent line along the top: clear of the window's rounded corners, fading at the ends.
      Rectangle {
        anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
        anchors.leftMargin: 10; anchors.rightMargin: 10; anchors.topMargin: 1
        height: 2
        gradient: Gradient {
          orientation: Gradient.Horizontal
          GradientStop { position: 0; color: "transparent" }
          GradientStop { position: 0.08; color: root.amber }
          GradientStop { position: 0.92; color: root.teal }
          GradientStop { position: 1; color: "transparent" }
        }
      }

      ColumnLayout {
        anchors.fill: parent
        anchors.margins: 22
        spacing: 14

        // ---- header
        RowLayout {
          Layout.fillWidth: true
          spacing: 18
          ColumnLayout {
            spacing: 2
            Label { text: strings.t("studio.brand"); font.pixelSize: Style.font.caption; font.letterSpacing: 4; color: root.amber }
            Label { text: strings.t("deck.title").toUpperCase(); font.pixelSize: 22; font.bold: true; font.letterSpacing: 3; color: root.teal }
          }
          Item { Layout.fillWidth: true }
          // Party: the stage, guests' requests, the lock.
          ActionButton {
            icon: "󰐯"
            text: strings.t("deck.stage")
            tone: root.teal
            enabled: !!root.now
            onClicked: root.stageOn = true
          }
          ActionButton {
            icon: "󰄜"
            text: root.requests.length ? strings.tn("deck.requestsCount", root.requests.length).arg(root.requests.length) : strings.t("deck.guests")
            tone: root.guests || root.requests.length ? root.amber : root.teal
            onClicked: root.guestsOpen = !root.guestsOpen
          }
          ActionButton {
            id: lockButton
            icon: root.locked ? "󰌾" : "󰍁"
            text: root.locked ? (root.unlockHeld > 0 ? strings.t("deck.unlockHold") : strings.t("deck.locked")) : strings.t("deck.lock")
            tone: root.locked ? root.amber : root.teal
            onClicked: if (!root.locked) root.run(["deck", "lock", "on"])
            // Locked: hold it to open (so a tap from a guest does nothing).
            TapHandler {
              enabled: root.locked
              gesturePolicy: TapHandler.DragThreshold
              onPressedChanged: { root.unlockHeld = pressed ? 1 : 0; if (pressed) unlockTimer.restart(); else unlockTimer.stop() }
            }
            Timer { id: unlockTimer; interval: 1000; onTriggered: { root.unlockHeld = 0; root.run(["deck", "lock", "off"]) } }
          }
          ActionButton {
            visible: root.popped
            icon: "⤓"
            text: strings.t("deck.sendHome")
            tone: root.teal
            onClicked: root.goHome()
          }
          Label {
            visible: root.busy || root.status !== ""
            text: root.status !== "" ? root.status : "󰔟"
            color: root.status !== "" ? Commons.Color.urgent : root.teal
            font.family: "Iosevka Nerd Font Propo"
            font.pixelSize: Style.font.caption
            Layout.maximumWidth: 420
          }
          // Requests open and the crate folded away: the code, small (tap for it big).
          QrTile { visible: root.showQr && !root.crateOpen; size: 46 }
        }

        Rectangle {
          Layout.fillWidth: true
          height: 1
          gradient: Gradient {
            orientation: Gradient.Horizontal
            GradientStop { position: 0; color: Util.alpha(root.amber, 0.6) }
            GradientStop { position: 1; color: Util.alpha(root.teal, 0.08) }
          }
        }

        RowLayout {
          Layout.fillWidth: true
          Layout.fillHeight: true
          spacing: 22

          // ============================================== the crate
          Item {
            id: crateBox
            Layout.preferredWidth: root.crateOpen ? 380 : 44
            Layout.maximumWidth: root.crateOpen ? 380 : 44
            Layout.fillHeight: true
            clip: true
            Behavior on Layout.preferredWidth { NumberAnimation { duration: Style.duration(220); easing.type: Easing.OutCubic } }

            // Folded: a rail with search and Build, and the way back out.
            ColumnLayout {
              anchors.top: parent.top
              anchors.horizontalCenter: parent.horizontalCenter
              anchors.horizontalCenterOffset: root.crateOpen ? -400 : 0
              spacing: 8
              opacity: root.crateOpen ? 0 : 1
              visible: opacity > 0
              Behavior on opacity { NumberAnimation { duration: Style.duration(160) } }
              RoundButton { glyph: "󰅂"; tip: strings.t("deck.crateOpen"); onClicked: root.setCrate(true) }
              RoundButton { glyph: "󰍉"; tip: strings.t("deck.search"); onClicked: { root.setCrate(true); query.forceActiveFocus() } }
              RoundButton { glyph: "✦"; tip: strings.t("deck.build"); onClicked: { root.setCrate(true); root.buildOpen = true; brief.forceActiveFocus() } }
            }

          ColumnLayout {
            id: crate
            width: 380
            height: parent.height
            opacity: root.crateOpen ? 1 : 0
            visible: opacity > 0
            Behavior on opacity { NumberAnimation { duration: Style.duration(160) } }
            spacing: 10

            RowLayout {
              Layout.fillWidth: true
              Label { text: strings.t("deck.crate").toUpperCase(); font.pixelSize: Style.font.caption; font.letterSpacing: 2; opacity: 0.5 }
              Item { Layout.fillWidth: true }
              RoundButton { glyph: "󰅁"; tip: strings.t("deck.crateClose"); onClicked: root.setCrate(false) }
            }

            // ---- guests' requests: from their phones, waiting for you to take them
            Rectangle {
              Layout.fillWidth: true
              visible: root.requests.length > 0 || root.showQr
              implicitHeight: asks.implicitHeight + 16
              radius: Style.cornerRadius > 0 ? 6 : 0
              color: Util.alpha(root.teal, 0.06)
              border.width: 1
              border.color: Util.alpha(root.teal, 0.4)
              ColumnLayout {
                id: asks
                x: 10; y: 8
                width: parent.width - 20
                spacing: 4
                // Requests open: the code to scan, big enough for a phone to focus on.
                RowLayout {
                  Layout.fillWidth: true
                  visible: root.showQr
                  spacing: 14
                  QrTile { size: 118 }
                  ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 4
                    Label { text: strings.t("deck.stageScan"); font.bold: true; color: root.teal; Layout.fillWidth: true; wrapMode: Text.Wrap }
                    Label { text: strings.t("deck.qrTapHint"); font.pixelSize: Style.font.caption; opacity: 0.55; Layout.fillWidth: true; wrapMode: Text.Wrap }
                  }
                }
                RowLayout {
                  Layout.fillWidth: true
                  visible: root.requests.length > 0
                  Label {
                    Layout.fillWidth: true
                    text: "󰄜  " + strings.tn("deck.requestsCount", root.requests.length).arg(root.requests.length).toUpperCase()
                    font.family: "Iosevka Nerd Font Propo"; font.pixelSize: Style.font.caption; font.letterSpacing: 2; color: root.teal
                  }
                  // Turn them all down: tap twice (and not while locked).
                  HeadLink {
                    visible: !root.locked
                    glyph: root.clearArmed ? "󰀦" : "󰆴"
                    text: root.clearArmed ? strings.t("deck.requestsClearSure") : ""
                    tip: strings.t("deck.requestsClear")
                    onTapped: {
                      if (root.clearArmed) { root.clearArmed = false; root.run(["deck", "requests", "clear"]) }
                      else { root.clearArmed = true; clearDisarm.restart() }
                    }
                  }
                  Timer { id: clearDisarm; interval: 4000; onTriggered: root.clearArmed = false }
                }
                // Newest first; after four it scrolls, so the crate keeps its room.
                ListView {
                  id: askList
                  Layout.fillWidth: true
                  Layout.preferredHeight: Math.min(count, 4) * 64 + Math.max(0, Math.min(count, 4) - 1) * 4
                  clip: true
                  spacing: 4
                  boundsBehavior: Flickable.StopAtBounds
                  model: root.requests.slice().reverse()
                  delegate: RequestRow {
                    required property var modelData
                    width: askList.width
                    height: 64
                    coverSize: 52
                    req: modelData
                  }
                  add: Transition { NumberAnimation { properties: "opacity"; from: 0; to: 1; duration: Style.duration(200) } }
                }
                Label {
                  visible: root.requests.length > 4
                  text: strings.t("deck.requestsScroll")
                  font.pixelSize: Style.font.caption; opacity: 0.45
                }
              }
            }


            // ---- Build a set: a brief, a length, maybe a first song.
            Rectangle {
              Layout.fillWidth: true
              implicitHeight: build.implicitHeight + 20
              radius: Style.cornerRadius > 0 ? 6 : 0
              color: Util.alpha(root.amber, 0.06)
              border.width: 1
              border.color: Util.alpha(root.amber, 0.35)
              ColumnLayout {
                id: build
                anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
                anchors.margins: 10
                spacing: 8
                property int minutes: 60
                RowLayout {
                  Layout.fillWidth: true
                  Label { text: "✦  " + strings.t("deck.build").toUpperCase(); font.pixelSize: Style.font.caption; font.letterSpacing: 2; color: root.amber }
                  Label {
                    Layout.fillWidth: true
                    visible: !root.buildShown
                    text: strings.t("deck.buildTeaser")
                    elide: Text.ElideRight
                    font.pixelSize: Style.font.caption
                    opacity: 0.5
                  }
                  Item { Layout.fillWidth: root.buildShown }
                  Label { text: root.buildShown ? "󰅃" : "󰅀"; font.family: "Iosevka Nerd Font Propo"; color: root.amber; opacity: 0.8 }
                  HoverHandler { cursorShape: Qt.PointingHandCursor }
                  TapHandler {
                    onTapped: {
                      if (root.buildShown) { root.buildOpen = false; root.seed = null }
                      else { root.buildOpen = true; brief.forceActiveFocus() }
                    }
                  }
                }
                Rectangle {
                  visible: root.buildShown
                  Layout.fillWidth: true
                  implicitHeight: Math.max(54, brief.implicitHeight + 12)
                  radius: Style.cornerRadius > 0 ? 4 : 0
                  color: Util.alpha(root.ink, 0.04)
                  border.width: 1
                  border.color: brief.activeFocus ? root.amber : Util.alpha(root.ink, 0.14)
                  TextEdit {
                    id: brief
                    anchors.fill: parent
                    anchors.margins: 6
                    wrapMode: TextEdit.Wrap
                    color: root.ink
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    textFormat: TextEdit.PlainText
                    Label {
                      visible: brief.text === ""
                      width: parent.width
                      wrapMode: Text.Wrap
                      text: strings.t("deck.briefHint")
                      font.pixelSize: Style.font.caption
                      opacity: 0.4
                    }
                  }
                }
                RowLayout {
                  visible: root.buildShown
                  Layout.fillWidth: true
                  spacing: 6
                  Repeater {
                    model: [30, 60, 120, 180]
                    delegate: Rectangle {
                      required property var modelData
                      readonly property bool on: build.minutes === modelData
                      implicitWidth: lenLabel.implicitWidth + 14
                      implicitHeight: lenLabel.implicitHeight + 8
                      radius: Style.cornerRadius > 0 ? 3 : 0
                      color: on ? Util.alpha(root.amber, 0.2) : "transparent"
                      border.width: 1
                      border.color: on ? root.amber : Util.alpha(root.ink, 0.15)
                      Label {
                        id: lenLabel
                        anchors.centerIn: parent
                        text: modelData < 60 ? strings.t("deck.minutes").arg(modelData) : strings.t("deck.hours").arg(modelData / 60)
                        font.pixelSize: Style.font.caption
                      }
                      HoverHandler { cursorShape: Qt.PointingHandCursor }
                      TapHandler { onTapped: build.minutes = modelData }
                    }
                  }
                  Item { Layout.fillWidth: true }
                  ActionButton {
                    icon: "✦"
                    text: strings.t("deck.buildGo")
                    enabled: brief.text.trim() !== "" || !!root.seed
                    onClicked: {
                      const args = ["deck", "build", String(build.minutes)]
                      if (brief.text.trim() !== "") args.push(brief.text.trim())
                      if (root.seed) args.push("--seed", JSON.stringify(root.seed))
                      else if (root.now) args.push("--start", root.now.title + " by " + root.now.artist)
                      if ((root.deck.set || []).length === 0) args.push("--replace")
                      args.push("--service", root.seed ? root.seedService : root.service)
                      root.runLong(args)
                      root.seed = null
                      root.buildOpen = false
                    }
                  }
                }
                // The song it grows from, picked with ✦ on a song below.
                Rectangle {
                  visible: !!root.seed
                  Layout.fillWidth: true
                  implicitHeight: 46
                  radius: Style.cornerRadius > 0 ? 4 : 0
                  color: Util.alpha(root.amber, 0.1)
                  border.width: 1
                  border.color: Util.alpha(root.amber, 0.4)
                  RowLayout {
                    anchors.fill: parent
                    anchors.margins: 5
                    spacing: 8
                    Cover { url: root.seed ? root.seed.thumb || "" : ""; size: 34 }
                    ColumnLayout {
                      Layout.fillWidth: true
                      spacing: 0
                      Label { Layout.fillWidth: true; text: strings.t("deck.seedFrom"); font.pixelSize: Style.font.caption; color: root.amber; opacity: 0.85 }
                      Label {
                        Layout.fillWidth: true
                        text: root.seed ? root.seed.title + " · " + String(root.seed.subtitle || "").split(" • ")[0] : ""
                        font.bold: true; font.pixelSize: Style.font.caption
                      }
                    }
                    RoundButton {
                      glyph: "∞"
                      tip: strings.t("deck.seedAutodj")
                      onClicked: {
                        root.runLong(["deck", "autodj", "from", root.seedService, JSON.stringify(root.seed)])
                        root.seed = null
                      }
                    }
                    RoundButton { glyph: "󰅖"; tip: strings.t("deck.seedClear"); onClicked: root.seed = null }
                  }
                }
                Label {
                  visible: root.buildShown
                  Layout.fillWidth: true
                  wrapMode: Text.Wrap
                  text: root.seed ? strings.t("deck.seedNote")
                    : root.now ? strings.t("deck.buildFrom").arg(root.now.title) : strings.t("deck.buildNote")
                  font.pixelSize: Style.font.caption
                  opacity: 0.55
                }
              }
            }

            // ---- search
            RowLayout {
              Layout.fillWidth: true
              spacing: 6
              Repeater {
                model: [{ id: "ytmusic", name: "YouTube Music", icon: "󰗃" }, { id: "applemusic", name: "Apple Music", icon: "󰀵" },
                        { id: "beatport", name: "Beatport", icon: "󰋋" }]
                delegate: Rectangle {
                  required property var modelData
                  readonly property bool on: root.service === modelData.id
                  implicitWidth: svcLabel.implicitWidth + 16
                  implicitHeight: svcLabel.implicitHeight + 8
                  radius: Style.cornerRadius > 0 ? 3 : 0
                  color: on ? Util.alpha(root.amber, 0.16) : "transparent"
                  border.width: 1
                  border.color: on ? root.amber : Util.alpha(root.ink, 0.15)
                  Label {
                    id: svcLabel
                    anchors.centerIn: parent
                    text: modelData.icon + "  " + modelData.name
                    font.family: "Iosevka Nerd Font Propo"
                    font.pixelSize: Style.font.caption
                  }
                  HoverHandler { cursorShape: Qt.PointingHandCursor }
                  TapHandler {
                    onTapped: {
                      root.pickedService = modelData.id
                      root.results = []
                      root.closePlaylist()
                      if (query.text.trim() !== "") root.find(query.text)
                    }
                  }
                }
              }
            }
            Rectangle {
              Layout.fillWidth: true
              implicitHeight: query.implicitHeight + 14
              radius: Style.cornerRadius > 0 ? 4 : 0
              color: Util.alpha(root.ink, 0.04)
              border.width: 1
              border.color: query.activeFocus ? root.amber : Util.alpha(root.ink, 0.14)
              TextInput {
                id: query
                anchors.left: parent.left; anchors.right: searchIcon.left
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: 10; anchors.rightMargin: 6
                color: root.ink
                font.family: Style.font.family
                font.pixelSize: Style.font.body
                clip: true
                onAccepted: root.find(text)
                Label {
                  visible: query.text === ""
                  text: strings.t("deck.search")
                  opacity: 0.4
                }
              }
              Label {
                id: searchIcon
                anchors.right: parent.right; anchors.rightMargin: 10
                anchors.verticalCenter: parent.verticalCenter
                text: root.searching ? "󰔟" : "󰍉"
                font.family: "Iosevka Nerd Font Propo"
                color: root.amber
                TapHandler { onTapped: root.find(query.text) }
              }
            }
            // An album or playlist you opened: back, what it is, and all of it at once.
            Rectangle {
              visible: !!root.openList
              Layout.fillWidth: true
              implicitHeight: 58
              radius: Style.cornerRadius > 0 ? 4 : 0
              color: Util.alpha(root.amber, 0.08)
              border.width: 1
              border.color: Util.alpha(root.amber, 0.35)
              RowLayout {
                anchors.fill: parent
                anchors.margins: 6
                spacing: 8
                RoundButton { glyph: "󰁍"; tip: strings.t("deck.listBack"); onClicked: root.closePlaylist() }
                Cover { url: root.openList ? root.openList.thumb || "" : ""; size: 42; glyph: "󰲸" }
                ColumnLayout {
                  Layout.fillWidth: true
                  spacing: 0
                  Label { Layout.fillWidth: true; text: root.openList ? root.openList.title : ""; font.bold: true; font.pixelSize: Style.font.caption }
                  Label {
                    Layout.fillWidth: true
                    text: root.listLoading ? strings.t("deck.listLoading") : strings.tn("deck.listCount", root.listSongs.length).arg(root.listSongs.length)
                    font.pixelSize: Style.font.caption; opacity: 0.6
                  }
                }
                RoundButton { glyph: "󰐊"; tip: strings.t("deck.playNow"); onClicked: root.run(["deck", "add", root.service, JSON.stringify(root.openList), "--play"]) }
                RoundButton { glyph: "󰒝"; tip: strings.t("deck.bloomMix"); onClicked: root.run(["deck", "add", root.service, JSON.stringify(root.openList), "--scatter"]) }
                RoundButton { glyph: "󰐒"; tip: strings.t("deck.add"); onClicked: root.run(["deck", "add", root.service, JSON.stringify(root.openList)]) }
              }
            }
            ListView {
              id: found
              Layout.fillWidth: true
              Layout.fillHeight: true
              clip: true
              spacing: 2
              readonly property bool shelf: !root.openList && root.results.length === 0 && query.text.trim() === ""
              model: root.openList ? root.listSongs : shelf ? root.myPlaylists : root.results
              // Before a search: your saved sets, then your own playlists.
              header: Column {
                width: found.width
                spacing: 2
                visible: found.shelf
                height: found.shelf ? implicitHeight : 0
                Label {
                  visible: root.savedSets.length > 0
                  text: strings.t("deck.yourSets").toUpperCase()
                  font.pixelSize: Style.font.caption; font.letterSpacing: 2; color: root.amber
                  bottomPadding: 4
                }
                Repeater {
                  model: root.savedSets
                  delegate: Rectangle {
                    id: saved
                    required property var modelData
                    width: found.width
                    height: 66
                    radius: Style.cornerRadius > 0 ? 4 : 0
                    color: savedHover.hovered ? Util.alpha(root.ink, 0.05) : "transparent"
                    RowLayout {
                      anchors.fill: parent
                      anchors.margins: 5
                      spacing: 10
                      // A little mosaic of its first covers.
                      Grid {
                        columns: 2
                        spacing: 0
                        Repeater {
                          model: 4
                          delegate: Cover { required property int index; size: 21; url: saved.modelData.thumbs[index] || ""; radius: 0 }
                        }
                      }
                      ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 0
                        Label { Layout.fillWidth: true; text: saved.modelData.name; font.bold: true; font.pixelSize: Style.font.caption }
                        Label {
                          Layout.fillWidth: true
                          text: strings.tn("deck.count", saved.modelData.count).arg(saved.modelData.count)
                                + (saved.modelData.minutes > 0 ? "  ·  " + root.span(saved.modelData.minutes * 60) : "")
                                + "  ·  " + new Date(saved.modelData.saved * 1000).toLocaleDateString(Qt.locale(Commons.I18n.formatLocale), Locale.ShortFormat)
                          font.pixelSize: Style.font.caption
                          opacity: 0.6
                        }
                        // Where it came from: its services, and the playlists, albums or brief behind it.
                        Label {
                          Layout.fillWidth: true
                          text: (saved.modelData.services || []).join(" · ")
                                + ((saved.modelData.from || []).length ? "  ·  " + strings.t("deck.from").arg((saved.modelData.from || []).join(", ")) : "")
                          font.pixelSize: Style.font.caption
                          color: root.teal
                          opacity: 0.8
                        }
                      }
                      RoundButton {
                        id: exportGo
                        visible: savedHover.hovered
                        glyph: "󰈝"
                        tip: strings.t("deck.exportTo")
                        onClicked: root.openBloom("export", { title: saved.modelData.name, thumb: (saved.modelData.thumbs || [])[0] || "" }, "",
                                                  exportGo.mapToItem(root.stageItem, exportGo.width / 2, exportGo.height / 2))
                      }
                      RoundButton { visible: savedHover.hovered; glyph: "󰆴"; onClicked: { root.run(["deck", "forget", saved.modelData.name]); forgetDone.start() } }
                      RoundButton { glyph: "󰐊"; onClicked: { root.run(["deck", "load", saved.modelData.name, "--replace"]); root.run(["deck", "next"]) } }
                      RoundButton { glyph: "󰐒"; onClicked: root.run(["deck", "load", saved.modelData.name]) }
                    }
                    HoverHandler { id: savedHover }
                  }
                }
                Timer { id: forgetDone; interval: 600; onTriggered: root.readShelf() }
                Label {
                  visible: root.myPlaylists.length > 0
                  topPadding: root.savedSets.length > 0 ? 10 : 0
                  bottomPadding: 4
                  text: strings.t("deck.yourPlaylists").toUpperCase()
                  font.pixelSize: Style.font.caption; font.letterSpacing: 2; color: root.amber
                }
              }
              boundsBehavior: Flickable.StopAtBounds
              delegate: Rectangle {
                id: hit
                required property var modelData
                width: found.width
                implicitHeight: 52
                radius: Style.cornerRadius > 0 ? 4 : 0
                color: hitHover.hovered ? Util.alpha(root.ink, 0.05) : "transparent"
                RowLayout {
                  anchors.fill: parent
                  anchors.margins: 5
                  spacing: 10
                  Cover {
                    url: hit.modelData.thumb || ""; size: 42
                    glyph: hit.modelData.kind === "album" ? "󰀥" : hit.modelData.kind === "playlist" ? "󰲸" : "󰎈"
                  }
                  ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 0
                    Label { Layout.fillWidth: true; text: hit.modelData.title; font.bold: true; font.pixelSize: Style.font.caption }
                    Label {
                      Layout.fillWidth: true
                      text: hit.modelData.mine ? "󰲸  " + strings.t("deck.yourPlaylist")
                        : (hit.modelData.kind === "album" ? strings.t("ytmusic.kind.album") + " · "
                           : hit.modelData.kind === "playlist" ? strings.t("deck.playlist") + " · " : "") + (hit.modelData.subtitle || "")
                      font.family: "Iosevka Nerd Font Propo"
                      color: hit.modelData.mine ? root.amber : root.ink
                      font.pixelSize: Style.font.caption
                      opacity: 0.6
                    }
                  }
                  RoundButton {
                    visible: hit.modelData.kind === "album" || hit.modelData.kind === "playlist"
                    glyph: "󰁔"
                    tip: strings.t("deck.listOpen")
                    onClicked: root.openPlaylist(hit.modelData)
                  }
                  RoundButton {
                    visible: (hit.modelData.kind || "song") === "song"
                    glyph: "✦"
                    tip: strings.t("deck.seedPick")
                    on: !!root.seed && root.seed.id === hit.modelData.id && root.seed.video === hit.modelData.video
                    onClicked: { root.seed = hit.modelData; root.seedService = root.service }
                  }
                  RoundButton { glyph: "󰐊"; tip: strings.t("deck.playNow"); onClicked: root.run(["deck", "add", root.service, JSON.stringify(hit.modelData), "--play"]) }
                  RoundButton {
                    glyph: hit.modelData.kind === "playlist" || hit.modelData.kind === "album" ? "󰐒" : "󰐕"
                    tip: strings.t("deck.add")
                    onClicked: root.run(["deck", "add", root.service, JSON.stringify(hit.modelData)])
                  }
                }
                HoverHandler { id: hitHover; cursorShape: root.dragging ? Qt.ClosedHandCursor : Qt.PointingHandCursor }
                // Tap: the Bloom (or, with nothing playing, just play it).
                // Hold: the Bloom, then flick toward a petal and let go.
                TapHandler {
                  id: hitTap
                  longPressThreshold: 0.35
                  onTapped: function(point) {
                    if (point.position.x > hit.width - 110) return         // the ✦ (or 󰁔), ▶ and + buttons
                    if (hit.modelData.kind === "album" || hit.modelData.kind === "playlist") { root.openPlaylist(hit.modelData); return }
                    root.tapFound(hit.modelData, hit.mapToItem(root.stageItem, point.position.x, point.position.y))
                  }
                  onLongPressed: root.openBloom("found", hit.modelData, "", hit.mapToItem(root.stageItem, hitTap.point.position.x, hitTap.point.position.y))
                }
                DragHandler {
                  target: null
                  grabPermissions: PointerHandler.CanTakeOverFromAnything
                  onActiveChanged: {
                    if (active) { if (root.bloomOpen) root.bloomFlick = true; else root.beginDrag("found", "", hit.modelData, hit.modelData.title, hit.modelData.thumb || "") }
                    else if (root.bloomFlick) root.releaseFlick()
                    else if (root.dragging) root.endDrag()
                  }
                  onCentroidChanged: if (active) {
                    const at = hit.mapToItem(root.stageItem, centroid.position.x, centroid.position.y)
                    if (root.bloomFlick) root.aimBloom(at); else root.moveGhost(at)
                  }
                }
              }
              Label {
                anchors.centerIn: parent
                width: parent.width - 20
                visible: root.results.length === 0 && !(found.shelf && (root.savedSets.length || root.myPlaylists.length))
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.Wrap
                text: strings.t("deck.findHint")
                opacity: 0.45
                font.pixelSize: Style.font.caption
              }
            }
          }
          }

          // ============================================== the deck
          ColumnLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 12

            // ---- now playing
            RowLayout {
              Layout.fillWidth: true
              spacing: 20
              Item {
                id: nowCover
                Layout.preferredWidth: 176
                Layout.preferredHeight: 176
                Rectangle {
                  anchors.fill: parent
                  anchors.margins: -3
                  radius: 15
                  color: "transparent"
                  border.width: 2
                  border.color: nowDrop.containsDrag ? root.teal : Util.alpha(root.amber, root.deck.playing ? 0.9 : 0.35)
                }
                CrossCover { anchors.fill: parent; url: root.now ? root.now.thumb || "" : ""; size: 176; glyph: "󰎆"; radius: 12 }
                DropArea {
                  id: nowDrop
                  anchors.fill: parent
                  keys: ["deck-song"]
                  onDropped: root.playDropped("")
                }
              }
              ColumnLayout {
                Layout.fillWidth: true
                spacing: 4
                // The title on the left, the Skyline on the right.
                RowLayout {
                  Layout.fillWidth: true
                  spacing: 16
                  ColumnLayout {
                    Layout.fillWidth: true
                    Layout.alignment: Qt.AlignTop
                    spacing: 4
                    Label {
                      Layout.fillWidth: true
                      // The name without its brackets ("[From …]", "(Radio Edit)"): those go
                      // on their own line below. Long names shrink before they're ever cut.
                      text: root.now ? root.titleParts(root.now.title).main : strings.t("deck.empty")
                      font.pixelSize: 26
                      fontSizeMode: Text.Fit
                      minimumPixelSize: 17
                      Layout.maximumHeight: 68
                      font.bold: true
                      color: root.amber
                      wrapMode: Text.Wrap
                      maximumLineCount: 2
                    }
                    Label {
                      Layout.fillWidth: true
                      visible: text !== ""
                      text: root.now ? root.titleParts(root.now.title).extra : ""
                      font.pixelSize: Style.font.caption
                      color: root.amber
                      opacity: 0.65
                      elide: Text.ElideRight
                    }
                    Label {
                      Layout.fillWidth: true
                      text: root.now ? root.now.artist : strings.t("deck.emptyHint")
                      opacity: 0.85
                      wrapMode: Text.Wrap
                      maximumLineCount: 2
                    }
                    Label {
                      Layout.fillWidth: true
                      text: root.now ? (root.whereId === "laptop" ? "󰌢  " + strings.t(root.deck.playing ? "hover.playingOn" : "deck.pausedOn").arg(root.whereName)
                                                                : "󰓃  " + strings.t(root.deck.playing ? "hover.playingIn" : "deck.pausedIn").arg(root.whereName))
                                        + " · " + root.serviceName(root.now.service)
                                        + (root.keyTempo(root.now) !== "" ? "  ·  " + root.keyTempo(root.now) : "") : ""
                      font.family: "Iosevka Nerd Font Propo"
                      font.pixelSize: Style.font.caption
                      color: root.teal
                    }
                    Label {
                      Layout.fillWidth: true
                      visible: root.alertText !== ""
                      text: root.alertGlyph + "  " + root.alertText
                      font.family: "Iosevka Nerd Font Propo"
                      font.pixelSize: Style.font.caption
                      color: Commons.Color.warning
                      wrapMode: Text.Wrap
                    }
                  }
                  DeckVisualizer {
                    Layout.preferredWidth: Math.min(360, Math.max(200, root.stageItem.width * 0.24))
                    Layout.preferredHeight: 112
                    Layout.alignment: Qt.AlignTop
                    Layout.rightMargin: 8
                    visible: !!root.now
                    active: root.seen && !!root.now && !root.stageOn
                    playing: root.deck.playing
                    live: !root.inSonos
                    mic: root.deck.micViz === true
                    amber: root.amber
                    teal: root.teal
                    ground: root.ground
                    // In a room: let the bars hear it through the microphone (or not).
                    HeadLink {
                      visible: root.inSonos
                      anchors.right: parent.right; anchors.top: parent.top
                      glyph: root.deck.micViz ? "󰍬" : "󰍭"
                      text: root.deck.micViz ? strings.t("deck.micOn") : strings.t("deck.micOff")
                      tip: strings.t("deck.micTip")
                      on: root.deck.micViz === true
                      onTapped: root.run(["deck", "mic", root.deck.micViz ? "off" : "on"])
                    }
                  }
                }
                // progress
                Item {
                  Layout.fillWidth: true
                  Layout.topMargin: 6
                  implicitHeight: 18
                  visible: !!root.now
                  Rectangle {
                    id: track
                    anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
                    height: 3
                    radius: 2
                    color: Util.alpha(root.ink, 0.1)
                    Rectangle {
                      height: parent.height
                      radius: 2
                      width: root.pos.length > 0 ? parent.width * Math.min(1, root.shownTime / root.pos.length) : 0
                      gradient: Gradient {
                        orientation: Gradient.Horizontal
                        GradientStop { position: 0; color: root.amber }
                        GradientStop { position: 1; color: root.teal }
                      }
                    }
                  }
                  Label {
                    anchors.left: parent.left; anchors.bottom: parent.bottom
                    text: root.clock(root.shownTime)
                    font.pixelSize: Style.font.caption; opacity: 0.6
                  }
                  Label {
                    anchors.right: parent.right; anchors.bottom: parent.bottom
                    visible: root.pos.length > 0
                    text: root.clock(root.pos.length)
                    font.pixelSize: Style.font.caption; opacity: 0.6
                  }
                }
                Flow {
                  Layout.topMargin: 4
                  Layout.fillWidth: true
                  spacing: 8
                  ActionButton { icon: "󰒮"; tone: root.teal; enabled: !!root.now; onClicked: root.run(["deck", "previous"]) }
                  ActionButton {
                    icon: root.deck.playing ? "󰏤" : "󰐊"
                    text: root.deck.playing ? strings.t("deck.pause") : strings.t("deck.play")
                    enabled: !!root.now || (root.deck.set || []).length > 0
                    onClicked: root.playPause()
                  }
                  ActionButton { icon: "󰒭"; text: strings.t("deck.next"); tone: root.teal; enabled: (root.deck.set || []).length > 0; onClicked: root.skip() }
                  // Playing above; the set and the night below the bar.
                  Rectangle { width: 1; height: 30; color: Util.alpha(root.ink, 0.18) }
                  ActionButton { icon: "✦"; text: strings.t("deck.fill"); enabled: !root.locked; onClicked: root.runLong(["deck", "fill", "--service", root.service]) }
                  ActionButton {
                    icon: "󰘶"
                    text: strings.t("deck.shape")
                    tone: root.shapeOpen ? root.amber : root.teal
                    enabled: (root.deck.set || []).length > 1 && !root.locked
                    onClicked: { root.shapeOpen = !root.shapeOpen; root.autodjOpen = false; root.saving = false; root.filterOpen = false }
                  }
                  // Auto-DJ: with three songs left, Grok adds more that carry the night on.
                  ActionButton {
                    icon: "∞"
                    text: root.djBusy ? strings.t("deck.autodjWorking") : strings.t("deck.autodj")
                    tone: root.deck.autodj ? root.amber : root.teal
                    onClicked: { root.autodjOpen = !root.autodjOpen; root.shapeOpen = false; root.saving = false; root.filterOpen = false }
                  }
                  // Sleep: off, 15, 30, 60 minutes, the end of this song.
                  ActionButton {
                    icon: "󰒲"
                    text: !root.sleep ? strings.t("deck.sleep") : root.sleep.song ? strings.t("deck.sleepSong") : strings.t("deck.sleepIn").arg(root.sleepMinutes)
                    tone: root.sleep ? root.amber : root.teal
                    onClicked: root.nextSleep()
                  }
                  // Soft: Next, Back, Pause and Play fade rather than cut (on the laptop).
                  ActionButton {
                    visible: !root.inSonos
                    icon: "∿"
                    text: strings.t(root.deck.softSkip === false ? "deck.softOff" : "deck.soft")
                    tone: root.deck.softSkip === false ? root.teal : root.amber
                    onClicked: {
                      const on = root.deck.softSkip === false
                      root.deck = Object.assign({}, root.deck, { softSkip: on })
                      root.run(["deck", "soft-skip", on ? "on" : "off"])
                    }
                  }
                  // Crossfade: Sonos fades one song into the next.
                  ActionButton {
                    id: crossfadeButton
                    visible: root.inSonos
                    icon: "󰡍"
                    text: strings.t("deck.crossfade")
                    tone: root.deck.crossfade ? root.amber : root.teal
                    onClicked: root.run(["deck", "crossfade", root.deck.crossfade ? "off" : "on"])
                  }
                  // The volume where the Deck plays: the Sonos room, or the
                  // laptop's speaker or headphones. Centred on the buttons.
                  Item {
                    visible: root.hereVolume !== null
                    width: volRow.implicitWidth + 12
                    height: crossfadeButton.implicitHeight
                    Row {
                      x: 12
                      id: volRow
                      anchors.verticalCenter: parent.verticalCenter
                      spacing: 8
                      Label { text: root.inSonos ? "󰜟" : root.outGlyph; font.family: "Iosevka Nerd Font Propo"; color: root.amber; anchors.verticalCenter: parent.verticalCenter }
                      ThemedSlider {
                        id: roomVol
                        anchors.verticalCenter: parent.verticalCenter
                        width: 170
                        label: ""; valueText: ""
                        value: root.hereVolume || 0
                        minimum: 0; maximum: 100; step: 2
                        fromColor: root.amber; toColor: root.teal
                        onCommitted: function(v) { root.run(["deck", "volume", String(Math.round(v))]) }
                      }
                      Label {
                        anchors.verticalCenter: parent.verticalCenter
                        width: 26
                        text: Commons.I18n.formatNumber(Math.round(roomVol.liveValue))
                        font.pixelSize: Style.font.caption; color: root.teal
                      }
                    }
                  }
                }
              }
            }

            // ---- up next: how long it runs, when it ends; undo, save, find, the wall
            RowLayout {
              Layout.fillWidth: true
              spacing: 14
              Label { text: strings.t("deck.upNext").toUpperCase(); font.pixelSize: Style.font.caption; font.letterSpacing: 2; color: root.amber }
              Label {
                Layout.fillWidth: true
                text: (root.deck.set || []).length > 0
                  ? strings.tn("deck.count", (root.deck.set || []).length).arg((root.deck.set || []).length)
                    + "  ·  " + root.span(root.setSeconds) + "  ·  " + strings.t("deck.endsAt").arg(root.clockAt(root.setSeconds))
                    + (root.djBusy ? "  ·  ∞ " + strings.t("deck.autodjFinding") + "…" : !root.deck.autodj ? "" : "  ·  ∞ " + ((root.deck.set || []).length > 3
                        ? strings.t("deck.autodjAt").arg(root.clockAt(root.startsAt[(root.deck.set || []).length - 3] || 0))
                        : strings.t("deck.autodjSoon"))
                      + (root.directionLabel !== "" ? ", " + root.directionLabel : "")
                      + (root.towardLabel !== "" ? ", " + root.towardLabel : ""))
                  : ""
                font.pixelSize: Style.font.caption
                opacity: 0.6
              }
              // Picked songs: what to do with all of them.
              Label {
                visible: root.selectedUids.length > 0
                text: strings.tn("deck.picked", root.selectedUids.length).arg(root.selectedUids.length)
                font.pixelSize: Style.font.caption
                color: root.amber
              }
              HeadLink { visible: root.selectedUids.length > 0; glyph: "󰐊"; text: strings.t("deck.bloomNow"); onTapped: root.placePicked("now") }
              HeadLink { visible: root.selectedUids.length > 0; glyph: "󰒭"; text: strings.t("deck.bloomNext"); onTapped: root.placePicked("next") }
              HeadLink { visible: root.selectedUids.length > 0; glyph: "󰐒"; text: strings.t("deck.bloomLater"); onTapped: root.placePicked("end") }
              HeadLink { visible: root.selectedUids.length > 0 && !root.locked; glyph: "󰅖"; text: strings.t("deck.remove"); onTapped: root.placePicked("remove") }
              HeadLink { visible: root.selectedUids.length > 0; glyph: "󰜺"; onTapped: root.clearPicked() }
              // Otherwise: the tools for the set.
              HeadLink {
                visible: root.selectedUids.length === 0 && (root.deck.undo || 0) > 0 && !root.locked
                glyph: "󰕌"; text: strings.t("deck.undo"); onTapped: root.run(["deck", "undo"])
              }
              HeadLink {
                visible: root.selectedUids.length === 0 && (root.deck.set || []).length > 0
                glyph: "󰆓"; text: strings.t("deck.save")
                onTapped: { root.saving = true; root.filterOpen = false }
              }
              HeadLink {
                visible: root.selectedUids.length === 0
                glyph: "󰍉"; on: root.filterOpen; tip: strings.t("deck.findInSet")
                onTapped: { root.filterOpen = !root.filterOpen; if (!root.filterOpen) root.filter = ""; root.saving = false }
              }
              HeadLink {
                visible: root.selectedUids.length === 0
                glyph: root.wall ? "󰉹" : "󰕰"; on: root.wall; tip: strings.t("deck.wallTip")
                onTapped: root.wall = !root.wall
              }
              HeadLink {
                visible: root.selectedUids.length === 0 && (root.deck.set || []).length > 0 && !root.locked
                glyph: "󰆴"; tip: strings.t("deck.clearTip"); onTapped: root.run(["deck", "clear"])
              }
            }
            // Shape the set: reorder it by tempo, key and energy (pinned songs stay).
            Flow {
              Layout.fillWidth: true
              visible: root.shapeOpen
              spacing: 8
              Label { text: strings.t("deck.shapeHint"); font.pixelSize: Style.font.caption; opacity: 0.6; height: 30; verticalAlignment: Text.AlignVCenter }
              Repeater {
                model: root.shapes
                delegate: Rectangle {
                  required property var modelData
                  implicitWidth: chipRow.implicitWidth + 18
                  implicitHeight: 30
                  radius: 15
                  color: chipHover.hovered ? Util.alpha(root.amber, 0.18) : Util.alpha(root.amber, 0.06)
                  border.width: 1
                  border.color: Util.alpha(root.amber, chipHover.hovered ? 0.9 : 0.45)
                  Row {
                    id: chipRow
                    anchors.centerIn: parent
                    spacing: 6
                    Label { text: modelData.glyph; font.family: "Iosevka Nerd Font Propo"; color: root.amber }
                    Label { text: modelData.label; font.pixelSize: Style.font.caption; color: root.ink }
                  }
                  HoverHandler { id: chipHover; cursorShape: Qt.PointingHandCursor }
                  TapHandler {
                    onTapped: {
                      root.run(modelData.key === "shuffle" ? ["deck", "shuffle"] : ["deck", "shape", modelData.key])
                      root.shapeOpen = false
                    }
                  }
                }
              }
            }
            // Auto-DJ, all in one place: on or off, the way it takes the night,
            // somewhere new to head for, and whether it tidies its songs.
            Rectangle {
              Layout.fillWidth: true
              visible: root.autodjOpen
              implicitHeight: djCol.implicitHeight + 24
              radius: Style.cornerRadius > 0 ? 8 : 0
              color: Util.alpha(root.amber, 0.04)
              border.width: 1; border.color: Util.alpha(root.amber, 0.45)
              ColumnLayout {
                id: djCol
                x: 14; y: 12
                width: parent.width - 28
                spacing: 10
                RowLayout {
                  Layout.fillWidth: true
                  spacing: 8
                  Label { text: "∞  " + strings.t("deck.autodj").toUpperCase(); font.pixelSize: Style.font.caption; font.letterSpacing: 2; color: root.amber }
                  DjChip { text: strings.t("deck.autodjOn"); on: !!root.deck.autodj; onTapped: root.run(["deck", "autodj", "on"]) }
                  DjChip { text: strings.t("deck.autodjOff"); on: !root.deck.autodj; onTapped: root.run(["deck", "autodj", "off"]) }
                  Label { Layout.fillWidth: true; wrapMode: Text.Wrap; text: strings.t("deck.autodjAbout"); font.pixelSize: Style.font.caption; opacity: 0.55 }
                  RoundButton { glyph: "󰅖"; onClicked: root.autodjOpen = false }
                }
                Flow {
                  Layout.fillWidth: true
                  spacing: 8
                  Label { text: strings.t("deck.autodjDirection"); font.pixelSize: Style.font.caption; color: root.teal; height: 30; verticalAlignment: Text.AlignVCenter; width: 120 }
                  Repeater {
                    model: [
                      { key: "none", label: strings.t("deck.autodjFollow"), glyph: "∞" },
                      { key: "arc", label: strings.t("deck.autodjDirArc"), glyph: "󱗿" },
                      { key: "energy", label: strings.t("deck.autodjDirEnergy"), glyph: "󱐋" },
                      { key: "tempo", label: strings.t("deck.autodjDirTempo"), glyph: "󰓅" },
                      { key: "harmonic", label: strings.t("deck.autodjDirHarmonic"), glyph: "󰽰" },
                      { key: "smooth", label: strings.t("deck.autodjDirSmooth"), glyph: "󰾆" }
                    ]
                    delegate: DjChip {
                      required property var modelData
                      glyph: modelData.glyph; text: modelData.label
                      on: (root.deck.direction || "none") === modelData.key
                      onTapped: root.run(["deck", "autodj", "direction", modelData.key])
                    }
                  }
                }
                Flow {
                  Layout.fillWidth: true
                  visible: !root.locked
                  spacing: 8
                  Label { text: strings.t("deck.towardLabel"); font.pixelSize: Style.font.caption; color: root.teal; height: 30; verticalAlignment: Text.AlignVCenter; width: 120 }
                  Repeater {
                    model: root.towardPresets
                    delegate: DjChip {
                      required property var modelData
                      text: modelData.label
                      on: (root.deck.toward || {}).brief === modelData.brief
                      onTapped: if (!root.djBusy) root.runLong(["deck", "autodj", "toward", modelData.brief])
                    }
                  }
                  Rectangle {
                    width: 260; height: 30
                    radius: 15
                    color: Util.alpha(root.ink, 0.04)
                    border.width: 1; border.color: towardInput.activeFocus ? root.teal : Util.alpha(root.teal, 0.45)
                    TextInput {
                      id: towardInput
                      anchors.left: parent.left; anchors.right: towardGo.left
                      anchors.leftMargin: 12; anchors.rightMargin: 6
                      anchors.verticalCenter: parent.verticalCenter
                      color: root.ink; clip: true
                      font.family: Style.font.family; font.pixelSize: Style.font.caption
                      maximumLength: 120
                      onAccepted: if (text.trim() !== "" && !root.djBusy) { root.runLong(["deck", "autodj", "toward", text.trim()]); text = "" }
                      Label { visible: towardInput.text === ""; text: strings.t("deck.towardHint"); font.pixelSize: Style.font.caption; opacity: 0.4 }
                    }
                    HeadLink {
                      id: towardGo
                      anchors.right: parent.right; anchors.rightMargin: 8
                      anchors.verticalCenter: parent.verticalCenter
                      text: strings.t("deck.towardGo")
                      onTapped: towardInput.accepted()
                    }
                  }
                }
                // What it's doing right now: finding songs (a pulsing ∞), or where it's heading.
                RowLayout {
                  visible: !!root.djBusy || root.towardLabel !== ""
                  Layout.fillWidth: true
                  spacing: 10
                  Label {
                    text: "∞"; color: root.amber; font.pixelSize: Style.font.body + 2
                    SequentialAnimation on opacity {
                      running: !!root.djBusy && !Style.reduceMotion
                      loops: Animation.Infinite
                      NumberAnimation { from: 1; to: 0.25; duration: 700; easing.type: Easing.InOutSine }
                      NumberAnimation { from: 0.25; to: 1; duration: 700; easing.type: Easing.InOutSine }
                    }
                  }
                  Label {
                    Layout.fillWidth: true
                    wrapMode: Text.Wrap
                    text: root.djBusy ? root.djBusyText : root.towardLabel.charAt(0).toUpperCase() + root.towardLabel.slice(1)
                    font.pixelSize: Style.font.caption; color: root.djBusy ? root.amber : root.ink
                  }
                  HeadLink {
                    visible: !root.djBusy && !!root.deck.toward && !root.locked
                    glyph: "󰅖"; text: strings.t("deck.towardOff")
                    onTapped: root.run(["deck", "autodj", "toward", "off"])
                  }
                }
                // Auto-DJ tidies its own songs once their real tempos are in (on unless you turn it off).
                HeadLink {
                  glyph: root.deck.autoTidy !== false ? "󰄲" : "󰄱"
                  text: strings.t("deck.autoTidy")
                  tip: strings.t("deck.autoTidyTip")
                  onTapped: root.run(["deck", "autodj", "tidy", root.deck.autoTidy !== false ? "off" : "on"])
                }
              }
            }
            // Naming a set to save (what, and where), or finding a song in this one.
            Rectangle {
              Layout.fillWidth: true
              visible: root.saving || root.filterOpen
              implicitHeight: panel.implicitHeight + 12
              radius: Style.cornerRadius > 0 ? 4 : 0
              color: Util.alpha(root.ink, 0.04)
              border.width: 1
              border.color: root.amber
              ColumnLayout {
                id: panel
                anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
                anchors.margins: 6
                anchors.leftMargin: 10
                spacing: 6
                RowLayout {
                  Layout.fillWidth: true
                  spacing: 8
                  Label { text: root.saving ? "󰆓" : "󰍉"; font.family: "Iosevka Nerd Font Propo"; color: root.amber }
                  TextInput {
                    id: lineInput
                    Layout.fillWidth: true
                    color: root.ink
                    font.family: Style.font.family
                    font.pixelSize: Style.font.body
                    clip: true
                    onVisibleChanged: if (visible) {
                      text = root.saving ? strings.t("deck.saveDefault").arg(new Date().toLocaleDateString(Qt.locale(Commons.I18n.formatLocale), Locale.ShortFormat)) : root.filter
                      forceActiveFocus(); selectAll()
                    }
                    onTextChanged: if (root.filterOpen && !root.saving) root.filter = text
                    onAccepted: { if (root.saving) root.saveAs(text); else stage.forceActiveFocus() }
                    Keys.onEscapePressed: { root.saving = false; root.filterOpen = false; root.filter = ""; stage.forceActiveFocus() }
                    Label {
                      visible: lineInput.text === ""
                      text: root.saving ? strings.t("deck.saveHint") : strings.t("deck.findInSet")
                      opacity: 0.4
                    }
                  }
                  ActionButton {
                    id: saveGo
                    visible: root.saving
                    icon: "󰆓"; text: strings.t("deck.save")
                    enabled: lineInput.text.trim() !== ""
                    onClicked: root.openBloom("save", { title: lineInput.text.trim(), thumb: root.now ? root.now.thumb || "" : "" }, "",
                                              saveGo.mapToItem(root.stageItem, saveGo.width / 2, saveGo.height / 2))
                  }
                  RoundButton { glyph: "󰅖"; onClicked: { root.saving = false; root.filterOpen = false; root.filter = ""; stage.forceActiveFocus() } }
                }
                // What to save, and where to.
                Flow {
                  Layout.fillWidth: true
                  visible: root.saving
                  spacing: 14
                  Repeater {
                    model: [{ key: "next", label: strings.t("deck.saveNext") }, { key: "played", label: strings.t("deck.savePlayed") },
                            { key: "all", label: strings.t("deck.saveAll") }]
                    delegate: HeadLink {
                      required property var modelData
                      glyph: root.savePart === modelData.key ? "󰄵" : "󰄱"
                      text: modelData.label
                      on: root.savePart === modelData.key
                      onTapped: root.savePart = modelData.key
                    }
                  }
                }
                Label {
                  visible: root.saving
                  Layout.fillWidth: true
                  wrapMode: Text.Wrap
                  text: strings.t("deck.saveThereHint")
                  font.pixelSize: Style.font.caption
                  opacity: 0.55
                }
              }
            }

            RowLayout {
              Layout.fillWidth: true
              Layout.fillHeight: true
              spacing: 10

            Item {
              id: listBox
              Layout.fillWidth: true
              Layout.fillHeight: true

              // Dropping below the last song: the end of the set.
              DropArea {
                anchors.fill: parent
                keys: ["deck-song"]
                onEntered: root.dropIndex = setModel.count
                onDropped: root.dropInSet(setModel.count)
              }
              TapHandler { onTapped: { stage.forceActiveFocus(); if (root.selectedUids.length) root.clearPicked() } }
              ListView {
                id: setList
                anchors.fill: parent
                visible: !root.wall
                // Until you scroll it yourself, the top (played, then what's playing) stays in view.
                property bool moved: false
                onMovementStarted: moved = true
                onCountChanged: if (!moved) topAgain.restart()
                onOriginYChanged: if (!moved) topAgain.restart()
                Timer { id: topAgain; interval: 60; onTriggered: setList.contentY = setList.originY }
                clip: true
                spacing: 0
                model: setModel
                boundsBehavior: Flickable.StopAtBounds
                interactive: !root.dragging
                move: Transition { NumberAnimation { properties: "y"; duration: Style.duration(260); easing.type: Easing.OutCubic } }
                moveDisplaced: Transition { NumberAnimation { properties: "y"; duration: Style.duration(260); easing.type: Easing.OutCubic } }
                displaced: Transition { NumberAnimation { properties: "y"; duration: Style.duration(220); easing.type: Easing.OutCubic } }
                add: Transition {
                  NumberAnimation { properties: "opacity"; from: 0; to: 1; duration: Style.duration(200) }
                  NumberAnimation { properties: "scale"; from: 0.97; to: 1; duration: Style.duration(200); easing.type: Easing.OutCubic }
                }

                // ---- under the last song: one that wouldn't play (crossed out,
                // for a minute), and Auto-DJ lining up more.
                footer: Column {
                  id: tail
                  width: setList.width
                  topPadding: 6
                  spacing: 6
                  property real clock: Date.now() / 1000
                  readonly property var gone: root.deck.unplayable && tail.clock - (root.deck.unplayable.at || 0) < 60
                                              ? root.deck.unplayable : null
                  Timer {
                    interval: 5000; repeat: true
                    running: !!root.deck.unplayable || !!root.deck.autodj
                    onTriggered: tail.clock = Date.now() / 1000
                  }
                  Connections { target: root; function onDeckChanged() { tail.clock = Date.now() / 1000 } }
                  Rectangle {
                    visible: !!tail.gone
                    width: parent.width - 16
                    height: 40
                    radius: Style.cornerRadius > 0 ? 6 : 0
                    color: Util.alpha(Commons.Color.warning, 0.06)
                    border.width: 1
                    border.color: Util.alpha(Commons.Color.warning, 0.3)
                    Row {
                      anchors.verticalCenter: parent.verticalCenter
                      x: 14
                      spacing: 10
                      Label { text: "󰒭"; font.family: "Iosevka Nerd Font Propo"; color: Commons.Color.warning; anchors.verticalCenter: parent.verticalCenter }
                      Label {
                        anchors.verticalCenter: parent.verticalCenter
                        textFormat: Text.PlainText
                        text: tail.gone ? tail.gone.title + "  ·  " + tail.gone.artist : ""
                        font.strikeout: true
                        opacity: 0.6
                      }
                      Label {
                        anchors.verticalCenter: parent.verticalCenter
                        text: strings.t("deck.unplayable")
                        font.pixelSize: Style.font.caption
                        color: Commons.Color.warning
                      }
                    }
                  }
                  Rectangle {
                    visible: root.runningLow
                    width: parent.width - 16
                    height: 46
                    radius: Style.cornerRadius > 0 ? 6 : 0
                    color: Util.alpha(root.amber, 0.05)
                    border.width: 1
                    border.color: Util.alpha(root.amber, 0.3)
                    Row {
                      anchors.centerIn: parent
                      spacing: 14
                      Label {
                        anchors.verticalCenter: parent.verticalCenter
                        text: strings.tn("deck.runningLow", (root.deck.set || []).length).arg((root.deck.set || []).length)
                        font.pixelSize: Style.font.caption; color: root.amber
                      }
                      HeadLink { anchors.verticalCenter: parent.verticalCenter; glyph: "✦"; text: strings.t("deck.fill"); on: true; onTapped: root.run(["deck", "fill"]) }
                      HeadLink { anchors.verticalCenter: parent.verticalCenter; glyph: "∞"; text: strings.t("deck.autodjTurnOn"); on: true; onTapped: root.run(["deck", "autodj", "on"]) }
                    }
                  }
                  Rectangle {
                    visible: !!root.deck.autodj
                    width: parent.width - 16
                    height: 52
                    radius: Style.cornerRadius > 0 ? 6 : 0
                    color: "transparent"
                    border.width: 1
                    border.color: Util.alpha(root.teal, 0.22)
                    Row {
                      anchors.centerIn: parent
                      spacing: 10
                      Label {
                        id: tailGlyph
                        text: "∞"
                        color: root.teal
                        anchors.verticalCenter: parent.verticalCenter
                        SequentialAnimation on opacity {
                          running: !!root.deck.autodj && root.open && Style.duration(100) > 0
                          loops: Animation.Infinite
                          NumberAnimation { to: 0.35; duration: 1100; easing.type: Easing.InOutSine }
                          NumberAnimation { to: 1; duration: 1100; easing.type: Easing.InOutSine }
                        }
                      }
                      Label {
                        anchors.verticalCenter: parent.verticalCenter
                        text: root.djBusy ? root.djBusyText : strings.t("deck.autodjLining")
                        font.pixelSize: Style.font.caption
                        font.letterSpacing: 1
                        color: root.teal
                        opacity: 0.8
                      }
                    }
                  }
                  Item { width: 1; height: 8 }
                }

                // ---- what's played (folded) and the playhead: the set as past, now and next.
                header: Column {
                  width: setList.width
                  spacing: 4
                  bottomPadding: 8
                  // It grows once the song and what's played arrive: keep the top in view.
                  onHeightChanged: if (!setList.moved) topAgain.restart()
                  Item {
                    width: parent.width
                    height: 26
                    visible: (root.deck.played || []).length > 0 && root.filter === ""
                    Label {
                      anchors.verticalCenter: parent.verticalCenter
                      text: (root.playedOpen ? "󰅀  " : "󰅂  ") + strings.t("deck.played").toUpperCase() + "  ·  " + (root.deck.played || []).length
                      font.family: "Iosevka Nerd Font Propo"
                      font.pixelSize: Style.font.caption
                      font.letterSpacing: 2
                      opacity: playedHover.hovered ? 0.9 : 0.5
                    }
                    HoverHandler { id: playedHover; cursorShape: Qt.PointingHandCursor }
                    TapHandler { onTapped: root.playedOpen = !root.playedOpen }
                  }
                  Repeater {
                    model: root.playedOpen && root.filter === "" ? (root.deck.played || []) : []
                    delegate: Rectangle {
                      id: was
                      required property var modelData
                      required property int index
                      // A new hour starts here: say which (the night read back in hours).
                      readonly property string hour: root.hourOf(modelData.playedAt || 0)
                      readonly property bool newHour: hour !== "" && (index === 0 || root.hourOf((root.deck.played[index - 1] || {}).playedAt || 0) !== hour)
                      width: setList.width
                      height: 40 + (newHour ? 24 : 0)
                      radius: Style.cornerRadius > 0 ? 4 : 0
                      color: wasHover.hovered ? Util.alpha(root.ink, 0.05) : "transparent"
                      opacity: wasHover.hovered ? 1 : 0.55
                      Label {
                        visible: was.newHour
                        x: 40; y: 6
                        text: was.hour
                        font.pixelSize: Style.font.caption; font.letterSpacing: 2; color: root.teal
                      }
                      RowLayout {
                        anchors.fill: parent
                        anchors.topMargin: was.newHour ? 24 : 0
                        anchors.leftMargin: 40; anchors.rightMargin: 8
                        spacing: 10
                        Cover { url: was.modelData.thumb || ""; size: 30 }
                        Label { Layout.fillWidth: true; text: was.modelData.title + "  ·  " + was.modelData.artist; font.pixelSize: Style.font.caption }
                        Label { text: "󰑙"; font.family: "Iosevka Nerd Font Propo"; visible: wasHover.hovered; color: root.amber }
                      }
                      HoverHandler { id: wasHover; cursorShape: Qt.PointingHandCursor }
                      TapHandler { onTapped: root.run(["deck", "play", was.modelData.uid]) }
                      DragHandler {
                        target: null
                        onActiveChanged: if (active) root.beginDrag("played", was.modelData.uid, null, was.modelData.title, was.modelData.thumb || "")
                                         else if (root.dragging) root.endDrag()
                        onCentroidChanged: if (active) root.moveGhost(was.mapToItem(stage, centroid.position.x, centroid.position.y))
                      }
                    }
                  }
                  // The playhead.
                  Rectangle {
                    width: setList.width
                    height: 46
                    visible: !!root.now && root.filter === ""
                    radius: Style.cornerRadius > 0 ? 5 : 0
                    color: Util.alpha(root.amber, 0.08)
                    clip: true
                    Rectangle { width: 3; height: parent.height; color: root.amber }
                    RowLayout {
                      anchors.fill: parent
                      anchors.leftMargin: 12; anchors.rightMargin: 6
                      spacing: 12
                      Label { text: strings.t("deck.nowShort").toUpperCase(); font.pixelSize: Style.font.caption; font.letterSpacing: 3; color: root.amber; Layout.preferredWidth: 34 }
                      Cover { url: root.now ? root.now.thumb || "" : ""; size: 32 }
                      Label {
                        Layout.fillWidth: true
                        text: root.now ? root.now.title + "  ·  " + root.now.artist : ""
                        font.bold: true
                        font.pixelSize: Style.font.caption
                        elide: Text.ElideRight
                      }
                      // What's playing: its key and tempo, in the same columns as the songs below.
                      Label {
                        Layout.preferredWidth: root.keyColumn
                        horizontalAlignment: Text.AlignHCenter
                        text: root.now && root.now.key ? root.now.key : "–"
                        font.pixelSize: Style.font.caption; font.bold: true; color: root.amber
                        opacity: root.now && root.now.key ? 1 : 0.3
                      }
                      Label {
                        Layout.preferredWidth: root.bpmColumn
                        horizontalAlignment: Text.AlignHCenter
                        text: root.now && root.now.bpm > 0 ? Math.round(root.now.bpm) : "–"
                        font.pixelSize: Style.font.caption; color: root.amber
                        opacity: root.now && root.now.bpm > 0 ? 1 : 0.3
                      }
                      Label {
                        Layout.preferredWidth: root.timeColumn
                        horizontalAlignment: Text.AlignRight
                        text: "−" + root.clock(root.nowLeft)
                        font.pixelSize: Style.font.caption
                        color: root.teal
                      }
                      Item {
                        Layout.preferredWidth: root.actionsColumn
                        implicitHeight: 20
                        Equalizer { anchors.centerIn: parent; visible: root.deck.playing; on: root.deck.playing }
                      }
                    }
                    Rectangle {
                      anchors.bottom: parent.bottom
                      height: 2
                      width: root.pos.length > 0 ? parent.width * Math.min(1, root.shownTime / root.pos.length) : 0
                      gradient: Gradient {
                        orientation: Gradient.Horizontal
                        GradientStop { position: 0; color: root.amber }
                        GradientStop { position: 1; color: root.teal }
                      }
                    }
                  }
                }

                delegate: Item {
                  id: slot
                  required property int index
                  required property string uid
                  required property string title
                  required property string artist
                  required property string thumb
                  required property string service
                  required property string why
                  required property string chapter
                  required property string warn
                  required property string from
                  required property real bpm
                  required property string key
                  required property real energy
                  readonly property var info: root.chapters[index] || ({ name: "", opens: false, head: -1, count: 0, seconds: 0 })
                  readonly property bool heading: info.opens && root.filter === ""
                  readonly property bool isFolded: heading && !!root.folded[uid]
                  readonly property bool shown: root.matches(title, artist) && !root.hiddenAt(index) && !isFolded
                  width: setList.width
                  height: (heading ? 36 : 0) + (shown ? 56 : 0)
                  visible: height > 0
                  clip: true

                  // ---- a chapter starts here: its name, how long, when; fold it, drag it, rename it
                  Item {
                    id: head
                    visible: slot.heading
                    width: parent.width
                    height: 32
                    RowLayout {
                      anchors.fill: parent
                      anchors.leftMargin: 4
                      spacing: 10
                      Label {
                        text: slot.isFolded ? "󰅂" : "󰅀"
                        font.family: "Iosevka Nerd Font Propo"
                        color: root.amber
                        HoverHandler { cursorShape: Qt.PointingHandCursor }
                        TapHandler { onTapped: root.foldChapter(slot.uid) }
                      }
                      Label {
                        visible: root.renaming !== slot.uid
                        text: slot.info.name.toUpperCase()
                        font.pixelSize: Style.font.caption
                        font.letterSpacing: 3
                        font.bold: true
                        color: root.amber
                        HoverHandler { cursorShape: Qt.IBeamCursor }
                        TapHandler { onTapped: root.renaming = slot.uid }
                      }
                      TextInput {
                        id: rename
                        visible: root.renaming === slot.uid
                        Layout.preferredWidth: 220
                        text: slot.info.name
                        color: root.amber
                        font.family: Style.font.family
                        font.pixelSize: Style.font.caption
                        font.bold: true
                        onVisibleChanged: if (visible) { text = slot.info.name; forceActiveFocus(); selectAll() }
                        onAccepted: { root.run(["deck", "chapter", slot.uid, text.trim()]); root.renaming = ""; stage.forceActiveFocus() }
                        Keys.onEscapePressed: { root.renaming = ""; stage.forceActiveFocus() }
                        onActiveFocusChanged: if (!activeFocus && root.renaming === slot.uid) root.renaming = ""
                      }
                      Label {
                        text: strings.tn("deck.count", slot.info.count).arg(slot.info.count) + "  ·  " + root.span(slot.info.seconds)
                              + "  ·  " + root.clockAt(root.startsAt[slot.index] || 0)
                        font.pixelSize: Style.font.caption
                        opacity: 0.5
                      }
                      Rectangle {
                        Layout.fillWidth: true
                        height: 1
                        gradient: Gradient {
                          orientation: Gradient.Horizontal
                          GradientStop { position: 0; color: Util.alpha(root.amber, 0.5) }
                          GradientStop { position: 1; color: Util.alpha(root.amber, 0) }
                        }
                      }
                      Label {
                        text: "󰅖"
                        font.family: "Iosevka Nerd Font Propo"
                        opacity: headHover.hovered ? 0.6 : 0
                        HoverHandler { cursorShape: Qt.PointingHandCursor }
                        TapHandler { onTapped: root.run(["deck", "chapter", slot.uid, ""]) }
                      }
                    }
                    HoverHandler { id: headHover; cursorShape: root.dragging ? Qt.ClosedHandCursor : Qt.OpenHandCursor }
                    DragHandler {
                      target: null
                      onActiveChanged: if (active) root.beginDrag("chapter", slot.uid, null, slot.info.name, slot.thumb)
                                       else if (root.dragging) root.endDrag()
                      onCentroidChanged: if (active) root.moveGhost(head.mapToItem(stage, centroid.position.x, centroid.position.y))
                    }
                    DropArea {
                      anchors.fill: parent
                      keys: ["deck-song"]
                      onEntered: root.dropIndex = slot.index
                      onPositionChanged: root.dropIndex = slot.index
                      onDropped: root.dropInSet(slot.index)
                    }
                  }

                  Rectangle {
                    id: row
                    readonly property bool isPinned: root.pinned(slot.uid)
                    readonly property bool lifted: root.dragging && root.dragFrom === "set" && root.dragUid === slot.uid
                    readonly property bool picked: !!root.selected[slot.uid]
                    readonly property var warns: slot.warn === "" ? [] : slot.warn.split(",")
                    y: slot.heading ? 36 : 0
                    visible: slot.shown
                    width: parent.width
                    height: 52
                    radius: Style.cornerRadius > 0 ? 5 : 0
                    color: picked ? Util.alpha(root.amber, 0.13)
                         : rowHover.hovered || rowDrop.containsDrag ? Util.alpha(root.ink, 0.06) : Util.alpha(root.ink, 0.025)
                    border.width: 1
                    border.color: picked ? root.amber : isPinned ? Util.alpha(Commons.Color.warning, 0.5) : (rowHover.hovered ? Util.alpha(root.ink, 0.12) : "transparent")
                    opacity: lifted ? 0.3 : 1
                    // Where a drop goes: a bright line above this row.
                    Rectangle {
                      anchors.left: parent.left; anchors.right: parent.right
                      anchors.bottom: parent.top; anchors.bottomMargin: 1
                      height: 3
                      radius: 2
                      color: root.amber
                      visible: root.dragging && root.dropIndex === slot.index && !slot.heading
                    }
                    RowLayout {
                      anchors.fill: parent
                      anchors.margins: 6
                      spacing: 12
                      // The number; on hover, start a chapter here.
                      Item {
                        Layout.preferredWidth: 22
                        Layout.fillHeight: true
                        Label {
                          anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                          visible: !(rowHover.hovered && !slot.heading)
                          text: String(slot.index + 1); font.pixelSize: Style.font.caption; opacity: 0.4
                        }
                        Label {
                          anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                          visible: rowHover.hovered && !slot.heading
                          text: "§"
                          color: root.amber
                          opacity: chapterHover.hovered ? 1 : 0.6
                          HoverHandler { id: chapterHover; cursorShape: Qt.PointingHandCursor }
                          TapHandler { onTapped: root.newChapter(slot.uid) }
                        }
                      }
                      Cover { url: slot.thumb; size: 42 }
                      // The song: title, then who and why (where it came from, and
                      // anything that doesn't sit well, on hover). Long names stop
                      // short, so the columns after them never move.
                      ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 2
                        Label { Layout.fillWidth: true; text: slot.title; font.bold: true; elide: Text.ElideRight }
                        Label {
                          Layout.fillWidth: true
                          readonly property string reasons: row.warns.map(w => strings.t("deck.warn." + w)).join("  ·  ")
                          text: root.serviceGlyph(slot.service) + "  " + slot.artist
                                + (rowHover.hovered ? (reasons !== "" ? "  ·  ◆ " + reasons : slot.from !== "" ? "  ·  " + slot.from : "")
                                                    : slot.why !== "" ? "  ·  ✦ " + slot.why : "")
                          font.family: "Iosevka Nerd Font Propo"
                          font.pixelSize: Style.font.caption
                          color: rowHover.hovered && reasons !== "" ? Commons.Color.warning : root.ink
                          opacity: 0.6
                          elide: Text.ElideRight
                        }
                      }
                      // Key, read against the song before it (the playing one, for the
                      // next): teal when it mixes, amber when it clashes.
                      Item {
                        id: ktChip
                        readonly property var before: slot.index === 0 ? root.now
                                                    : (slot.index - 1 < setModel.count ? setModel.get(slot.index - 1) : null)
                        readonly property bool keyOk: !before || root.keysFit(before.key || "", slot.key)
                        readonly property var step: before ? root.tempoStep(before.bpm || 0, slot.bpm) : null
                        readonly property bool jump: step !== null && !step.fits
                        Layout.preferredWidth: root.keyColumn
                        Layout.fillHeight: true
                        Label {
                          anchors.centerIn: parent
                          text: slot.key !== "" ? slot.key : "–"
                          font.pixelSize: Style.font.caption
                          font.bold: slot.key !== ""
                          color: !ktChip.keyOk ? Commons.Color.warning : root.teal
                          opacity: slot.key !== "" ? 1 : 0.3
                        }
                      }
                      // Tempo, and its step from the song before (amber past 8%).
                      Item {
                        Layout.preferredWidth: root.bpmColumn
                        Layout.fillHeight: true
                        Column {
                          anchors.centerIn: parent
                          spacing: 0
                          Label {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: slot.bpm > 0 ? Math.round(slot.bpm) : "–"
                            font.pixelSize: Style.font.caption
                            color: ktChip.jump ? Commons.Color.warning : root.teal
                            opacity: slot.bpm > 0 ? 1 : 0.3
                          }
                          Label {
                            anchors.horizontalCenter: parent.horizontalCenter
                            visible: slot.bpm > 0 && ktChip.step !== null && ktChip.step.text !== ""
                            text: ktChip.step === null ? "" : ktChip.step.text
                            font.pixelSize: Style.font.caption - 2
                            color: ktChip.jump ? Commons.Color.warning : root.teal
                            opacity: 0.6
                          }
                        }
                      }
                      // When it starts.
                      Label {
                        Layout.preferredWidth: root.timeColumn
                        horizontalAlignment: Text.AlignRight
                        text: root.clockAt(root.startsAt[slot.index] || 0)
                        font.pixelSize: Style.font.caption
                        color: root.teal
                        opacity: 0.75
                      }
                      // Play, pin, remove: there on hover (a pin stays lit), their room kept.
                      Row {
                        Layout.preferredWidth: root.actionsColumn
                        spacing: 0
                        RoundButton { glyph: "󰐊"; tip: strings.t("deck.playNow"); opacity: rowHover.hovered ? 1 : 0; onClicked: root.run(["deck", "play", slot.uid]) }
                        RoundButton { glyph: row.isPinned ? "󰐃" : "󰤰"; tip: row.isPinned ? strings.t("deck.unpin") : strings.t("deck.pin"); on: row.isPinned
                                      opacity: rowHover.hovered || row.isPinned ? 1 : 0; onClicked: root.run(["deck", "pin", slot.uid]) }
                        RoundButton { visible: !root.locked; glyph: "󰅖"; tip: strings.t("deck.remove"); opacity: rowHover.hovered ? 1 : 0; onClicked: root.run(["deck", "remove", slot.uid]) }
                      }
                    }
                    HoverHandler { id: rowHover; cursorShape: root.dragging ? Qt.ClosedHandCursor : Qt.OpenHandCursor }
                    TapHandler {
                      id: rowTap
                      longPressThreshold: 0.5
                      readonly property var song: ({ uid: slot.uid, title: slot.title, artist: slot.artist, thumb: slot.thumb })
                      onTapped: function(point) {
                        stage.forceActiveFocus()
                        if (point.position.x > row.width - 120 || point.position.x < 40) return       // the number; play, pin, remove
                        if (point.modifiers & (Qt.ControlModifier | Qt.ShiftModifier)) { root.pick(slot.uid, point.modifiers); return }
                        root.openBloom("set", song, slot.uid, row.mapToItem(root.stageItem, point.position.x, point.position.y))
                      }
                      onLongPressed: root.openBloom("set", song, slot.uid, row.mapToItem(root.stageItem, rowTap.point.position.x, rowTap.point.position.y))
                    }
                    DragHandler {
                      target: null
                      grabPermissions: PointerHandler.CanTakeOverFromAnything
                      // In the set, moving always drags the song: if a hold has
                      // just opened its petals, they close and the drag goes on.
                      onActiveChanged: {
                        if (active) {
                          if (root.bloomOpen) root.closeBloom()
                          root.beginDrag("set", slot.uid, null, slot.title, slot.thumb)
                        }
                        else if (root.dragging) root.endDrag()
                      }
                      onCentroidChanged: if (active) root.moveGhost(row.mapToItem(root.stageItem, centroid.position.x, centroid.position.y))
                    }
                    DropArea {
                      id: rowDrop
                      anchors.fill: parent
                      keys: ["deck-song"]
                      // The top half drops before this row, the bottom half after it.
                      onPositionChanged: function(drag) { root.dropIndex = drag.y < height / 2 ? slot.index : slot.index + 1 }
                      onEntered: function(drag) { root.dropIndex = drag.y < height / 2 ? slot.index : slot.index + 1 }
                      onDropped: root.dropInSet(root.dropIndex)
                    }
                  }
                }
              }

              // ---- the wall: the set as big covers, for across the room
              GridView {
                id: wallView
                anchors.fill: parent
                visible: root.wall
                clip: true
                model: setModel
                boundsBehavior: Flickable.StopAtBounds
                cellWidth: Math.floor(width / Math.max(1, Math.floor(width / 176)))
                cellHeight: cellWidth + 44
                header: Item {
                  width: wallView.width
                  height: root.now ? 196 : 0
                  visible: !!root.now
                  Rectangle {
                    anchors.fill: parent; anchors.margins: 7; anchors.bottomMargin: 12
                    radius: Style.cornerRadius > 0 ? 6 : 0
                    color: Util.alpha(root.amber, 0.07)
                    border.width: 1; border.color: Util.alpha(root.amber, 0.35)
                    Cover { id: wallNow; x: 12; y: 12; size: parent.height - 24; url: root.now ? root.now.thumb || "" : "" }
                    ColumnLayout {
                      anchors.left: wallNow.right; anchors.leftMargin: 18; anchors.right: parent.right; anchors.rightMargin: 18
                      anchors.verticalCenter: parent.verticalCenter
                      spacing: 6
                      Label { text: strings.t("deck.nowShort").toUpperCase(); font.pixelSize: Style.font.caption; font.letterSpacing: 3; color: root.amber }
                      Label { Layout.fillWidth: true; text: root.now ? root.titleParts(root.now.title).main : ""; font.pixelSize: 26; font.bold: true; color: root.amber; elide: Text.ElideRight }
                      Label { Layout.fillWidth: true; text: root.now ? root.now.artist : ""; font.pixelSize: Style.font.subtitle; elide: Text.ElideRight }
                      Rectangle {
                        Layout.fillWidth: true; Layout.topMargin: 6
                        height: 3; radius: 1.5
                        color: Util.alpha(root.ink, 0.12)
                        Rectangle {
                          height: parent.height; radius: 1.5
                          width: parent.width * Math.min(1, root.shownTime / Math.max(1, root.pos.length || root.lengthOf(root.now)))
                          gradient: Gradient { orientation: Gradient.Horizontal; GradientStop { position: 0; color: root.amber } GradientStop { position: 1; color: root.teal } }
                        }
                      }
                      Label { text: "−" + root.clock(root.nowLeft); font.pixelSize: Style.font.caption; color: root.teal }
                    }
                  }
                }
                delegate: Item {
                  id: tile
                  required property int index
                  required property string uid
                  required property string title
                  required property string artist
                  required property string thumb
                  readonly property bool picked: !!root.selected[uid]
                  width: wallView.cellWidth
                  height: wallView.cellHeight
                  opacity: root.matches(title, artist) ? 1 : 0.15
                  Cover {
                    id: big
                    x: 7; y: 7
                    width: parent.width - 14; height: width
                    size: width
                    url: tile.thumb
                    border.width: tile.picked ? 2 : 0
                    border.color: root.amber
                    scale: wallHover.hovered ? 1.03 : 1
                    Behavior on scale { NumberAnimation { duration: Style.duration(160); easing.type: Easing.OutCubic } }
                  }
                  Rectangle {
                    x: big.x + 6; y: big.y + 6
                    implicitWidth: num.implicitWidth + 10; implicitHeight: num.implicitHeight + 4
                    radius: Style.cornerRadius > 0 ? 3 : 0
                    color: Util.alpha(root.ground, 0.75)
                    Label { id: num; anchors.centerIn: parent; text: String(tile.index + 1); font.pixelSize: Style.font.caption; color: root.amber }
                  }
                  Rectangle {
                    anchors.right: big.right; anchors.bottom: big.bottom; anchors.margins: 6
                    implicitWidth: at.implicitWidth + 10; implicitHeight: at.implicitHeight + 4
                    radius: Style.cornerRadius > 0 ? 3 : 0
                    color: Util.alpha(root.ground, 0.75)
                    Label { id: at; anchors.centerIn: parent; text: root.clockAt(root.startsAt[tile.index] || 0); font.pixelSize: Style.font.caption; color: root.teal }
                  }
                  Label { x: 8; y: big.y + big.height + 6; width: parent.width - 16; text: tile.title; font.bold: true; font.pixelSize: Style.font.caption }
                  Label { x: 8; y: big.y + big.height + 24; width: parent.width - 16; text: tile.artist; font.pixelSize: Style.font.caption; opacity: 0.6 }
                  HoverHandler { id: wallHover; cursorShape: Qt.PointingHandCursor }
                  TapHandler {
                    onTapped: function(point) {
                      stage.forceActiveFocus()
                      if (point.modifiers & (Qt.ControlModifier | Qt.ShiftModifier)) { root.pick(tile.uid, point.modifiers); return }
                      root.openBloom("set", { uid: tile.uid, title: tile.title, artist: tile.artist, thumb: tile.thumb }, tile.uid,
                                     tile.mapToItem(root.stageItem, point.position.x, point.position.y))
                    }
                  }
                }
              }

              Label {
                anchors.centerIn: parent
                visible: setModel.count === 0
                width: parent.width * 0.7
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.Wrap
                text: strings.t("deck.setHint")
                opacity: 0.45
              }
              // ---- the heads-up: the next song, in the last 20 seconds of this one
              Rectangle {
                id: headsUp
                readonly property var nextSong: (root.deck.set || [])[0] || null
                readonly property bool shown: root.deck.playing && !!nextSong && root.pos.length > 0
                                              && root.nowLeft > 0 && root.nowLeft <= 20 && !root.dragging && !root.bloomOpen
                z: 5
                width: Math.min(380, parent.width - 24)
                height: 64
                // Low down, clear of what's playing and the next song's row; the End pill moves up for it.
                y: parent.height - height - 58
                x: shown ? parent.width - width - 12 : parent.width + 12
                opacity: shown ? 1 : 0
                visible: opacity > 0
                Behavior on x { NumberAnimation { duration: Style.duration(260); easing.type: Easing.OutCubic } }
                Behavior on opacity { NumberAnimation { duration: Style.duration(200) } }
                radius: Style.cornerRadius > 0 ? 6 : 0
                color: Qt.tint(root.ground, Util.alpha(root.amber, 0.1))
                border.width: 1
                border.color: Util.alpha(root.amber, 0.6)
                RowLayout {
                  anchors.fill: parent
                  anchors.margins: 8
                  spacing: 10
                  Cover { url: headsUp.nextSong ? headsUp.nextSong.thumb || "" : ""; size: 46 }
                  ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 0
                    Label { text: strings.t("deck.nextIn").arg(Math.ceil(root.nowLeft)).toUpperCase(); font.pixelSize: Style.font.caption; font.letterSpacing: 2; color: root.amber }
                    Label { Layout.fillWidth: true; text: headsUp.nextSong ? headsUp.nextSong.title : ""; font.bold: true; font.pixelSize: Style.font.caption }
                    Label { Layout.fillWidth: true; text: headsUp.nextSong ? headsUp.nextSong.artist : ""; font.pixelSize: Style.font.caption; opacity: 0.6 }
                  }
                  ColumnLayout {
                    spacing: 4
                    HeadLink { glyph: "󰒬"; text: strings.t("deck.skipIt"); onTapped: root.run(["deck", "remove", headsUp.nextSong.uid]) }
                    HeadLink { glyph: "󰐒"; text: strings.t("deck.bloomLater"); onTapped: root.run(["deck", "move", headsUp.nextSong.uid, String((root.deck.set || []).length)]) }
                  }
                }
              }

              // The end-of-set marker, when dropping below the last song.
              Rectangle {
                x: 0
                width: setList.width
                height: 3
                radius: 2
                color: root.amber
                y: Math.min(setList.contentHeight + setList.originY - setList.contentY, setList.height) + 1
                visible: root.dragging && root.dropIndex === setModel.count && setModel.count > 0 && !root.wall
              }

              // ---- back to the top, or to the end, once you've scrolled away
              Row {
                anchors.horizontalCenter: parent.horizontalCenter; anchors.bottom: parent.bottom
                anchors.margins: 12
                spacing: 8
                readonly property var list: root.wall ? wallView : setList
                Pill {
                  shown: parent.list.contentY > parent.list.originY + 160
                  glyph: "󰁝"; text: root.now ? strings.t("deck.nowShort") : strings.t("deck.top")
                  onTapped: root.toTop()
                }
                Pill {
                  shown: parent.list.contentY < parent.list.originY + parent.list.contentHeight - parent.list.height - 160
                  glyph: "󰁅"; text: strings.t("deck.end")
                  onTapped: root.toEnd()
                }
              }
            }

            // ---- the minimap: the whole set at a glance, its energy, where you are
            Minimap {
              Layout.preferredWidth: 36
              Layout.fillHeight: true
            }
            }
          }
        }

        // ============================================== rooms
        // The laptop, then the rooms playing together inside one capsule
        // (joined by a line that carries the music), then every other room.
        // Drag a room into the capsule to add it, out of it to take it out.
        ColumnLayout {
          Layout.fillWidth: true
          spacing: 8
          RowLayout {
            Layout.fillWidth: true
            Label { text: strings.t("deck.playIn").toUpperCase(); font.pixelSize: Style.font.caption; font.letterSpacing: 2; opacity: 0.55 }
            Item { Layout.fillWidth: true }
            ActionButton {
              visible: root.inSonos && root.otherRooms.some(r => !r.busy)
              icon: "󰇧"
              text: strings.t("deck.everywhere")
              tone: root.teal
              onClicked: root.run(["deck", "everywhere"])
            }
          }
          Item {
            id: strip
            Layout.fillWidth: true
            implicitHeight: 96
            readonly property int count: 1 + root.partyRooms.length + root.otherRooms.length
            readonly property real tileWidth: Math.max(100, Math.min(176,
              (width - 8 * (count - 1) - (root.inSonos ? 20 + 14 * Math.max(0, root.partyRooms.length - 1) : 0)) / Math.max(1, count)))

            // Dropping a room anywhere outside the capsule takes it out.
            DropArea {
              anchors.fill: parent
              keys: ["deck-room"]
              onDropped: if (root.roomById(root.dragUid) && root.roomById(root.dragUid).here) root.run(["deck", "leave", root.dragUid])
            }

            RowLayout {
              anchors.left: parent.left
              anchors.bottom: parent.bottom
              spacing: 8

              RoomTile { Layout.alignment: Qt.AlignBottom; roomId: "laptop"; name: strings.t("deck.laptop"); laptop: true; here: !root.inSonos
                         volume: root.laptopOut ? root.laptopOut.volume : null }

              // ---- the capsule: every room the Deck plays in
              Rectangle {
                id: capsule
                visible: root.inSonos
                Layout.alignment: Qt.AlignBottom
                implicitWidth: Math.max(party.implicitWidth + 20, legend.implicitWidth + 44)
                implicitHeight: 96
                radius: Style.cornerRadius > 0 ? 10 : 0
                readonly property bool wanted: capsuleDrop.containsDrag && root.dragFrom === "room"
                color: capsuleDrop.containsDrag ? Util.alpha(root.teal, 0.08) : Util.alpha(root.amber, 0.04)
                border.width: wanted ? 2 : 1
                border.color: capsuleDrop.containsDrag ? root.teal : Util.alpha(root.amber, root.deck.playing ? 0.75 : 0.4)
                Behavior on implicitWidth { NumberAnimation { duration: Style.duration(240); easing.type: Easing.OutCubic } }
                Behavior on border.color { ColorAnimation { duration: Style.duration(160) } }

                // The legend, sitting on the border.
                Rectangle {
                  x: 14
                  y: -height / 2
                  width: legend.implicitWidth + 12
                  height: legend.implicitHeight
                  color: root.ground
                  Label {
                    id: legend
                    anchors.centerIn: parent
                    text: root.dragging && root.dragFrom === "room"
                      ? (root.roomById(root.dragUid) && root.roomById(root.dragUid).here ? strings.t("deck.dropToLeave") : strings.t("deck.dropToJoin"))
                      : (root.partyRooms.length > 1 ? "󰴸  " + strings.t("deck.together").arg(root.partyRooms.length) : "󰓃  " + strings.t("deck.dragIn"))
                    font.family: "Iosevka Nerd Font Propo"
                    font.pixelSize: Style.font.caption
                    font.letterSpacing: 1
                    color: capsuleDrop.containsDrag ? root.teal : root.amber
                  }
                }

                // The line between the rooms, and the light that runs along it.
                Item {
                  id: cable
                  visible: root.partyRooms.length > 1
                  x: 10 + strip.tileWidth / 2
                  width: Math.max(0, party.implicitWidth - strip.tileWidth)
                  y: party.y + 35
                  height: 2
                  Rectangle {
                    anchors.fill: parent
                    gradient: Gradient {
                      orientation: Gradient.Horizontal
                      GradientStop { position: 0; color: root.amber }
                      GradientStop { position: 1; color: root.teal }
                    }
                    opacity: 0.55
                  }
                  Rectangle {
                    id: spark
                    width: 36
                    height: 4
                    y: -1
                    radius: 2
                    visible: root.deck.playing && Style.duration(100) > 0
                    gradient: Gradient {
                      orientation: Gradient.Horizontal
                      GradientStop { position: 0; color: "transparent" }
                      GradientStop { position: 0.5; color: Qt.lighter(root.amber, 1.4) }
                      GradientStop { position: 1; color: "transparent" }
                    }
                    NumberAnimation on x {
                      running: spark.visible && cable.visible && root.seen
                      from: -spark.width; to: cable.width
                      duration: 900 + cable.width * 3
                      loops: Animation.Infinite
                    }
                  }
                }

                RowLayout {
                  id: party
                  x: 10
                  anchors.bottom: parent.bottom
                  anchors.bottomMargin: 8
                  spacing: 22
                  Repeater {
                    model: root.partyRooms
                    delegate: RoomTile {
                      required property var modelData
                      roomId: modelData.id; name: modelData.name; volume: modelData.volume
                      here: true; lead: modelData.lead
                    }
                  }
                }
                DropArea {
                  id: capsuleDrop
                  anchors.fill: parent
                  keys: ["deck-room", "deck-song"]
                  onDropped: {
                    if (root.dragFrom === "room") {
                      const r = root.roomById(root.dragUid)
                      if (r && !r.here) root.run(["deck", "join", r.id])
                    } else root.playDropped("")
                  }
                }
              }

              Repeater {
                model: root.otherRooms
                delegate: RoomTile {
                  required property var modelData
                  Layout.alignment: Qt.AlignBottom
                  roomId: modelData.id; name: modelData.name; volume: modelData.volume
                  busy: !!modelData.busy
                }
              }
            }
          }
        }
      }

      // ---- the stage: the playing song, big, for the room (P, or Stage)
      Rectangle {
        id: stageView
        anchors.fill: parent
        z: 40
        visible: opacity > 0
        opacity: root.stageOn ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: Style.duration(root.stageOn ? 220 : 140); easing.type: Easing.OutCubic } }
        color: root.ground
        TapHandler {}       // nothing underneath takes a tap while it's up
        HoverHandler { cursorShape: Qt.ArrowCursor }
        // A request popping in: the whole stage softens behind it.
        layer.enabled: root.stageOn && askPop.opacity > 0
        layer.effect: MultiEffect { blurEnabled: true; blur: askPop.opacity * 0.55; blurMax: 40 }

        readonly property var nextUp: (root.deck.set || []).slice(0, 3)
        readonly property string nowUid: root.deck.now ? root.deck.now.uid || "" : ""
        readonly property real big: Math.min(height * 0.5, width * 0.34)
        // The low end of the sound, 0-1: what the cover's glow breathes with.
        readonly property real bass: {
          const l = stageViz.levels || []
          if (!l.length || !root.deck.playing) return 0
          let sum = 0
          for (let i = 0; i < 6; i++) sum += l[i] || 0
          return Math.min(1, sum / 6 * 1.25)
        }
        // A dedication being read out: shown across the stage meanwhile.
        readonly property var speaking: root.deck.speaking || null
        property real clock: Date.now() / 1000
        readonly property bool moment: !!speaking && clock < speaking.until + 0.4
        Timer {
          running: stageView.visible && !!stageView.speaking
          interval: 50; repeat: true; triggeredOnStart: true
          onTriggered: stageView.clock = Date.now() / 1000
        }

        // The cover's colours, washed across the whole stage.
        Image { id: stageGlowSrc; anchors.fill: parent; source: glow.url; sourceSize: Qt.size(48, 48); fillMode: Image.PreserveAspectCrop; visible: false; asynchronous: true }
        MultiEffect {
          source: stageGlowSrc; anchors.fill: parent
          blurEnabled: true; blur: 1.0; blurMax: 64; saturation: 0.35
          opacity: glow.url !== "" ? 0.32 : 0
          Behavior on opacity { NumberAnimation { duration: Style.duration(900) } }
        }
        Rectangle {
          anchors.fill: parent
          gradient: Gradient {
            GradientStop { position: 0; color: Util.alpha(root.ground, 0.25) }
            GradientStop { position: 0.7; color: Util.alpha(root.ground, 0.7) }
            GradientStop { position: 1; color: root.ground }
          }
        }
        Rectangle {
          anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
          anchors.leftMargin: 10; anchors.rightMargin: 10; anchors.topMargin: 1
          height: 2
          gradient: Gradient {
            orientation: Gradient.Horizontal
            GradientStop { position: 0; color: "transparent" }
            GradientStop { position: 0.08; color: root.amber }
            GradientStop { position: 0.92; color: root.teal }
            GradientStop { position: 1; color: "transparent" }
          }
        }

        // Last call, while it runs: a small amber tag by the clock.
        Rectangle {
          readonly property real closes: root.deck.lastCall || 0
          visible: closes > 0 && stageClock.stamp < closes
          x: 36; y: 64
          height: 26; width: callTag.implicitWidth + 22; radius: 13
          color: Util.alpha(root.amber, 0.14)
          border.width: 1; border.color: root.amber
          Label {
            id: callTag
            anchors.centerIn: parent
            text: "󰄜  " + strings.t("deck.closesAt").arg(new Date(parent.closes * 1000).toLocaleTimeString(Qt.locale(Commons.I18n.formatLocale), Locale.ShortFormat)).toUpperCase()
            font.family: "Iosevka Nerd Font Propo"; font.pixelSize: Style.font.caption - 1; font.letterSpacing: 2; color: root.amber
          }
        }
        // The music stopped by itself, or the battery's low: a tag the room can see.
        Rectangle {
          visible: root.alertText !== ""
          x: 36; y: (root.deck.lastCall || 0) > 0 && stageClock.stamp < (root.deck.lastCall || 0) ? 100 : 64
          height: 26; width: alertTag.implicitWidth + 22; radius: 13
          color: Util.alpha(Commons.Color.warning, 0.14)
          border.width: 1; border.color: Commons.Color.warning
          Label {
            id: alertTag
            anchors.centerIn: parent
            text: (root.alertGlyph + "  " + root.alertText).toUpperCase()
            font.family: "Iosevka Nerd Font Propo"; font.pixelSize: Style.font.caption - 1; font.letterSpacing: 2
            color: Commons.Color.warning
          }
        }
        // The time, and the way out.
        Label {
          x: 36; y: 28
          text: stageClock.now
          font.pixelSize: 22; font.letterSpacing: 3; color: root.teal
          Timer { id: stageClock; property string now: ""; property real stamp: 0; interval: 10000; repeat: true; running: stageView.visible; triggeredOnStart: true
                  onTriggered: { now = new Date().toLocaleTimeString(Qt.locale(Commons.I18n.formatLocale), Locale.ShortFormat); stamp = Date.now() / 1000 } }
        }
        RowLayout {
          anchors.right: parent.right; anchors.top: parent.top; anchors.margins: 26
          spacing: 10
          Label { text: root.locked ? "󰌾" : ""; font.family: "Iosevka Nerd Font Propo"; color: root.amber; visible: root.locked }
          Label { text: strings.t("deck.stageLeave"); font.pixelSize: Style.font.caption; opacity: 0.4 }
          RoundButton { glyph: "󰅖"; tip: strings.t("deck.stageLeaveTip"); onClicked: root.stageOn = false }
        }

        // Tonight's top contributors: their faces, bobbing with the music.
        Row {
          z: 2
          anchors.horizontalCenter: parent.horizontalCenter
          y: 30   // clear of the top edge, glow and bounce included
          spacing: 18
          visible: root.people.length > 0
          Repeater {
            model: root.people.slice(0, 5)
            delegate: Column {
              id: fan
              required property var modelData
              required property int index
              spacing: 4
              readonly property bool leader: (modelData.played || 0) > 0 && modelData.played === (root.people[0].played || 0)
              // How much it bounces: the loudness of a slice of the sound.
              readonly property real beat: {
                const l = stageViz.levels || []
                if (!l.length || !root.deck.playing) return 0
                const at = Math.floor((index * 0.17 + 0.05) * l.length) % l.length
                return Math.min(1, (l[at] || 0) * 1.4)
              }
              Item {
                width: 64; height: 74
                // Whoever has had the most played tonight glows softly (ties share it).
                Rectangle {
                  visible: fan.leader
                  width: 64; height: 64; radius: 32
                  anchors.horizontalCenter: fanRing.horizontalCenter
                  y: fanRing.y
                  color: root.amber
                  opacity: 0.55 + fan.beat * 0.35
                  scale: 1.18 + fan.beat * 0.08
                  Behavior on opacity { NumberAnimation { duration: Style.duration(140); easing.type: Easing.OutCubic } }
                  Behavior on scale { NumberAnimation { duration: Style.duration(140); easing.type: Easing.OutCubic } }
                  layer.enabled: true
                  layer.effect: MultiEffect { blurEnabled: true; blur: 1.0; blurMax: 20; autoPaddingEnabled: true }
                }
                Rectangle {
                  id: fanRing
                  width: 64; height: 64; radius: 32
                  y: 8 - fan.beat * 9
                  Behavior on y { NumberAnimation { duration: Style.duration(90); easing.type: Easing.OutCubic } }
                  color: root.ground
                  border.width: fan.leader ? 3 : 2
                  border.color: fan.leader ? root.amber : root.teal
                  Image {
                    id: fanFace
                    anchors.fill: parent; anchors.margins: 3
                    source: (fan.modelData.photo || "") !== "" ? "file://" + fan.modelData.photo : ""
                    fillMode: Image.PreserveAspectCrop
                    asynchronous: true
                    layer.enabled: true
                    layer.effect: MultiEffect { maskEnabled: true; maskSource: fanMask }
                  }
                  Rectangle { id: fanMask; anchors.fill: fanFace; radius: width / 2; visible: false; layer.enabled: true }
                  Label { anchors.centerIn: parent; visible: fanFace.status !== Image.Ready; text: (fan.modelData.name || "?").charAt(0).toUpperCase(); font.bold: true; font.pixelSize: 24; color: root.teal }
                }
              }
            }
          }
        }

        // Requests while on stage: the newest few, to mix in, put next or turn down.
        Rectangle {
          id: stageAsks
          z: 2
          visible: root.requests.length > 0
          anchors.right: parent.right; anchors.top: parent.top
          anchors.topMargin: 84; anchors.rightMargin: 26
          width: 460
          height: stageAskCol.implicitHeight + 24
          radius: Style.cornerRadius > 0 ? 8 : 0
          color: Util.alpha(root.ground, 0.92)
          border.width: 1; border.color: Util.alpha(root.teal, 0.5)
          opacity: visible ? 1 : 0
          Behavior on opacity { NumberAnimation { duration: Style.duration(180) } }
          ColumnLayout {
            id: stageAskCol
            x: 14; y: 12
            width: parent.width - 28
            spacing: 8
            Label {
              text: "󰄜  " + strings.tn("deck.requestsCount", root.requests.length).arg(root.requests.length).toUpperCase()
              font.family: "Iosevka Nerd Font Propo"; font.pixelSize: Style.font.caption; font.letterSpacing: 2; color: root.teal
            }
            Repeater {
              model: root.requests.slice(-3).reverse()
              delegate: RequestRow {
                required property var modelData
                Layout.fillWidth: true
                coverSize: 56
                req: modelData
              }
            }
            Label {
              visible: root.requests.length > 3
              text: strings.t("deck.requestsMore").arg(root.requests.length - 3)
              font.pixelSize: Style.font.caption; opacity: 0.5
            }
          }
        }

        // The song: cover, then its name, big.
        Item {
          id: stageSong
          anchors.left: parent.left; anchors.right: parent.right
          anchors.leftMargin: 64; anchors.rightMargin: 64
          y: parent.height * 0.11
          height: stageView.big
          Rectangle {
            id: stageCoverShadow
            width: stageView.big; height: width
            radius: Math.round(stageView.big * 0.04)
            color: "transparent"
            layer.enabled: true
            // A soft glow all round, centred on the cover, breathing with the bass.
            layer.effect: MultiEffect {
              shadowEnabled: true; shadowBlur: 1.0; blurMax: 64
              shadowHorizontalOffset: 0; shadowVerticalOffset: 0
              shadowColor: Util.alpha(root.amber, 0.3 + stageView.bass * 0.45)
              shadowScale: 1.02 + stageView.bass * 0.03
              autoPaddingEnabled: true
            }
            CrossCover { anchors.fill: parent; size: stageView.big; radius: stageCoverShadow.radius; live: stageView.visible
                         url: root.now ? root.now.thumb || "" : root.setDone ? root.lastPlayed.thumb || "" : ""
                         opacity: root.now ? 1 : 0.55
                         Behavior on opacity { NumberAnimation { duration: Style.duration(400); easing.type: Easing.OutCubic } } }
          }
          // A guest's request playing: their face, big, on the cover's corner,
          // glowing a little and moving with the music.
          Item {
            id: spotlight
            z: 2
            readonly property bool on: !!root.now && (root.now.by || "") !== ""
            readonly property real size: Math.round(stageView.big * 0.36)
            readonly property real beat: {
              const l = stageViz.levels || []
              if (!l.length || !root.deck.playing) return 0
              let sum = 0
              const n = Math.max(1, Math.floor(l.length / 4))
              for (let i = 0; i < n; i++) sum += l[i] || 0
              return Math.min(1, sum / n * 1.3)
            }
            width: size; height: size
            // Overhangs the cover's bottom, but not into the words beside it.
            x: stageCoverShadow.width - size * 0.88
            y: stageCoverShadow.height - size * 0.62
            visible: on && opacity > 0
            opacity: 0
            property string uid: on ? root.now.uid : ""
            onUidChanged: {
              if (!uid) { opacity = 0; return }
              if (Style.reduceMotion || !stageView.visible) { opacity = 1; grow.scale = 1; return }
              spotIn.restart()
            }
            Component.onCompleted: if (on) { opacity = 1; grow.scale = 1 }
            ParallelAnimation {
              id: spotIn
              NumberAnimation { target: spotlight; property: "opacity"; from: 0; to: 1; duration: Style.duration(280); easing.type: Easing.OutCubic }
              NumberAnimation { target: grow; property: "scale"; from: 0.95; to: 1; duration: Style.duration(280); easing.type: Easing.Bezier; easing.bezierCurve: Style.easeOut }
            }
            Item {
              id: grow
              anchors.fill: parent
              scale: 1
              transform: Scale { origin.x: spotlight.size / 2; origin.y: spotlight.size / 2; xScale: 1 + spotlight.beat * 0.035; yScale: xScale }
              Rectangle {
                anchors.fill: parent
                radius: width / 2
                color: root.amber
                opacity: 0.35 + spotlight.beat * 0.3
                scale: 1.12
                Behavior on opacity { NumberAnimation { duration: Style.duration(140); easing.type: Easing.OutCubic } }
                layer.enabled: true
                layer.effect: MultiEffect { blurEnabled: true; blur: 1.0; blurMax: 32; autoPaddingEnabled: true }
              }
              Rectangle {
                anchors.fill: parent
                radius: width / 2
                color: root.ground
                border.width: 4; border.color: root.amber
                Image {
                  id: spotFace
                  anchors.fill: parent; anchors.margins: 6
                  source: root.now && (root.now.photo || "") !== "" ? "file://" + root.now.photo : ""
                  sourceSize.width: 384; sourceSize.height: 384
                  fillMode: Image.PreserveAspectCrop
                  asynchronous: true
                  layer.enabled: true
                  layer.effect: MultiEffect { maskEnabled: true; maskSource: spotMask }
                }
                Rectangle { id: spotMask; anchors.fill: spotFace; radius: width / 2; visible: false; layer.enabled: true }
                Label {
                  anchors.centerIn: parent
                  visible: spotFace.status !== Image.Ready
                  text: root.now ? (root.now.by || "?").charAt(0).toUpperCase() : ""
                  font.pixelSize: spotlight.size * 0.4; font.bold: true; color: root.amber
                }
              }
            }
          }
          ColumnLayout {
            id: stageWords
            anchors.left: stageCoverShadow.right; anchors.leftMargin: 56
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: 10
            // A new song arrives: its name slides in.
            property string uid: root.now ? root.now.uid : ""
            onUidChanged: if (stageView.visible && !Style.reduceMotion) arrive.restart()
            SequentialAnimation {
              id: arrive
              ParallelAnimation {
                NumberAnimation { target: stageWords; property: "opacity"; from: 0; to: 1; duration: Style.duration(260); easing.type: Easing.OutCubic }
                NumberAnimation { target: stageWords; property: "anchors.leftMargin"; from: 96; to: 56; duration: Style.duration(260); easing.type: Easing.OutCubic }
              }
            }
            Label { text: (root.setDone ? strings.t("deck.setDoneTag") : root.deck.playing ? strings.t("deck.nowPlaying") : strings.t("deck.paused")).toUpperCase(); font.pixelSize: Style.font.subtitle; font.letterSpacing: 6; color: root.teal }
            // The set ran out: say so, what played last, and how to carry on.
            ColumnLayout {
              visible: root.setDone
              spacing: 12
              Label {
                text: strings.t("deck.setDone")
                font.pixelSize: Math.max(34, Math.min(76, stageView.width / 20)); font.bold: true; color: root.amber
              }
              Label {
                Layout.maximumWidth: stageView.width * 0.45
                textFormat: Text.PlainText
                text: root.lastPlayed ? strings.t("deck.setDoneLast").arg(root.lastPlayed.title).arg(root.lastPlayed.artist) : ""
                font.pixelSize: Math.max(18, Math.min(28, stageView.width / 50)); opacity: 0.75
                elide: Text.ElideRight
              }
              RowLayout {
                Layout.topMargin: 14
                spacing: 12
                // Each finds songs from tonight (about a minute), then plays on.
                ActionButton { icon: "✦"; text: root.djBusy ? strings.t("deck.autodjWorking") : strings.t("deck.fill")
                               onClicked: if (!root.djBusy) { root.run(["deck", "fill"]); root.run(["deck", "play"]) } }
                ActionButton { icon: "∞"; text: strings.t("deck.autodj"); tone: root.deck.autodj ? root.amber : root.teal
                               onClicked: if (!root.djBusy) { root.run(["deck", "autodj", "on"]); root.run(["deck", "fill", "--auto"]); root.run(["deck", "play"]) } }
              }
            }
            // A guest's request playing: a shout-out, with their face.
            RowLayout {
              visible: !!root.now && (root.now.by || "") !== ""
              spacing: 14
              Rectangle {
                visible: !spotlight.visible        // the big face on the cover says it already
                width: 64; height: 64; radius: 32
                color: root.ground
                border.width: 3; border.color: root.teal
                Image {
                  id: shoutFace
                  anchors.fill: parent; anchors.margins: 3
                  source: root.now && (root.now.photo || "") !== "" ? "file://" + root.now.photo : ""
                  fillMode: Image.PreserveAspectCrop
                  asynchronous: true
                  layer.enabled: true
                  layer.effect: MultiEffect { maskEnabled: true; maskSource: shoutMask }
                }
                Rectangle { id: shoutMask; anchors.fill: shoutFace; radius: width / 2; visible: false; layer.enabled: true }
                Label { anchors.centerIn: parent; visible: shoutFace.status !== Image.Ready; text: root.now ? (root.now.by || "?").charAt(0).toUpperCase() : ""; font.pixelSize: 26; font.bold: true; color: root.teal }
              }
              ColumnLayout {
                spacing: 2
                Label { text: root.now ? strings.t("deck.requestedBy").arg(root.now.by || "") : ""; font.pixelSize: Math.max(18, Math.min(28, stageView.width / 50)); color: root.teal }
                Label {
                  visible: !!root.now && (root.now.note || "") !== ""
                  Layout.maximumWidth: stageView.width * 0.4
                  text: root.now ? "“" + (root.now.note || "") + "”" : ""
                  font.pixelSize: Math.max(16, Math.min(24, stageView.width / 60)); font.italic: true
                  wrapMode: Text.Wrap; maximumLineCount: 2; elide: Text.ElideRight
                }
              }
            }
            Label {
              Layout.fillWidth: true
              text: root.now ? root.titleParts(root.now.title).main : ""
              font.pixelSize: Math.max(34, Math.min(76, stageView.width / 20))
              font.bold: true
              color: root.amber
              wrapMode: Text.Wrap
              maximumLineCount: 2
              elide: Text.ElideRight
            }
            Label {
              Layout.fillWidth: true
              visible: text !== ""
              text: root.now ? root.titleParts(root.now.title).extra : ""
              font.pixelSize: Math.max(16, Math.min(26, stageView.width / 56))
              color: root.amber; opacity: 0.75
              elide: Text.ElideRight
            }
            Label {
              Layout.fillWidth: true
              text: root.now ? root.now.artist : ""
              font.pixelSize: Math.max(22, Math.min(40, stageView.width / 36))
              elide: Text.ElideRight
            }
            Item { implicitHeight: 14; visible: !!root.now }
            Rectangle {
              visible: !!root.now
              Layout.fillWidth: true
              height: 4; radius: 2
              color: Util.alpha(root.ink, 0.12)
              Rectangle {
                height: parent.height; radius: 2
                width: parent.width * Math.min(1, root.shownTime / Math.max(1, root.pos.length || root.lengthOf(root.now)))
                gradient: Gradient { orientation: Gradient.Horizontal; GradientStop { position: 0; color: root.amber } GradientStop { position: 1; color: root.teal } }
              }
            }
            RowLayout {
              visible: !!root.now
              Layout.fillWidth: true
              Label { text: root.clock(root.shownTime); font.pixelSize: Style.font.subtitle; opacity: 0.6 }
              Item { Layout.fillWidth: true }
              Label {
                visible: root.nowVotes.up + root.nowVotes.down > 0
                text: "👍 " + root.nowVotes.up + "   👎 " + root.nowVotes.down
                font.pixelSize: Style.font.subtitle
                Layout.rightMargin: 18
              }
              Label { text: "−" + root.clock(root.nowLeft); font.pixelSize: Style.font.subtitle; color: root.teal }
            }
          }
        }

        // The sound, across the bottom.
        DeckVisualizer {
          id: stageViz
          anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom
          anchors.leftMargin: 64; anchors.rightMargin: stageQr.visible ? stageQr.width + 96 : 64
          anchors.bottomMargin: 150
          height: Math.min(150, stageView.height * 0.16)
          active: stageView.visible && !!root.now
          playing: root.deck.playing
          live: !root.inSonos
          mic: root.deck.micViz === true
          amber: root.amber; teal: root.teal; ground: root.ground
        }

        // ---- A dedication being read: the stage hushes, and the guest's face
        // and words take it over, typed out as the voice says them.
        Rectangle {
          anchors.fill: parent
          z: 25
          color: root.ground
          opacity: stageView.moment ? 0.97 : 0
          visible: opacity > 0
          Behavior on opacity { NumberAnimation { duration: Style.duration(stageView.moment ? 360 : 260); easing.type: Easing.OutCubic } }
        }
        Item {
          id: dedication
          anchors.fill: parent
          z: 26
          visible: opacity > 0
          opacity: stageView.moment ? 1 : 0
          Behavior on opacity { NumberAnimation { duration: Style.duration(stageView.moment ? 420 : 240); easing.type: Easing.OutCubic } }
          readonly property var m: stageView.speaking || ({})
          readonly property bool isCall: m.kind === "call"
          readonly property real length: Math.max(1, (m.until || 0) - (m.start || 0))
          readonly property real since: stageView.clock - (m.start || 0)
          // The voice says who it's from first; the words type out while it reads them.
          readonly property real typed: Math.max(0, Math.min(1, (since - 1.7) / Math.max(1, length * 0.78 - 1.7)))
          readonly property string note: m.note || ""
          readonly property real face: Math.min(280, stageView.height * 0.3)
          property real lift: stageView.moment ? 0 : 28
          Behavior on lift { NumberAnimation { duration: Style.duration(520); easing.type: Easing.Bezier; easing.bezierCurve: Style.easeOut } }

          RowLayout {
            anchors.verticalCenter: parent.verticalCenter
            anchors.verticalCenterOffset: dedication.lift
            anchors.left: parent.left; anchors.right: parent.right
            anchors.leftMargin: Math.max(64, stageView.width * 0.09); anchors.rightMargin: Math.max(64, stageView.width * 0.09)
            spacing: Math.max(40, stageView.width * 0.04)

            // Last call: the code to scan, big, where a face would be.
            Rectangle {
              visible: dedication.isCall && !!root.guests && (root.guests.qr || "") !== ""
              Layout.preferredWidth: dedication.face; Layout.preferredHeight: dedication.face
              Layout.alignment: Qt.AlignVCenter
              radius: Style.cornerRadius > 0 ? 12 : 0
              color: "white"
              layer.enabled: true
              layer.effect: MultiEffect { shadowEnabled: true; shadowColor: Util.alpha(root.amber, 0.4 + stageView.bass * 0.3); shadowBlur: 1.0 }
              Image {
                anchors.fill: parent; anchors.margins: 14
                source: root.guests && root.guests.qr ? "file://" + root.guests.qr + "?" + root.guests.since : ""
                smooth: false; fillMode: Image.PreserveAspectFit; cache: false
              }
            }
            // The face, with sound rippling out from it.
            Item {
              visible: !dedication.isCall
              Layout.preferredWidth: dedication.face; Layout.preferredHeight: dedication.face
              Layout.alignment: Qt.AlignVCenter
              Repeater {
                model: 3
                delegate: Rectangle {
                  required property int index
                  anchors.centerIn: parent
                  width: dedication.face; height: width; radius: width / 2
                  color: "transparent"
                  border.width: 2; border.color: index % 2 ? root.teal : root.amber
                  opacity: 0
                  SequentialAnimation on scale {
                    running: dedication.visible && !Style.reduceMotion
                    loops: Animation.Infinite
                    PauseAnimation { duration: index * 600 }
                    NumberAnimation { from: 1.0; to: 1.55; duration: 1800; easing.type: Easing.OutCubic }
                  }
                  SequentialAnimation on opacity {
                    running: dedication.visible && !Style.reduceMotion
                    loops: Animation.Infinite
                    PauseAnimation { duration: index * 600 }
                    NumberAnimation { from: 0.55; to: 0; duration: 1800; easing.type: Easing.OutCubic }
                  }
                }
              }
              Rectangle {
                anchors.fill: parent
                radius: width / 2
                color: root.amber
                opacity: 0.3 + stageView.bass * 0.35
                scale: 1.1 + stageView.bass * 0.06
                layer.enabled: true
                layer.effect: MultiEffect { blurEnabled: true; blur: 1.0; blurMax: 48; autoPaddingEnabled: true }
              }
              Rectangle {
                anchors.fill: parent
                radius: width / 2
                color: root.ground
                border.width: 5; border.color: root.amber
                Image {
                  id: dedFace
                  anchors.fill: parent; anchors.margins: 8
                  source: (dedication.m.photo || "") !== "" ? "file://" + dedication.m.photo : ""
                  sourceSize.width: 512; sourceSize.height: 512
                  fillMode: Image.PreserveAspectCrop
                  asynchronous: true
                  layer.enabled: true
                  layer.effect: MultiEffect { maskEnabled: true; maskSource: dedMask }
                }
                Rectangle { id: dedMask; anchors.fill: dedFace; radius: width / 2; visible: false; layer.enabled: true }
                Label {
                  anchors.centerIn: parent
                  visible: dedFace.status !== Image.Ready
                  text: (dedication.m.by || "?").charAt(0).toUpperCase()
                  font.pixelSize: dedication.face * 0.42; font.bold: true; color: root.amber
                }
              }
            }

            ColumnLayout {
              Layout.fillWidth: true
              Layout.alignment: Qt.AlignVCenter
              spacing: 16
              Label {
                text: dedication.isCall ? "󰄜  " + strings.t("deck.lastCallTitle").toUpperCase()
                                        : "󰎈  " + strings.t("deck.dedication").toUpperCase()
                font.family: "Iosevka Nerd Font Propo"
                font.pixelSize: Math.max(14, Math.min(20, stageView.width / 90)); font.letterSpacing: 8
                color: root.teal
              }
              // A line that draws itself, accent to cyan.
              Rectangle {
                Layout.preferredHeight: 2
                Layout.preferredWidth: parent.width * (stageView.moment ? 1 : 0)
                Behavior on Layout.preferredWidth { NumberAnimation { duration: Style.duration(900); easing.type: Easing.OutCubic } }
                gradient: Gradient { orientation: Gradient.Horizontal; GradientStop { position: 0; color: root.amber } GradientStop { position: 1; color: Util.alpha(root.teal, 0) } }
              }
              Label {
                Layout.fillWidth: true
                visible: dedication.note !== ""
                readonly property string words: dedication.isCall ? (dedication.m.title || "") : dedication.note
                readonly property real shown: dedication.isCall ? Math.min(1, dedication.since / 1.4) : dedication.typed
                text: (dedication.isCall ? "" : "“") + words.substring(0, Math.round(words.length * shown))
                      + (shown < 1 ? "▍" : (dedication.isCall ? "" : "”"))
                font.pixelSize: Math.max(30, Math.min(68, stageView.width / 21))
                font.italic: true
                lineHeight: 1.08
                color: root.ink
                wrapMode: Text.Wrap
                maximumLineCount: 3
                elide: Text.ElideRight
              }
              RowLayout {
                spacing: 14
                Label {
                  visible: dedication.isCall
                  text: strings.t("deck.lastCallScan")
                  font.pixelSize: Math.max(18, Math.min(28, stageView.width / 52))
                  color: root.teal
                }
                Label {
                  visible: !dedication.isCall
                  text: "— " + (dedication.m.by || "")
                  font.pixelSize: Math.max(22, Math.min(36, stageView.width / 44)); font.bold: true
                  color: root.amber
                }
                Label {
                  visible: !dedication.isCall
                  Layout.fillWidth: true
                  text: dedication.m.title ? strings.t("deck.dedicationFor").arg(root.titleParts(dedication.m.title).main) : ""
                  font.pixelSize: Math.max(16, Math.min(24, stageView.width / 64))
                  color: root.teal
                  elide: Text.ElideRight
                }
              }
            }
          }
          // How long the voice has left: a hairline across the bottom.
          Rectangle {
            anchors.left: parent.left; anchors.bottom: parent.bottom
            height: 3
            width: parent.width * Math.min(1, dedication.since / dedication.length)
            gradient: Gradient { orientation: Gradient.Horizontal; GradientStop { position: 0; color: root.amber } GradientStop { position: 1; color: root.teal } }
          }
        }

        // ---- The night's recap: when requests close (or Recap is pressed).
        // Tonight's covers drift behind; the numbers count up; the most loved
        // song, the crowd's top DJs, and the code to save tonight's songs.
        Item {
          id: recap
          anchors.fill: parent
          z: 27
          readonly property var r: root.deck.recap || null
          readonly property bool on: !!r && !stageView.moment
          visible: opacity > 0
          opacity: on ? 1 : 0
          Behavior on opacity { NumberAnimation { duration: Style.duration(recap.on ? 600 : 260); easing.type: Easing.OutCubic } }
          property real shown: 0          // 0 → 1 as it comes in: the numbers count up with it
          onOnChanged: if (on) { shown = 0; countUp.restart() }
          NumberAnimation { id: countUp; target: recap; property: "shown"; from: 0; to: 1; duration: Style.duration(1800); easing.type: Easing.OutCubic }
          TapHandler { onTapped: root.run(["deck", "recap", "off"]) }

          Rectangle { anchors.fill: parent; color: root.ground }
          // Tonight's covers, a slow drifting wall.
          Item {
            anchors.fill: parent
            clip: true
            opacity: 0.22
            readonly property int cell: Math.ceil(stageView.width / 9)
            readonly property var covers: (recap.r && recap.r.covers) || []
            Grid {
              id: wall
              columns: 9
              readonly property int rows: Math.ceil(stageView.height / parent.cell) + 1
              Repeater {
                model: parent.parent.covers.length ? 9 * wall.rows * 2 : 0
                delegate: Image {
                  required property int index
                  width: wall.parent.cell; height: width
                  source: wall.parent.covers[(index * 7 + Math.floor(index / 9)) % wall.parent.covers.length]
                  sourceSize.width: 200; sourceSize.height: 200
                  fillMode: Image.PreserveAspectCrop
                  asynchronous: true
                }
              }
              NumberAnimation on y {
                running: recap.visible && !Style.reduceMotion
                from: 0; to: -wall.rows * wall.parent.cell
                duration: 120000; loops: Animation.Infinite
              }
            }
            layer.enabled: true
            layer.effect: MultiEffect { blurEnabled: true; blur: 0.5; blurMax: 24; saturation: 0.2 }
          }
          Rectangle {
            anchors.fill: parent
            gradient: Gradient {
              GradientStop { position: 0; color: Util.alpha(root.ground, 0.55) }
              GradientStop { position: 0.5; color: Util.alpha(root.ground, 0.8) }
              GradientStop { position: 1; color: root.ground }
            }
          }
          Rectangle {
            anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
            anchors.leftMargin: 10; anchors.rightMargin: 10; anchors.topMargin: 1
            height: 2
            gradient: Gradient {
              orientation: Gradient.Horizontal
              GradientStop { position: 0; color: "transparent" }
              GradientStop { position: 0.08; color: root.amber }
              GradientStop { position: 0.92; color: root.teal }
              GradientStop { position: 1; color: "transparent" }
            }
          }

          ColumnLayout {
            anchors.centerIn: parent
            width: Math.min(parent.width - 128, 1400)
            spacing: 0
            opacity: recap.shown > 0 ? 1 : 0
            transform: Translate { y: (1 - Math.min(1, recap.shown * 3)) * 24 }

            Label {
              text: strings.t("deck.recapKicker").toUpperCase()
              font.pixelSize: Style.font.caption + 2; font.letterSpacing: 10; color: root.teal
            }
            Label {
              Layout.topMargin: 8
              text: strings.t("deck.recapTitle")
              font.pixelSize: Math.min(96, stageView.height * 0.1); font.bold: true; color: root.amber
              layer.enabled: true
              layer.effect: MultiEffect { shadowEnabled: true; shadowColor: Util.alpha(root.amber, 0.35 + stageView.bass * 0.3); shadowBlur: 1.0; shadowVerticalOffset: 0 }
            }
            // The numbers, counting up.
            RowLayout {
              Layout.topMargin: 36
              spacing: Math.max(48, stageView.width * 0.05)
              Repeater {
                model: recap.r ? [
                  { n: recap.r.songs, label: strings.t("deck.recapSongs") },
                  { n: recap.r.minutes >= 60 ? recap.r.minutes / 60 : recap.r.minutes, hours: recap.r.minutes >= 60,
                    label: recap.r.minutes >= 60 ? strings.t("deck.recapHours") : strings.t("deck.recapMinutes") },
                  { n: recap.r.requests, label: strings.t("deck.recapRequests") },
                  { n: recap.r.dedications, label: strings.t("deck.recapDedications") }
                ].filter(x => x.n > 0) : []
                delegate: ColumnLayout {
                  required property var modelData
                  spacing: 4
                  Label {
                    text: modelData.hours ? Commons.I18n.formatNumber(modelData.n * recap.shown, 1)
                                          : Commons.I18n.formatNumber(Math.round(modelData.n * recap.shown))
                    font.pixelSize: Math.min(84, stageView.height * 0.085); font.bold: true; color: root.ink
                  }
                  Label { text: modelData.label.toUpperCase(); font.pixelSize: Style.font.caption; font.letterSpacing: 4; color: root.teal }
                }
              }
            }
            Rectangle {
              Layout.topMargin: 40; Layout.fillWidth: true
              height: 2
              gradient: Gradient { orientation: Gradient.Horizontal
                GradientStop { position: 0; color: root.amber }
                GradientStop { position: Math.max(0.01, recap.shown); color: root.teal }
                GradientStop { position: Math.min(1, recap.shown + 0.01); color: "transparent" } }
            }
            RowLayout {
              Layout.topMargin: 40; Layout.fillWidth: true
              spacing: Math.max(48, stageView.width * 0.04)
              // The most loved song.
              ColumnLayout {
                visible: !!(recap.r && recap.r.loved)
                spacing: 12
                Label { text: strings.t("deck.recapLoved").toUpperCase(); font.pixelSize: Style.font.caption; font.letterSpacing: 4; color: root.teal }
                RowLayout {
                  spacing: 18
                  Cover {
                    size: Math.min(140, stageView.height * 0.14)
                    url: recap.r && recap.r.loved ? recap.r.loved.thumb || "" : ""
                    layer.enabled: true
                    layer.effect: MultiEffect { shadowEnabled: true; shadowColor: Util.alpha(root.amber, 0.45); shadowBlur: 1.0; shadowVerticalOffset: 0 }
                  }
                  ColumnLayout {
                    spacing: 4
                    Layout.maximumWidth: stageView.width * 0.24
                    Label { Layout.fillWidth: true; text: recap.r && recap.r.loved ? root.titleParts(recap.r.loved.title).main : ""; font.pixelSize: 28; font.bold: true; color: root.amber; elide: Text.ElideRight }
                    Label { Layout.fillWidth: true; text: recap.r && recap.r.loved ? recap.r.loved.artist : ""; font.pixelSize: Style.font.body + 2; opacity: 0.75; elide: Text.ElideRight }
                    Label { text: recap.r && recap.r.loved ? "👍 " + recap.r.loved.up : ""; font.pixelSize: Style.font.body + 2; color: root.teal }
                  }
                }
              }
              // The crowd's DJs: whose songs got played most (the top one glows).
              ColumnLayout {
                visible: !!(recap.r && recap.r.top.length)
                spacing: 12
                Label { text: strings.t("deck.recapCrowd").toUpperCase(); font.pixelSize: Style.font.caption; font.letterSpacing: 4; color: root.teal }
                Row {
                  spacing: 18
                  Repeater {
                    model: recap.r ? recap.r.top : []
                    delegate: Item {
                      id: dj
                      required property var modelData
                      required property int index
                      readonly property real size: index === 0 ? 112 : 88
                      width: size; height: 112
                      Rectangle {
                        visible: dj.index === 0
                        anchors.centerIn: djFace
                        width: djFace.width; height: width; radius: width / 2
                        color: root.amber
                        opacity: 0.4 + stageView.bass * 0.3
                        scale: 1.12
                        layer.enabled: true
                        layer.effect: MultiEffect { blurEnabled: true; blur: 1.0; blurMax: 32; autoPaddingEnabled: true }
                      }
                      Rectangle {
                        id: djFace
                        anchors.bottom: parent.bottom
                        width: dj.size; height: width; radius: width / 2
                        color: root.ground
                        border.width: dj.index === 0 ? 4 : 2; border.color: dj.index === 0 ? root.amber : Util.alpha(root.teal, 0.7)
                        Image {
                          id: djImg
                          anchors.fill: parent; anchors.margins: dj.index === 0 ? 6 : 4
                          source: (dj.modelData.photo || "") !== "" ? "file://" + dj.modelData.photo : ""
                          sourceSize.width: 256; sourceSize.height: 256
                          fillMode: Image.PreserveAspectCrop
                          asynchronous: true
                          layer.enabled: true
                          layer.effect: MultiEffect { maskEnabled: true; maskSource: djMask }
                        }
                        Rectangle { id: djMask; anchors.fill: djImg; radius: width / 2; visible: false; layer.enabled: true }
                        Label { anchors.centerIn: parent; visible: djImg.status !== Image.Ready; text: (dj.modelData.name || "?").charAt(0).toUpperCase(); font.pixelSize: dj.size * 0.4; font.bold: true; color: root.amber }
                      }
                    }
                  }
                }
              }
              Item { Layout.fillWidth: true }
              // Save tonight's songs: the requests page has them, with links.
              ColumnLayout {
                visible: root.showQr
                spacing: 10
                Rectangle {
                  Layout.alignment: Qt.AlignHCenter
                  Layout.preferredWidth: Math.min(170, stageView.height * 0.17); Layout.preferredHeight: Layout.preferredWidth
                  radius: Style.cornerRadius > 0 ? 10 : 0
                  color: "white"
                  Image {
                    anchors.fill: parent; anchors.margins: 10
                    source: root.guests && root.guests.qr ? "file://" + root.guests.qr + "?" + root.guests.since : ""
                    smooth: false; fillMode: Image.PreserveAspectFit; cache: false
                  }
                }
                Label { Layout.alignment: Qt.AlignHCenter; text: strings.t("deck.recapSave"); font.pixelSize: Style.font.caption; color: root.teal }
              }
            }
            // Keep tonight: a new playlist in your Apple Music, only when you press it.
            Rectangle {
              id: keepNight
              Layout.alignment: Qt.AlignHCenter
              Layout.topMargin: 18
              property bool sent: false
              implicitWidth: keepRow.implicitWidth + 32
              implicitHeight: 38
              radius: 19
              color: Util.alpha(root.amber, keepHover.hovered ? 0.24 : 0.12)
              border.width: 1; border.color: Util.alpha(root.amber, 0.8)
              opacity: sent ? 0.6 : 1
              Row {
                id: keepRow
                anchors.centerIn: parent
                spacing: 8
                Label { text: "󰆓"; font.family: "Iosevka Nerd Font Propo"; color: root.amber }
                Label { text: strings.t(keepNight.sent ? "deck.recapKeeping" : "deck.recapKeep").toUpperCase(); font.pixelSize: Style.font.caption; font.letterSpacing: 2; color: root.amber }
              }
              HoverHandler { id: keepHover; cursorShape: Qt.PointingHandCursor }
              TapHandler {
                gesturePolicy: TapHandler.WithinBounds
                onTapped: {
                  if (keepNight.sent) return
                  keepNight.sent = true
                  const d = new Date()
                  root.run(["deck", "export", "applemusic", strings.t("deck.recapKeepName").arg(d.toLocaleDateString(Qt.locale(Commons.I18n.formatLocale), Locale.ShortFormat)), "--tonight"])
                }
              }
              Connections { target: recap; function onOnChanged() { keepNight.sent = false } }
            }
          }
          Label {
            anchors.horizontalCenter: parent.horizontalCenter; anchors.bottom: parent.bottom; anchors.bottomMargin: 28
            text: strings.t("deck.recapClose"); font.pixelSize: Style.font.caption; opacity: 0.4
          }
        }

        // ---- A request just in: the stage dims behind it, and the guest's face
        // and song slide up under the song's name.
        Rectangle {
          anchors.fill: parent
          z: 23
          color: root.ground
          opacity: askPop.opacity * 0.72
          visible: opacity > 0
        }
        // Up next: the next three, and when each starts.
        RowLayout {
          anchors.left: parent.left; anchors.bottom: parent.bottom
          anchors.leftMargin: 64; anchors.bottomMargin: 40
          anchors.right: stageQr.visible ? stageQr.left : parent.right; anchors.rightMargin: 32
          spacing: 28
          visible: stageView.nextUp.length > 0
          ColumnLayout {
            Layout.alignment: Qt.AlignVCenter
            spacing: 4
            // The last half minute: a countdown to the next song.
            Label {
              readonly property bool counting: root.deck.playing && root.songLeft >= 0 && root.songLeft <= 30
              text: counting ? strings.t("deck.nextIn").arg(Math.floor(root.songLeft / 60) + ":" + String(Math.floor(root.songLeft % 60)).padStart(2, "0")).toUpperCase()
                             : strings.t("deck.upNext").toUpperCase()
              font.pixelSize: Style.font.caption; font.letterSpacing: 4
              color: counting ? root.amber : root.teal
            }
            // Where Auto-DJ is taking the night.
            Label {
              visible: root.towardLabel !== ""
              text: "∞  " + root.towardLabel
              font.pixelSize: Style.font.caption - 1; font.letterSpacing: 1
              color: root.teal; opacity: 0.75
            }
          }
          Repeater {
            model: stageView.nextUp
            delegate: RowLayout {
              id: coming
              required property var modelData
              required property int index
              spacing: 12
              Layout.maximumWidth: 320
              // The song changed: the line moves along, one after another.
              transform: Translate { id: comeShift }
              Connections { target: stageView; function onNowUidChanged() { if (stageView.visible) comeIn.restart() } }
              SequentialAnimation {
                id: comeIn
                PropertyAction { target: coming; property: "opacity"; value: 0 }
                PropertyAction { target: comeShift; property: "x"; value: 48 }
                PauseAnimation { duration: Style.duration(220 + coming.index * 110) }
                ParallelAnimation {
                  NumberAnimation { target: comeShift; property: "x"; to: 0; duration: Style.duration(520); easing.type: Easing.OutCubic }
                  NumberAnimation { target: coming; property: "opacity"; to: 1; duration: Style.duration(400); easing.type: Easing.OutCubic }
                }
              }
              Cover { url: coming.modelData.thumb || ""; size: 64 }
              ColumnLayout {
                spacing: 2
                Layout.fillWidth: true
                Label { Layout.fillWidth: true; text: root.titleParts(coming.modelData.title).main; font.bold: true; elide: Text.ElideRight }
                Label { Layout.fillWidth: true; text: coming.modelData.artist; opacity: 0.6; font.pixelSize: Style.font.caption; elide: Text.ElideRight }
                Label { text: root.clockAt(root.startsAt[coming.index] || 0); color: root.teal; font.pixelSize: Style.font.caption }
              }
            }
          }
          Item { Layout.fillWidth: true }
        }

        // Guests: scan to ask for a song.
        Column {
          id: stageQr
          visible: !!root.guests && (root.guests.qr || "") !== ""
          anchors.right: parent.right; anchors.bottom: parent.bottom; anchors.margins: 40
          spacing: 8
          Rectangle {
            width: 150; height: 150
            radius: Style.cornerRadius > 0 ? 6 : 0
            color: "white"
            Image {
              anchors.fill: parent; anchors.margins: 6
              source: root.guests && root.guests.qr ? "file://" + root.guests.qr + "?" + root.guests.since : ""
              smooth: false; cache: false
              fillMode: Image.PreserveAspectFit
            }
          }
          TapHandler { onTapped: root.qrBig = true }
          Label { width: 150; horizontalAlignment: Text.AlignHCenter; text: strings.t("deck.stageScan"); font.pixelSize: Style.font.caption; color: root.teal; wrapMode: Text.Wrap }
        }
      }

      // ---- A request just in: shown over the stage, which blurs and dims behind it.
      Item {
        id: askPop
        // Over the stage (outside it, so the stage can blur behind it), in line
        // with the song's name, in the space under its progress.
        z: 41
        x: 64 + stageView.big + 56
        y: stageViz.y - 24 - height
        width: Math.min(560, stageView.width - (64 + stageView.big + 56) - 64); height: 96
        opacity: 0
        visible: opacity > 0 && root.stageOn
        property var queue: []
        property var item: ({})
        property real seenAt: Date.now() / 1000
        property real rise: 24
        transform: Translate { y: askPop.rise }
        function check() {
          const asks = root.deck.asks || []
          const fresh = asks.filter(a => (a.at || 0) > seenAt)
          if (!fresh.length) return
          seenAt = Math.max(...fresh.map(a => a.at || 0))
          queue = queue.concat(fresh)
          if (!showing.running) next()
        }
        function next() {
          if (!queue.length) return
          item = queue[0]; queue = queue.slice(1)
          showing.restart()
        }
        Connections { target: root; function onDeckChanged() { askPop.check() } }
        SequentialAnimation {
          id: showing
          ParallelAnimation {
            NumberAnimation { target: askPop; property: "opacity"; from: 0; to: 1; duration: Style.duration(360); easing.type: Easing.OutCubic }
            NumberAnimation { target: askPop; property: "rise"; from: 24; to: 0; duration: Style.duration(420); easing.type: Easing.Bezier; easing.bezierCurve: Style.easeOut }
          }
          PauseAnimation { duration: 6500 }
          ParallelAnimation {
            NumberAnimation { target: askPop; property: "opacity"; to: 0; duration: Style.duration(240); easing.type: Easing.OutCubic }
            NumberAnimation { target: askPop; property: "rise"; to: -10; duration: Style.duration(240); easing.type: Easing.OutCubic }
          }
          ScriptAction { script: askPop.next() }
        }
        Rectangle {
          anchors.fill: parent
          radius: Style.cornerRadius > 0 ? 10 : 0
          color: Util.alpha(root.ground, 0.9)
          border.width: 1; border.color: Util.alpha(root.amber, 0.45)
          layer.enabled: true
          layer.effect: MultiEffect { shadowEnabled: true; shadowColor: Util.alpha(root.amber, 0.35); shadowBlur: 1.0; shadowVerticalOffset: 6 }
          RowLayout {
            anchors.fill: parent; anchors.leftMargin: 16; anchors.rightMargin: 16
            spacing: 16
            Item {
              Layout.preferredWidth: 72; Layout.preferredHeight: 72
              Cover { anchors.fill: parent; size: 72; url: askPop.item.thumb || "" }
              Rectangle {
                width: 38; height: 38; radius: 19
                x: parent.width - 26; y: parent.height - 26
                color: root.ground
                border.width: 2; border.color: root.amber
                Image {
                  id: popFace
                  anchors.fill: parent; anchors.margins: 2
                  source: (askPop.item.photo || "") !== "" ? "file://" + askPop.item.photo : ""
                  fillMode: Image.PreserveAspectCrop
                  asynchronous: true
                  layer.enabled: true
                  layer.effect: MultiEffect { maskEnabled: true; maskSource: popMask }
                }
                Rectangle { id: popMask; anchors.fill: popFace; radius: width / 2; visible: false; layer.enabled: true }
                Label { anchors.centerIn: parent; visible: popFace.status !== Image.Ready; text: (askPop.item.by || "?").charAt(0).toUpperCase(); font.bold: true; color: root.amber }
              }
            }
            ColumnLayout {
              Layout.fillWidth: true
              spacing: 2
              Label {
                text: strings.t("deck.newRequest").toUpperCase() + ((askPop.item.note || "") !== "" ? "  ·  ✦ " + strings.t("deck.withDedication").toUpperCase() : "")
                font.family: "Iosevka Nerd Font Propo"; font.pixelSize: Style.font.caption - 1; font.letterSpacing: 3; color: root.teal
              }
              Label { Layout.fillWidth: true; text: strings.t("deck.askedFor").arg(askPop.item.by || strings.t("deck.aGuest")); font.pixelSize: Style.font.body; opacity: 0.8; elide: Text.ElideRight }
              Label { Layout.fillWidth: true; text: root.titleParts(askPop.item.title || "").main; font.pixelSize: 20; font.bold: true; color: root.amber; elide: Text.ElideRight }
              Label { Layout.fillWidth: true; text: askPop.item.artist || ""; font.pixelSize: Style.font.caption; opacity: 0.65; elide: Text.ElideRight }
            }
          }
        }
      }

      // ---- guests: the QR code for the requests page, and how requests go in
      Rectangle {
        id: guestsCard
        visible: root.guestsOpen
        z: 50
        anchors.top: parent.top; anchors.right: parent.right
        anchors.topMargin: 78; anchors.rightMargin: 22
        width: 340
        height: guestCol.implicitHeight + 28
        radius: Style.cornerRadius > 0 ? 8 : 0
        color: Util.alpha(root.ground, 0.97)
        border.width: 1
        border.color: Util.alpha(root.teal, 0.5)
        TapHandler {}       // keep taps inside the card
        ColumnLayout {
          id: guestCol
          x: 14; y: 14
          width: parent.width - 28
          spacing: 10
          RowLayout {
            Layout.fillWidth: true
            Label { Layout.fillWidth: true; text: strings.t("deck.guestsTitle").toUpperCase(); font.pixelSize: Style.font.caption; font.letterSpacing: 2; color: root.teal }
            Label {
              visible: root.locked
              text: "󰌾  " + strings.t("deck.guestsLocked")
              font.family: "Iosevka Nerd Font Propo"; font.pixelSize: Style.font.caption - 1; color: root.amber; opacity: 0.8
            }
          }
          Label {
            Layout.fillWidth: true
            wrapMode: Text.Wrap
            text: root.guests ? strings.t("deck.guestsOnHint") : strings.t("deck.guestsOffHint")
            font.pixelSize: Style.font.caption; opacity: 0.7
          }
          Rectangle {
            visible: !!root.guests && (root.guests.qr || "") !== ""
            Layout.alignment: Qt.AlignHCenter
            width: 200; height: 200
            radius: Style.cornerRadius > 0 ? 6 : 0
            color: "white"
            Image {
              anchors.fill: parent; anchors.margins: 8
              source: root.guests && root.guests.qr ? "file://" + root.guests.qr + "?" + root.guests.since : ""
              smooth: false
              fillMode: Image.PreserveAspectFit
              cache: false
            }
          }
          Label {
            visible: !!root.guests
            Layout.fillWidth: true
            horizontalAlignment: Text.AlignHCenter
            text: root.guests ? root.guests.url.replace(/\/[^\/]*$/, "/…") : ""
            font.pixelSize: Style.font.caption; opacity: 0.5
          }
          ActionButton {
            Layout.alignment: Qt.AlignHCenter
            visible: !root.locked || !root.guests
            icon: root.guests ? "󰅖" : "󰐲"
            text: root.guests ? strings.t("deck.guestsStop") : strings.t("deck.guestsStart")
            tone: root.guests ? root.teal : root.amber
            onClicked: root.run(["deck", "guests", root.guests ? "off" : "on"])
          }
          // Before the party: check everything's in place. And the night's recap.
          RowLayout {
            Layout.fillWidth: true
            spacing: 8
            HeadLink {
              glyph: "󰄬"
              text: root.readyAsked && !root.readyFresh ? strings.t("deck.readyChecking") : strings.t("deck.readyCheck")
              // Tap to check; tap again (while the results show) to put them away.
              onTapped: {
                if (root.readyAsked && root.readyFresh) { root.readyAsked = false; return }
                root.readyAsked = true; root.readyAskedAt = Date.now() / 1000; root.run(["deck", "ready"])
              }
            }
            // The results go away by themselves after a while.
            Timer { running: root.readyAsked && root.readyFresh; interval: 20000; onTriggered: root.readyAsked = false }
            Item { Layout.fillWidth: true }
            HeadLink { glyph: "󰄨"; text: strings.t("deck.recapShow"); onTapped: root.run(["deck", "recap"]) }
          }
          Column {
            visible: root.readyAsked && root.readyFresh
            Layout.fillWidth: true
            spacing: 6
            Repeater {
              model: root.readyAsked && root.deck.ready ? root.deck.ready.items : []
              delegate: RowLayout {
                required property var modelData
                width: parent.width
                spacing: 8
                Label {
                  Layout.alignment: Qt.AlignTop
                  text: modelData.ok === true ? "󰄬" : modelData.ok === false ? "󰀦" : "󰋼"
                  font.family: "Iosevka Nerd Font Propo"; font.pixelSize: Style.font.caption
                  color: modelData.ok === true ? root.teal : modelData.ok === false ? root.amber : root.ink
                  opacity: modelData.ok === null ? 0.55 : 1
                }
                Label {
                  Layout.fillWidth: true
                  wrapMode: Text.Wrap
                  textFormat: Text.PlainText
                  text: modelData.text
                  font.pixelSize: Style.font.caption
                  opacity: modelData.ok === null ? 0.6 : 0.9
                }
              }
            }
          }
          // How requests go in: switches, each saying what it does.
          OptionTile {
            Layout.fillWidth: true; Layout.topMargin: 4
            wrap: true
            amber: root.amber; teal: root.teal
            icon: "󰒺"
            title: strings.t("deck.requestsAuto")
            detail: root.deck.requestsAuto ? strings.t("deck.requestsAutoOn") : strings.t("deck.requestsAutoOff")
            checked: !!root.deck.requestsAuto
            onToggled: if (!root.locked) root.run(["deck", "requests", "auto", root.deck.requestsAuto ? "off" : "on"])
          }
          OptionTile {
            visible: !!root.deck.voiceReady
            Layout.fillWidth: true
            wrap: true
            amber: root.amber; teal: root.teal
            icon: "󰔊"
            title: strings.t("deck.voice")
            detail: (root.deck.voice !== false ? strings.t("deck.voiceOn") : strings.t("deck.voiceOff")) + " " + strings.t("deck.voiceFriendly")
            checked: root.deck.voice !== false
            onToggled: if (!root.locked) root.run(["deck", "voice", root.deck.voice !== false ? "off" : "on"])
          }
          // Which voice reads them: step through with ‹ ›, each says hello.
          RowLayout {
            id: voiceRow
            visible: !!root.deck.voiceReady && root.deck.voice !== false && (root.deck.voices || []).length > 1
            Layout.fillWidth: true
            Layout.leftMargin: 4; Layout.rightMargin: 4
            spacing: 8
            readonly property var list: root.deck.voices || []
            readonly property int at: Math.max(0, list.findIndex(x => x.key === root.deck.voiceName))
            readonly property var v: list[at] || null
            function step(by) {
              if (!list.length || root.locked) return
              root.run(["deck", "voice", "use", list[(at + by + list.length) % list.length].key])
            }
            Label { text: strings.t("deck.voiceLabel").toUpperCase(); font.pixelSize: Style.font.caption; font.letterSpacing: 2; color: root.teal }
            HeadLink { visible: !root.locked; glyph: "󰅁"; onTapped: voiceRow.step(-1) }
            Label {
              Layout.fillWidth: true
              horizontalAlignment: Text.AlignHCenter
              elide: Text.ElideRight
              text: voiceRow.v ? (voiceRow.at === 0 ? "★ " : "") + voiceRow.v.name + "  ·  " + voiceRow.v.about : ""
              font.pixelSize: Style.font.caption
              color: root.amber
            }
            HeadLink { visible: !root.locked; glyph: "󰅂"; onTapped: voiceRow.step(1) }
          }
          Rectangle { Layout.fillWidth: true; Layout.topMargin: 2; height: 1; color: Util.alpha(root.teal, 0.18) }
          // Last call: requests close in a while (the phones say when), or now.
          // Locked, it only shows once one is set.
          RowLayout {
            visible: !!root.guests && (!root.locked || !!root.deck.lastCall)
            Layout.fillWidth: true
            spacing: 8
            Label {
              Layout.fillWidth: true
              text: !root.deck.lastCall ? strings.t("deck.lastCall")
                    : Date.now() / 1000 >= root.deck.lastCall ? strings.t("deck.requestsClosed")
                    : strings.t("deck.closesAt").arg(new Date(root.deck.lastCall * 1000).toLocaleTimeString(Qt.locale(Commons.I18n.formatLocale), Locale.ShortFormat))
              font.pixelSize: Style.font.caption; color: root.deck.lastCall ? root.amber : root.ink; opacity: root.deck.lastCall ? 1 : 0.7
            }
            HeadLink { visible: !root.locked && (!root.deck.lastCall); text: "15m"; onTapped: root.run(["deck", "requests", "lastcall", "15"]) }
            HeadLink { visible: !root.locked && (!root.deck.lastCall); text: "30m"; onTapped: root.run(["deck", "requests", "lastcall", "30"]) }
            HeadLink { visible: !root.locked && (!root.deck.lastCall); text: strings.t("deck.closeNow"); onTapped: root.run(["deck", "requests", "lastcall", "0"]) }
            HeadLink { visible: !root.locked && (!!root.deck.lastCall); glyph: "󰑐"; text: strings.t("deck.reopen"); onTapped: root.run(["deck", "requests", "lastcall", "off"]) }
          }
          // Who's asked tonight: faces, names, how many asked and played (most played first).
          Rectangle { visible: root.people.length > 0; Layout.fillWidth: true; Layout.topMargin: 2; height: 1; color: Util.alpha(root.teal, 0.18) }
          RowLayout {
            visible: root.people.length > 0
            Layout.fillWidth: true
            Label {
              Layout.fillWidth: true
              text: strings.t("deck.peopleTonight").arg(root.people.length).toUpperCase()
              font.pixelSize: Style.font.caption; font.letterSpacing: 2; color: root.teal
            }
            // Start fresh: every guest, their selfies and requests go. Tap twice.
            HeadLink {
              visible: !root.locked
              glyph: root.forgetArmed ? "󰀦" : "󰃢"
              text: root.forgetArmed ? strings.t("deck.guestsForgetSure") : strings.t("deck.guestsForget")
              onTapped: {
                if (root.forgetArmed) { root.forgetArmed = false; root.run(["deck", "guests", "forget"]) }
                else { root.forgetArmed = true; forgetDisarm.restart() }
              }
            }
            Timer { id: forgetDisarm; interval: 4000; onTriggered: root.forgetArmed = false }
          }
          Label {
            visible: root.people.length > 0 && !root.locked
            Layout.fillWidth: true
            wrapMode: Text.Wrap
            text: strings.t("deck.guestsDropHint")
            font.pixelSize: Style.font.caption - 1; opacity: 0.45
          }
          Flow {
            visible: root.people.length > 0
            Layout.fillWidth: true
            spacing: 10
            Repeater {
              // Two rows; the rest behind a +N (tap it to see everyone).
              model: root.people.length > 8 && !root.guestsAll ? root.people.slice(0, 7) : root.people.slice(0, 24)
              delegate: Column {
                id: guest
                required property var modelData
                required property int index
                readonly property bool leader: (modelData.played || 0) > 0 && modelData.played === (root.people[0].played || 0)
                width: 68
                spacing: 3
                Rectangle {
                  anchors.horizontalCenter: parent.horizontalCenter
                  width: 48; height: 48; radius: 24
                  color: root.ground
                  border.width: guest.leader ? 3 : 2
                  border.color: guest.leader ? root.amber : root.teal
                  Image {
                    id: guestFace
                    anchors.fill: parent; anchors.margins: 3
                    source: (guest.modelData.photo || "") !== "" ? "file://" + guest.modelData.photo : ""
                    fillMode: Image.PreserveAspectCrop
                    asynchronous: true
                    layer.enabled: true
                    layer.effect: MultiEffect { maskEnabled: true; maskSource: guestMask }
                  }
                  Rectangle { id: guestMask; anchors.fill: guestFace; radius: width / 2; visible: false; layer.enabled: true }
                  Label { anchors.centerIn: parent; visible: guestFace.status !== Image.Ready; text: (guest.modelData.name || "?").charAt(0).toUpperCase(); font.bold: true; color: root.teal }
                  HoverHandler { id: guestHover }
                  TapHandler { enabled: !root.locked; onLongPressed: root.dropArmed = guest.modelData.gid }
                  // Drop this guest: hover (or press and hold) for the ✕.
                  Rectangle {
                    visible: !root.locked && (guestHover.hovered || root.dropArmed === guest.modelData.gid)
                    anchors.right: parent.right; anchors.top: parent.top; anchors.margins: -5
                    width: 20; height: 20; radius: 10
                    color: dropHover.hovered ? Commons.Color.warning : root.ground
                    border.width: 1; border.color: Commons.Color.warning
                    Label { anchors.centerIn: parent; text: "󰅖"; font.family: "Iosevka Nerd Font Propo"; font.pixelSize: 11; color: dropHover.hovered ? root.ground : Commons.Color.warning }
                    HoverHandler { id: dropHover; cursorShape: Qt.PointingHandCursor }
                    TapHandler { onTapped: { root.dropArmed = ""; root.run(["deck", "guests", "drop", guest.modelData.gid]) } }
                  }
                }
                Label { width: parent.width; horizontalAlignment: Text.AlignHCenter; text: guest.modelData.name; font.pixelSize: Style.font.caption; elide: Text.ElideRight }
                Label {
                  width: parent.width; horizontalAlignment: Text.AlignHCenter
                  text: strings.t("deck.personCounts").arg(guest.modelData.asked).arg(guest.modelData.played)
                  font.pixelSize: Style.font.caption - 1; opacity: 0.55
                }
              }
            }
            Item {
              visible: root.people.length > 8 && !root.guestsAll
              width: 68; height: 48
              Rectangle {
                anchors.horizontalCenter: parent.horizontalCenter
                width: 48; height: 48; radius: 24
                color: moreHover.hovered ? Util.alpha(root.teal, 0.14) : "transparent"
                border.width: 1; border.color: Util.alpha(root.teal, 0.6)
                Label { anchors.centerIn: parent; text: "+" + (root.people.length - 7); font.bold: true; color: root.teal }
                HoverHandler { id: moreHover; cursorShape: Qt.PointingHandCursor }
                TapHandler { onTapped: root.guestsAll = true }
              }
            }
          }
          Label {
            visible: root.people.length > 12
            text: strings.t("deck.requestsMore").arg(root.people.length - 12)
            font.pixelSize: Style.font.caption; opacity: 0.5
          }
        }
      }

      // ---- the Bloom
      Item {
        id: bloom
        anchors.fill: parent
        z: 150
        visible: opacity > 0
        opacity: root.bloomOpen ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: Style.duration(root.bloomOpen ? 160 : 110); easing.type: Easing.OutCubic } }
        // A dim veil: a tap on it closes the Bloom.
        Rectangle {
          anchors.fill: parent
          color: root.ground
          opacity: 0.45
          TapHandler { enabled: root.bloomOpen; onTapped: root.closeBloom() }
        }
        Item {
          id: flower
          x: root.bloomAt.x
          y: root.bloomAt.y
          property real reach: root.bloomOpen ? 92 : 40
          Behavior on reach { NumberAnimation { duration: Style.duration(200); easing.type: Easing.OutCubic } }
          scale: root.bloomOpen ? 1 : 0.95
          Behavior on scale { NumberAnimation { duration: Style.duration(180); easing.type: Easing.OutCubic } }
          // Two rings, the look's two colours.
          Rectangle {
            x: -flower.reach; y: -flower.reach
            width: flower.reach * 2; height: width; radius: width / 2
            color: "transparent"
            border.width: 1
            border.color: Util.alpha(root.amber, 0.35)
          }
          Rectangle {
            x: -flower.reach * 0.62; y: -flower.reach * 0.62
            width: flower.reach * 1.24; height: width; radius: width / 2
            color: Util.alpha(root.ground, 0.6)
            border.width: 1
            border.color: Util.alpha(root.teal, 0.3)
          }
          // The line from the middle toward the petal being aimed at.
          Rectangle {
            visible: root.bloomPick >= 0
            width: flower.reach - 30
            height: 2
            radius: 1
            transformOrigin: Item.Left
            rotation: root.bloomPick >= 0 ? root.petals[root.bloomPick].angle : 0
            gradient: Gradient {
              orientation: Gradient.Horizontal
              GradientStop { position: 0; color: Util.alpha(root.amber, 0.1) }
              GradientStop { position: 1; color: root.amber }
            }
          }
          // What's being placed, in the middle.
          Rectangle {
            x: -27; y: -27
            width: 54; height: 54
            radius: Style.cornerRadius > 0 ? 8 : 0
            color: root.ground
            border.width: 2
            border.color: root.amber
            Cover {
              anchors.fill: parent
              anchors.margins: 3
              url: root.bloomItem ? root.bloomItem.thumb || "" : ""
              size: 48
              glyph: root.bloomFrom === "save" || root.bloomFrom === "export" ? "󰆓" : root.bloomMany ? "󰲸" : "󰎈"
            }
          }
          Repeater {
            model: root.petals
            delegate: Rectangle {
              id: petal
              required property var modelData
              required property int index
              readonly property bool aimed: root.bloomPick === index
              readonly property real rad: modelData.angle * Math.PI / 180
              x: Math.cos(rad) * flower.reach - width / 2
              y: Math.sin(rad) * flower.reach - height / 2
              width: petalRow.implicitWidth + 22
              height: 34
              radius: 17
              color: aimed ? Util.alpha(modelData.key === "remove" ? Commons.Color.urgent : root.amber, 0.28) : root.ground
              border.width: aimed ? 2 : 1
              border.color: modelData.key === "remove" ? Commons.Color.urgent : (index % 2 ? root.teal : root.amber)
              scale: aimed ? 1.1 : 1
              Behavior on scale { NumberAnimation { duration: Style.duration(120); easing.type: Easing.OutCubic } }
              Row {
                id: petalRow
                anchors.centerIn: parent
                spacing: 7
                Label { text: petal.modelData.glyph; font.family: "Iosevka Nerd Font Propo"; color: petal.border.color }
                Label { text: petal.modelData.label.toUpperCase(); font.pixelSize: Style.font.caption; font.letterSpacing: 1.5; font.bold: petal.aimed }
              }
              HoverHandler {
                cursorShape: Qt.PointingHandCursor
                onHoveredChanged: if (!root.bloomFlick) root.bloomPick = hovered ? petal.index : (root.bloomPick === petal.index ? -1 : root.bloomPick)
              }
              TapHandler { onTapped: root.chooseBloom(petal.index) }
            }
          }
          // The title, under it all.
          Label {
            x: -150
            y: flower.reach + 26
            width: 300
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
            text: root.bloomItem ? root.bloomItem.title : ""
            font.bold: true
          }
        }
      }

      // ---- the QR code, big, for a phone to scan (tap or Esc closes it)
      Rectangle {
        anchors.fill: parent
        z: 90
        visible: root.qrBig && root.showQr
        color: Util.alpha(root.ground, 0.88)
        TapHandler { onTapped: root.qrBig = false }
        Column {
          anchors.centerIn: parent
          spacing: 16
          Rectangle {
            width: Math.min(380, stage.height * 0.6); height: width
            radius: Style.cornerRadius > 0 ? 10 : 0
            color: "white"
            Image {
              anchors.fill: parent; anchors.margins: 14
              source: root.guests && root.guests.qr ? "file://" + root.guests.qr + "?" + root.guests.since : ""
              smooth: false; cache: false
              fillMode: Image.PreserveAspectFit
            }
          }
          Label { anchors.horizontalCenter: parent.horizontalCenter; text: strings.t("deck.stageScan"); font.pixelSize: Style.font.subtitle; color: root.teal }
        }
      }

      // ---- the tooltip
      Rectangle {
        z: 1000
        visible: root.tipShown && !root.dragging && !root.bloomOpen
        width: tipLabel.implicitWidth + 14
        height: tipLabel.implicitHeight + 8
        x: Math.max(4, Math.min(stage.width - width - 4, root.tipAt.x - width / 2))
        y: root.tipAt.y + height + 4 > stage.height ? root.tipAt.y - height - 40 : root.tipAt.y
        radius: Style.cornerRadius > 0 ? 4 : 0
        color: Qt.tint(root.ground, Util.alpha(root.ink, 0.08))
        border.width: 1
        border.color: Util.alpha(root.amber, 0.45)
        Label { id: tipLabel; anchors.centerIn: parent; text: root.tipText; font.pixelSize: Style.font.caption }
      }

      // ---- a cover flying to where it landed, and the glow it leaves
      Rectangle {
        id: landing
        z: 140
        radius: Style.cornerRadius > 0 ? 8 : 0
        color: Util.alpha(root.amber, 0.12)
        border.width: 2
        border.color: root.amber
        opacity: 0
      }
      Item {
        id: flyer
        z: 160
        width: 48; height: 48
        property string thumb: ""
        property bool removing: false
        property real fromX: 0; property real fromY: 0
        property real toX: 0; property real toY: 0
        opacity: 0
        Cover { anchors.fill: parent; url: flyer.thumb; size: 48 }
      }
      SequentialAnimation {
        id: flight
        PropertyAction { target: flyer; property: "opacity"; value: 1 }
        PropertyAction { target: flyer; property: "scale"; value: 1 }
        ParallelAnimation {
          // Across on one curve and down on another: an arc.
          NumberAnimation { target: flyer; property: "x"; from: flyer.fromX; to: flyer.toX; duration: Style.duration(340); easing.type: Easing.InOutCubic }
          NumberAnimation { target: flyer; property: "y"; from: flyer.fromY; to: flyer.toY; duration: Style.duration(340); easing.type: flyer.toY < flyer.fromY ? Easing.OutCubic : Easing.InCubic }
          NumberAnimation { target: flyer; property: "scale"; to: flyer.removing ? 0.6 : 0.8; duration: Style.duration(340) }
          NumberAnimation { target: flyer; property: "opacity"; to: flyer.removing ? 0 : 1; duration: Style.duration(340) }
        }
        ParallelAnimation {
          NumberAnimation { target: flyer; property: "opacity"; to: 0; duration: Style.duration(120) }
          SequentialAnimation {
            NumberAnimation { target: landing; property: "opacity"; to: flyer.removing ? 0 : 0.9; duration: Style.duration(90) }
            NumberAnimation { target: landing; property: "opacity"; to: 0; duration: Style.duration(420); easing.type: Easing.OutCubic }
          }
        }
      }

      // ---- the ghost that follows a drag
      Rectangle {
        id: ghost
        visible: root.dragging
        width: ghostRow.implicitWidth + 20
        height: 56
        radius: Style.cornerRadius > 0 ? 6 : 0
        color: Commons.Color.popups.background || root.ground
        border.width: 1
        border.color: root.amber
        rotation: -2
        z: 100
        Drag.active: root.dragging
        Drag.keys: root.dragFrom === "room" ? ["deck-room"] : ["deck-song"]
        Drag.hotSpot.x: 0
        Drag.hotSpot.y: height / 2
        RowLayout {
          id: ghostRow
          anchors.verticalCenter: parent.verticalCenter
          x: 6
          spacing: 10
          Cover { url: root.dragThumb; size: 44; glyph: root.dragFrom === "room" ? "󰓃" : "󰎈" }
          Label { text: root.dragTitle; font.bold: true; Layout.maximumWidth: 260 }
        }
      }
    }
  }

  // "Song (Radio Edit) [From the Film]": main "Song", extra "Radio Edit · From the Film".
  function titleParts(title) {
    const t = String(title || "")
    const extra = []
    const main = t.replace(/\s*[\(\[]([^\)\]]{2,80})[\)\]]/g, function(all, inside) { extra.push(inside.trim()); return "" }).trim()
    return main ? { main: main, extra: extra.join(" · ") } : { main: t, extra: "" }
  }

  function clock(seconds) {
    const s = Math.max(0, Math.floor(seconds || 0))
    return Math.floor(s / 60) + ":" + String(s % 60).padStart(2, "0")
  }

  // ------------------------------------------------------------ parts
  // A cover from the web (Apple's or YouTube's own images), or a glyph.
  // A guest's request: the song, who asked (their selfie on the cover's
  // corner), and what to do with it.
  component RequestRow: RowLayout {
    id: rr
    property var req: ({})
    property int coverSize: 36
    spacing: 10
    Item {
      implicitWidth: rr.coverSize + 10; implicitHeight: rr.coverSize + 10
      Cover { url: rr.req.thumb || ""; size: rr.coverSize }
      Rectangle {
        visible: (rr.req.photo || "") !== "" || (rr.req.by || "") !== ""
        anchors.right: parent.right; anchors.bottom: parent.bottom
        width: rr.coverSize * 0.66; height: width; radius: width / 2
        color: root.ground
        border.width: 2; border.color: root.teal
        clip: true
        Image {
          id: face
          anchors.fill: parent; anchors.margins: 2
          source: (rr.req.photo || "") !== "" ? "file://" + rr.req.photo : ""
          fillMode: Image.PreserveAspectCrop
          asynchronous: true
          layer.enabled: true
          layer.effect: MultiEffect { maskEnabled: true; maskSource: faceMask }
        }
        Rectangle { id: faceMask; anchors.fill: face; radius: width / 2; visible: false; layer.enabled: true }
        Label {
          anchors.centerIn: parent
          visible: face.status !== Image.Ready
          text: (rr.req.by || "?").charAt(0).toUpperCase()
          font.pixelSize: rr.coverSize * 0.26; font.bold: true; color: root.teal
        }
      }
    }
    ColumnLayout {
      Layout.fillWidth: true
      spacing: 1
      Label { Layout.fillWidth: true; text: rr.req.title || ""; font.bold: true; font.pixelSize: rr.coverSize > 40 ? Style.font.body : Style.font.caption }
      Label {
        Layout.fillWidth: true
        text: (rr.req.artist || "") + (rr.req.by ? "  ·  " + strings.t("deck.requestBy").arg(rr.req.by) : "")
        font.pixelSize: Style.font.caption; opacity: 0.6
      }
      Label {
        Layout.fillWidth: true
        visible: (rr.req.note || "") !== ""
        text: "“" + (rr.req.note || "") + "”"
        font.pixelSize: Style.font.caption; font.italic: true; color: root.teal
        elide: Text.ElideRight
      }
    }
    RoundButton { glyph: "◆"; tip: strings.t("deck.requestMix"); onClicked: root.run(["deck", "request", "take", rr.req.rid, "--mix"]) }
    RoundButton { glyph: "󰒭"; tip: strings.t("deck.bloomNext"); onClicked: root.run(["deck", "request", "take", rr.req.rid, "--next"]) }
    RoundButton { glyph: "󰐒"; tip: strings.t("deck.bloomLater"); onClicked: root.run(["deck", "request", "take", rr.req.rid]) }
    RoundButton { visible: !root.locked; glyph: "󰅖"; tip: strings.t("deck.requestDrop"); onClicked: root.run(["deck", "request", "drop", rr.req.rid]) }
  }

  // The requests page's QR code on white; tap it for it big.
  component QrTile: Rectangle {
    id: qt
    property int size: 46
    implicitWidth: size; implicitHeight: size
    Layout.preferredWidth: size; Layout.preferredHeight: size
    radius: Style.cornerRadius > 0 ? 4 : 0
    color: "white"
    Image {
      anchors.fill: parent; anchors.margins: Math.max(3, qt.size * 0.04)
      source: root.guests && root.guests.qr ? "file://" + root.guests.qr + "?" + root.guests.since : ""
      smooth: false; cache: false
      fillMode: Image.PreserveAspectFit
    }
    HoverHandler { cursorShape: Qt.PointingHandCursor; onHoveredChanged: root.hint(qt, strings.t("deck.qrTapHint"), hovered) }
    TapHandler { onTapped: root.qrBig = true }
  }

  // A cover that changes by dissolving: the new one loads out of sight, then
  // fades in over the old (settling from a touch larger), never a blank.
  // A choice in the Auto-DJ panel: lit when it's the one in use.
  component DjChip: Rectangle {
    id: chip
    property string text: ""
    property string glyph: ""
    property bool on: false
    signal tapped()
    implicitWidth: chipLine.implicitWidth + 20
    implicitHeight: 30
    radius: 15
    color: on ? Util.alpha(root.amber, 0.22) : chipMouse.hovered ? Util.alpha(root.teal, 0.14) : Util.alpha(root.teal, 0.05)
    border.width: 1
    border.color: on ? root.amber : Util.alpha(root.teal, chipMouse.hovered ? 0.9 : 0.4)
    Row {
      id: chipLine
      anchors.centerIn: parent
      spacing: 6
      Label { visible: chip.glyph !== ""; text: chip.glyph; font.family: "Iosevka Nerd Font Propo"; color: chip.on ? root.amber : root.teal }
      Label { text: chip.text; font.pixelSize: Style.font.caption; color: root.ink; font.bold: chip.on }
    }
    HoverHandler { id: chipMouse; cursorShape: Qt.PointingHandCursor }
    TapHandler { onTapped: chip.tapped() }
  }

  component CrossCover: Item {
    id: cross
    property string url: ""
    property int size: 48
    property real radius: 0
    property string glyph: "󰎈"
    property bool live: true            // off-screen: just swap
    property bool aFront: true
    property bool pending: false
    readonly property var front: aFront ? crossA : crossB
    readonly property var back: aFront ? crossB : crossA
    Cover { id: crossA; anchors.fill: parent; size: cross.size; radius: cross.radius; glyph: cross.glyph; z: cross.aFront ? 0 : 1 }
    Cover { id: crossB; anchors.fill: parent; size: cross.size; radius: cross.radius; glyph: cross.glyph; z: cross.aFront ? 1 : 0; opacity: 0 }
    Component.onCompleted: crossA.url = url
    onUrlChanged: {
      if (url === front.url) { pending = false; return }
      if (!live || Style.reduceMotion || front.url === "") { swap.stop(); front.url = url; back.opacity = 0; pending = false; return }
      swap.stop()
      back.opacity = 0; back.scale = 1.03
      back.url = url
      pending = true; waited.restart()
    }
    Timer { id: waited; interval: 4000; onTriggered: if (cross.pending) swap.restart() }
    Timer {
      running: cross.pending && !swap.running
      interval: 40; repeat: true
      onTriggered: if (cross.back.ready) swap.restart()
    }
    SequentialAnimation {
      id: swap
      ScriptAction { script: cross.pending = false }
      ParallelAnimation {
        NumberAnimation { target: cross.back; property: "opacity"; to: 1; duration: Style.duration(900); easing.type: Easing.InOutQuad }
        NumberAnimation { target: cross.back; property: "scale"; to: 1; duration: Style.duration(1400); easing.type: Easing.OutCubic }
      }
      ScriptAction { script: { cross.aFront = !cross.aFront; cross.back.opacity = 0 } }
    }
  }

  component Cover: Rectangle {
    id: cover
    property string url: ""
    readonly property bool ready: art.status === Image.Ready
    property int size: 48
    property string glyph: "󰎈"
    implicitWidth: size
    implicitHeight: size
    radius: Style.cornerRadius > 0 ? 3 : 0
    color: Util.alpha(root.ink, 0.05)
    clip: true
    Image {
      id: art
      // Apple's image server sometimes drops a request when many go at once:
      // try again a few times, a little later each time.
      property int tries: 0
      anchors.fill: parent
      source: /^https:\/\//.test(cover.url) ? cover.url + (tries > 0 ? "#" + tries : "") : ""
      onStatusChanged: if (status === Image.Error && tries < 4) retry.start()
      fillMode: Image.PreserveAspectCrop
      asynchronous: true
      sourceSize.width: cover.size * 2
      sourceSize.height: cover.size * 2
      // Rounded corners (clip alone keeps them square): only on big covers.
      layer.enabled: cover.radius > 4
      layer.effect: MultiEffect { maskEnabled: true; maskSource: artMask; maskThresholdMin: 0.5; maskSpreadAtMin: 1.0 }
    }
    Rectangle { id: artMask; anchors.fill: art; radius: cover.radius; visible: false; layer.enabled: true; antialiasing: true }
    Timer { id: retry; interval: 700 * (art.tries + 1); onTriggered: art.tries++ }
    onUrlChanged: art.tries = 0
    Label {
      anchors.centerIn: parent
      visible: !/^https:\/\//.test(cover.url)
      text: cover.glyph
      font.family: "Iosevka Nerd Font Propo"
      font.pixelSize: cover.size * 0.4
      color: root.amber
    }
  }

  // A room: tap to play the Deck there, drop a song on it to play it there.
  // In the capsule it has its own volume and can be dragged out; outside, it
  // can be dragged in (or + on hover).
  component RoomTile: Rectangle {
    id: tile
    property string roomId: ""
    property string name: ""
    property bool laptop: false
    property bool here: false
    property bool lead: false
    property bool busy: false
    property var volume: null
    property real heldVolume: 0
    property bool holding: false
    readonly property real shownVolume: holding ? heldVolume : (volume === null || volume === undefined ? 0 : volume)
    readonly property bool lifted: root.dragging && root.dragFrom === "room" && root.dragUid === roomId
    implicitWidth: root.tileWidth
    implicitHeight: 72
    radius: Style.cornerRadius > 0 ? 7 : 0
    // Solid (the tint laid over the ground), so the line between rooms passes behind.
    color: Qt.tint(root.ground, tileDrop.containsDrag ? Util.alpha(root.teal, 0.18) : here ? Util.alpha(root.amber, 0.12)
                                : Util.alpha(root.ink, tileHover.hovered ? 0.05 : 0.025))
    border.width: 1
    border.color: tileDrop.containsDrag ? root.teal : here ? Util.alpha(root.amber, 0.8) : Util.alpha(root.ink, tileHover.hovered ? 0.2 : 0.1)
    opacity: lifted ? 0.35 : 1
    scale: tileDrop.containsDrag ? 1.04 : 1
    Behavior on scale { NumberAnimation { duration: Style.duration(140); easing.type: Easing.OutCubic } }
    Behavior on color { ColorAnimation { duration: Style.duration(160) } }

    ColumnLayout {
      anchors.fill: parent
      anchors.margins: 8
      anchors.bottomMargin: 6
      spacing: 2
      RowLayout {
        Layout.fillWidth: true
        spacing: 6
        Label {
          text: tile.laptop ? (tile.here && root.laptopOut && root.laptopOut.kind !== "speaker" ? root.outGlyph : "󰌢") : tile.lead && root.partyRooms.length > 1 ? "󰴸" : "󰓃"
          font.family: "Iosevka Nerd Font Propo"
          color: tile.here ? root.amber : root.teal
        }
        Label { Layout.fillWidth: true; text: tile.name; font.bold: true; elide: Text.ElideRight }
      }
      RowLayout {
        Layout.fillWidth: true
        spacing: 6
        Equalizer { on: tile.here && root.deck.playing; visible: tile.here && !!root.now }
        Label {
          Layout.fillWidth: true
          text: tile.here ? (root.now ? (root.deck.playing ? root.now.title : strings.t("deck.paused")) : strings.t("deck.here"))
                : tile.busy ? "●  " + strings.t("deck.busy")
                : tileHover.hovered || root.dragging ? strings.t("deck.dropHere") : ""
          font.pixelSize: Style.font.caption
          color: tile.here ? root.amber : tile.busy ? root.teal : root.ink
          opacity: tile.here || tile.busy ? 0.95 : 0.5
          elide: Text.ElideRight
        }
      }
      Item { Layout.fillHeight: true }
      // Its own volume, in the capsule: drag along the line.
      Item {
        Layout.fillWidth: true
        implicitHeight: 12
        visible: tile.here && tile.volume !== null && tile.volume !== undefined
        Rectangle {
          anchors.verticalCenter: parent.verticalCenter
          width: parent.width
          height: 3
          radius: 2
          color: Util.alpha(root.ink, 0.1)
          Rectangle {
            height: parent.height
            radius: 2
            width: parent.width * tile.shownVolume / 100
            gradient: Gradient {
              orientation: Gradient.Horizontal
              GradientStop { position: 0; color: root.amber }
              GradientStop { position: 1; color: root.teal }
            }
          }
        }
        Rectangle {
          visible: volArea.containsMouse || tile.holding
          x: parent.width * tile.shownVolume / 100 - width / 2
          anchors.verticalCenter: parent.verticalCenter
          width: 10; height: 10; radius: 5
          color: root.ink
        }
        Label {
          visible: volArea.containsMouse || tile.holding
          anchors.right: parent.right
          anchors.bottom: parent.top
          text: Math.round(tile.shownVolume)
          font.pixelSize: Style.font.caption - 1
          color: root.teal
        }
        MouseArea {
          id: volArea
          anchors.fill: parent
          anchors.topMargin: -4; anchors.bottomMargin: -4
          hoverEnabled: true
          preventStealing: true
          cursorShape: Qt.PointingHandCursor
          function at(x) { return Math.max(0, Math.min(100, Math.round(x / width * 100))) }
          onPressed: function(mouse) { tile.holding = true; root.roomHeld = true; tile.heldVolume = at(mouse.x) }
          onPositionChanged: function(mouse) { if (pressed) tile.heldVolume = at(mouse.x) }
          onReleased: {
            root.run(["deck", "volume", tile.roomId, String(tile.heldVolume)])
            root.roomHeld = false
            settle.restart()
          }
        }
        // Keep showing the new level until the speakers report it back.
        Timer { id: settle; interval: 2500; onTriggered: tile.holding = false }
      }
    }

    // + or − on hover: add this room to the music, or take it out.
    Rectangle {
      visible: !tile.laptop && root.inSonos && tileHover.hovered && !root.dragging && !(tile.here && root.partyRooms.length < 2)
      anchors.right: parent.right; anchors.top: parent.top
      anchors.margins: 5
      width: 22; height: 22; radius: 11
      color: linkHover.hovered ? Util.alpha(tile.here ? Commons.Color.urgent : root.teal, 0.3) : Util.alpha(root.ground, 0.85)
      border.width: 1
      border.color: tile.here ? Util.alpha(Commons.Color.urgent, 0.7) : root.teal
      Label {
        anchors.centerIn: parent
        text: tile.here ? "󰌺" : "󰌹"
        font.family: "Iosevka Nerd Font Propo"
        font.pixelSize: Style.font.caption
        color: tile.here ? Commons.Color.urgent : root.teal
      }
      HoverHandler { id: linkHover; cursorShape: Qt.PointingHandCursor }
      TapHandler { onTapped: root.run(["deck", tile.here ? "leave" : "join", tile.roomId]) }
    }

    HoverHandler { id: tileHover; cursorShape: tile.here ? Qt.ArrowCursor : Qt.PointingHandCursor }
    TapHandler { onTapped: if (!tile.here) root.run(["deck", "where", tile.roomId]) }
    // Rooms move between the capsule and the rest by dragging (only once the
    // Deck plays in a Sonos room); the grip is the tile above its volume line.
    Item {
      anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
      height: parent.height - 18
      DragHandler {
        target: null
        enabled: !tile.laptop && root.inSonos
        onActiveChanged: if (active) root.beginDrag("room", tile.roomId, null, tile.name, "")
                         else if (root.dragging) root.endDrag()
        onCentroidChanged: if (active) root.moveGhost(tile.mapToItem(root.stageItem, centroid.position.x, centroid.position.y))
      }
    }
    DropArea {
      id: tileDrop
      anchors.fill: parent
      keys: ["deck-song"]
      onDropped: root.playDropped(tile.here ? "" : tile.roomId)
    }
  }

  // Three bars that dance while the music plays.
  component Equalizer: Row {
    id: eq
    property bool on: false
    spacing: 2
    height: 10
    Repeater {
      model: [520, 380, 610]
      delegate: Rectangle {
        required property var modelData
        width: 2
        radius: 1
        anchors.bottom: parent.bottom
        color: root.amber
        height: 3
        SequentialAnimation on height {
          running: eq.on && root.open && Style.duration(100) > 0
          loops: Animation.Infinite
          NumberAnimation { to: 10; duration: modelData; easing.type: Easing.InOutSine }
          NumberAnimation { to: 3; duration: modelData * 0.8; easing.type: Easing.InOutSine }
        }
        Binding on height { when: !eq.on; value: 3 }
      }
    }
  }

  // A quiet link in a header: a glyph and maybe a word.
  component HeadLink: Item {
    id: hl
    property string glyph: ""
    property string text: ""
    property bool on: false
    property string tip: ""
    signal tapped()
    implicitWidth: hlRow.implicitWidth
    implicitHeight: hlRow.implicitHeight
    Row {
      id: hlRow
      spacing: 6
      Label { text: hl.glyph; font.family: "Iosevka Nerd Font Propo"; font.pixelSize: Style.font.caption; color: hl.on ? root.amber : root.ink }
      Label { visible: hl.text !== ""; text: hl.text; font.pixelSize: Style.font.caption; color: hl.on ? root.amber : root.ink }
    }
    opacity: hlHover.hovered || hl.on ? 1 : 0.55
    HoverHandler { id: hlHover; cursorShape: Qt.PointingHandCursor; onHoveredChanged: root.hint(hl, hl.tip, hovered) }
    TapHandler { onTapped: { root.hint(hl, "", false); hl.tapped() } }
  }

  // A floating pill over the list: back to the top, on to the end.
  component Pill: Rectangle {
    id: pill
    property string glyph: ""
    property string text: ""
    property bool shown: false
    signal tapped()
    implicitWidth: pillRow.implicitWidth + 22
    implicitHeight: 30
    radius: 15
    color: Qt.tint(root.ground, Util.alpha(root.amber, pillHover.hovered ? 0.3 : 0.16))
    border.width: 1
    border.color: Util.alpha(root.amber, 0.7)
    opacity: shown ? 1 : 0
    scale: shown ? 1 : 0.96
    visible: opacity > 0
    Behavior on opacity { NumberAnimation { duration: Style.duration(shown ? 180 : 120); easing.type: Easing.OutCubic } }
    Behavior on scale { NumberAnimation { duration: Style.duration(180); easing.type: Easing.OutCubic } }
    Row {
      id: pillRow
      anchors.centerIn: parent
      spacing: 6
      Label { text: pill.glyph; font.family: "Iosevka Nerd Font Propo"; color: root.amber }
      Label { text: pill.text.toUpperCase(); font.pixelSize: Style.font.caption; font.letterSpacing: 2; color: root.amber }
    }
    HoverHandler { id: pillHover; cursorShape: Qt.PointingHandCursor }
    TapHandler { onTapped: pill.tapped() }
  }

  // The whole set in a strip: each song a tick (by its energy, accent when
  // it's high, cyan when calm), the energy as a line, marks where something
  // doesn't sit well, chapters as gaps, and the part you can see. Tap or drag
  // to go there.
  component Minimap: Item {
    id: map
    readonly property var set: root.deck.set || []
    readonly property var list: root.wall ? wallView : setList
    Canvas {
      id: paint
      anchors.fill: parent
      onPaint: {
        const g = getContext("2d")
        g.reset()
        const n = map.set.length
        const h = height, w = width, step = h / Math.max(1, n)
        const css = (c, a) => "rgba(" + Math.round(c.r * 255) + "," + Math.round(c.g * 255) + "," + Math.round(c.b * 255) + "," + a + ")"
        // An empty set still shows where the shape will be.
        if (!n) { g.fillStyle = css(root.ink, 0.12); g.fillRect(w - 6, 0, 6, h); return }
        const tone = (e) => e > 0 ? css(Qt.tint(root.teal, Util.alpha(root.amber, Math.min(1, Math.max(0, (e - 2) / 7)))), 0.85)
                                  : css(root.ink, 0.22)
        for (let i = 0; i < n; i++) {
          const s = map.set[i]
          const c = root.chapters[i]
          const y = i * step
          if (c && c.opens && i > 0) { g.fillStyle = css(root.amber, 0.9); g.fillRect(0, y, w, 1) }
          g.fillStyle = tone(s.energy || 0)
          g.fillRect(w - 6, y + (step > 3 ? 0.5 : 0), 6, Math.max(1, step - (step > 3 ? 1 : 0)))
          if ((s.warn || []).length) { g.fillStyle = css(Commons.Color.warning, 1); g.fillRect(0, y + step / 2 - 1.5, 3, 3) }
        }
        // The energy line: further left is higher.
        g.strokeStyle = css(root.amber, 0.9)
        g.lineWidth = 1.5
        g.lineJoin = "round"
        g.beginPath()
        const points = []
        for (let i = 0; i < n; i++) {
          const e = map.set[i].energy || 0
          if (e) points.push({ x: (w - 12) * (1 - (e - 1) / 9) + 2, y: (i + 0.5) * step })
        }
        points.forEach((p, i) => i ? g.lineTo(p.x, p.y) : g.moveTo(p.x, p.y))
        g.stroke()
        // Few songs: a dot on each, so a short set still has a shape.
        if (n <= 8) {
          g.fillStyle = css(root.amber, 0.95)
          points.forEach((p) => { g.beginPath(); g.arc(p.x, p.y, 2.5, 0, Math.PI * 2); g.fill() })
        }
      }
      Connections { target: root; function onDeckChanged() { paint.requestPaint() } }
      onWidthChanged: requestPaint()
      onHeightChanged: requestPaint()
    }
    // What you can see (not when it all fits: then the shape reads alone).
    Rectangle {
      readonly property real total: Math.max(1, map.list.contentHeight)
      visible: map.list.contentHeight > map.list.height + 4
      x: -2
      width: parent.width + 4
      y: Math.max(0, Math.min(parent.height - height, (map.list.contentY - map.list.originY) / total * parent.height))
      height: Math.max(12, Math.min(parent.height, map.list.height / total * parent.height))
      radius: Style.cornerRadius > 0 ? 3 : 0
      color: Util.alpha(root.ink, 0.06)
      border.width: 1
      border.color: Util.alpha(root.ink, 0.3)
    }
    function go(y) {
      const i = Math.max(0, Math.min(map.set.length - 1, Math.floor(y / height * map.set.length)))
      map.list.positionViewAtIndex(i, root.wall ? GridView.Center : ListView.Center)
    }
    HoverHandler { cursorShape: Qt.PointingHandCursor }
    TapHandler { onTapped: function(point) { map.go(point.position.y) } }
    DragHandler { target: null; onCentroidChanged: if (active) map.go(centroid.position.y) }
  }

  component RoundButton: Rectangle {
    id: rb
    property string glyph: ""
    property string tip: ""
    property bool on: false
    signal clicked()
    implicitWidth: 28
    implicitHeight: 28
    radius: 14
    color: rbHover.hovered ? Util.alpha(root.ink, 0.08) : "transparent"
    Label {
      anchors.centerIn: parent
      text: rb.glyph
      font.family: "Iosevka Nerd Font Propo"
      color: rb.on ? root.amber : root.ink
      opacity: rbHover.hovered || rb.on ? 1 : 0.6
    }
    HoverHandler { id: rbHover; cursorShape: Qt.PointingHandCursor; onHoveredChanged: root.hint(rb, rb.tip, hovered) }
    TapHandler { onTapped: { root.hint(rb, "", false); rb.clicked() } }
  }
}
