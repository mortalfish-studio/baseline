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
  property var roomList: []
  property string roomText: ""
  readonly property var partyRooms: roomList.filter(r => r.here).sort((a, b) => (b.lead ? 1 : 0) - (a.lead ? 1 : 0))
  readonly property var otherRooms: roomList.filter(r => !r.here)
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
  function find(words) {
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
  readonly property var petals: [
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
  property bool playedOpen: false

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
        if (root.bloomOpen) root.closeBloom()
        else if (root.selectedUids.length) root.clearPicked()
        else if (root.filterOpen || root.saving) { root.filterOpen = false; root.saving = false; root.filter = "" }
        else if (root.popped) root.goHome()
      }
      Keys.onSpacePressed: root.run(["deck", root.deck.playing ? "pause" : "play"])
      // Home and End, N for what's playing, / to find a song, Ctrl+Z to undo,
      // Delete for the picked songs, W for the wall.
      Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Home || (event.key === Qt.Key_N && !event.modifiers)) { root.toTop(); event.accepted = true }
        else if (event.key === Qt.Key_End) { root.toEnd(); event.accepted = true }
        else if (event.key === Qt.Key_Slash) { root.saving = false; root.filterOpen = true; event.accepted = true }
        else if (event.key === Qt.Key_Z && (event.modifiers & Qt.ControlModifier)) { root.run(["deck", "undo"]); event.accepted = true }
        else if (event.key === Qt.Key_Delete && root.selectedUids.length) { root.placePicked("remove"); event.accepted = true }
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

      Rectangle {
        anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
        height: 2
        gradient: Gradient {
          orientation: Gradient.Horizontal
          GradientStop { position: 0; color: root.amber }
          GradientStop { position: 1; color: root.teal }
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
              RoundButton { glyph: "✦"; tip: strings.t("deck.build"); onClicked: { root.setCrate(true); brief.forceActiveFocus() } }
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
                Label { text: "✦  " + strings.t("deck.build").toUpperCase(); font.pixelSize: Style.font.caption; font.letterSpacing: 2; color: root.amber }
                Rectangle {
                  Layout.fillWidth: true
                  implicitHeight: Math.max(54, brief.implicitHeight + 12)
                  radius: Style.cornerRadius > 0 ? 4 : 0
                  color: Qt.rgba(1, 1, 1, 0.04)
                  border.width: 1
                  border.color: brief.activeFocus ? root.amber : Qt.rgba(1, 1, 1, 0.14)
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
                      border.color: on ? root.amber : Qt.rgba(1, 1, 1, 0.15)
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
                    enabled: brief.text.trim() !== ""
                    onClicked: {
                      const args = ["deck", "build", String(build.minutes), brief.text.trim()]
                      if (root.now) args.push("--start", root.now.title + " by " + root.now.artist)
                      if ((root.deck.set || []).length === 0) args.push("--replace")
                      root.runLong(args)
                    }
                  }
                }
                Label {
                  Layout.fillWidth: true
                  wrapMode: Text.Wrap
                  text: root.now ? strings.t("deck.buildFrom").arg(root.now.title) : strings.t("deck.buildNote")
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
                model: [{ id: "ytmusic", name: "YouTube Music", icon: "󰗃" }, { id: "applemusic", name: "Apple Music", icon: "󰀵" }]
                delegate: Rectangle {
                  required property var modelData
                  readonly property bool on: root.service === modelData.id
                  implicitWidth: svcLabel.implicitWidth + 16
                  implicitHeight: svcLabel.implicitHeight + 8
                  radius: Style.cornerRadius > 0 ? 3 : 0
                  color: on ? Util.alpha(root.amber, 0.16) : "transparent"
                  border.width: 1
                  border.color: on ? root.amber : Qt.rgba(1, 1, 1, 0.15)
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
              color: Qt.rgba(1, 1, 1, 0.04)
              border.width: 1
              border.color: query.activeFocus ? root.amber : Qt.rgba(1, 1, 1, 0.14)
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
            ListView {
              id: found
              Layout.fillWidth: true
              Layout.fillHeight: true
              clip: true
              spacing: 2
              readonly property bool shelf: root.results.length === 0 && query.text.trim() === ""
              model: shelf ? root.myPlaylists : root.results
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
                    height: 52
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
                          font.pixelSize: Style.font.caption
                          opacity: 0.6
                        }
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
                color: hitHover.hovered ? Qt.rgba(1, 1, 1, 0.05) : "transparent"
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
                    if (point.position.x > hit.width - 76) return          // the ▶ and + buttons
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
                  radius: Style.cornerRadius > 0 ? 8 : 0
                  color: "transparent"
                  border.width: 2
                  border.color: nowDrop.containsDrag ? root.teal : Util.alpha(root.amber, root.deck.playing ? 0.9 : 0.35)
                }
                Cover { anchors.fill: parent; url: root.now ? root.now.thumb || "" : ""; size: 176; glyph: "󰎆" }
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
                      text: root.now ? (root.whereId === "laptop" ? "󰓃  " + strings.t("hover.playingOn").arg(root.whereName)
                                                                : "󰜟  " + strings.t("hover.playingIn").arg(root.whereName))
                                        + " · " + (root.now.service === "applemusic" ? "Apple Music" : "YouTube Music") : ""
                      font.family: "Iosevka Nerd Font Propo"
                      font.pixelSize: Style.font.caption
                      color: root.teal
                    }
                  }
                  DeckVisualizer {
                    Layout.preferredWidth: Math.min(360, Math.max(200, root.stageItem.width * 0.24))
                    Layout.preferredHeight: 112
                    Layout.alignment: Qt.AlignTop
                    Layout.rightMargin: 8
                    visible: !!root.now
                    active: root.seen && !!root.now
                    playing: root.deck.playing
                    live: !root.inSonos
                    amber: root.amber
                    teal: root.teal
                    ground: root.ground
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
                    color: Qt.rgba(1, 1, 1, 0.1)
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
                    onClicked: root.run(["deck", root.deck.playing ? "pause" : "play"])
                  }
                  ActionButton { icon: "󰒭"; text: strings.t("deck.next"); tone: root.teal; enabled: (root.deck.set || []).length > 0; onClicked: root.run(["deck", "next"]) }
                  ActionButton { icon: "󰒝"; text: strings.t("deck.shuffle"); tone: root.teal; enabled: (root.deck.set || []).length > 1; onClicked: root.run(["deck", "shuffle"]) }
                  ActionButton { icon: "✦"; text: strings.t("deck.fill"); onClicked: root.runLong(["deck", "fill"]) }
                  // Sleep: off, 15, 30, 60 minutes, the end of this song.
                  ActionButton {
                    icon: "󰒲"
                    text: !root.sleep ? "" : root.sleep.song ? strings.t("deck.sleepSong") : strings.t("deck.sleepIn").arg(root.sleepMinutes)
                    tone: root.sleep ? root.amber : root.teal
                    onClicked: root.nextSleep()
                  }
                  // Crossfade: Sonos fades one song into the next.
                  ActionButton {
                    visible: root.inSonos
                    icon: "󰡍"
                    text: strings.t("deck.crossfade")
                    tone: root.deck.crossfade ? root.amber : root.teal
                    onClicked: root.run(["deck", "crossfade", root.deck.crossfade ? "off" : "on"])
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
              HeadLink { visible: root.selectedUids.length > 0; glyph: "󰅖"; text: strings.t("deck.remove"); onTapped: root.placePicked("remove") }
              HeadLink { visible: root.selectedUids.length > 0; glyph: "󰜺"; onTapped: root.clearPicked() }
              // Otherwise: the tools for the set.
              HeadLink {
                visible: root.selectedUids.length === 0 && (root.deck.undo || 0) > 0
                glyph: "󰕌"; text: strings.t("deck.undo"); onTapped: root.run(["deck", "undo"])
              }
              HeadLink {
                visible: root.selectedUids.length === 0 && (root.deck.set || []).length > 0
                glyph: "󰆓"; text: strings.t("deck.save")
                onTapped: { root.saving = true; root.filterOpen = false }
              }
              HeadLink {
                visible: root.selectedUids.length === 0
                glyph: "󰍉"; on: root.filterOpen
                onTapped: { root.filterOpen = !root.filterOpen; if (!root.filterOpen) root.filter = ""; root.saving = false }
              }
              HeadLink {
                visible: root.selectedUids.length === 0
                glyph: root.wall ? "󰉹" : "󰕰"; on: root.wall
                onTapped: root.wall = !root.wall
              }
              HeadLink {
                visible: root.selectedUids.length === 0 && (root.deck.set || []).length > 0
                glyph: "󰆴"; text: strings.t("deck.clear"); onTapped: root.run(["deck", "clear"])
              }
            }
            // Naming a set to save, or finding a song in this one.
            Rectangle {
              Layout.fillWidth: true
              visible: root.saving || root.filterOpen
              implicitHeight: 36
              radius: Style.cornerRadius > 0 ? 4 : 0
              color: Util.alpha(root.ink, 0.04)
              border.width: 1
              border.color: root.amber
              RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 10; anchors.rightMargin: 6
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
                  onAccepted: {
                    if (root.saving && text.trim() !== "") { root.run(["deck", "save", text.trim()]); root.saving = false; saveDone.start() }
                    else stage.forceActiveFocus()
                  }
                  Keys.onEscapePressed: { root.saving = false; root.filterOpen = false; root.filter = ""; stage.forceActiveFocus() }
                  Label {
                    visible: lineInput.text === ""
                    text: root.saving ? strings.t("deck.saveHint") : strings.t("deck.findInSet")
                    opacity: 0.4
                  }
                }
                ActionButton {
                  visible: root.saving
                  icon: "󰆓"; text: strings.t("deck.save")
                  onClicked: if (lineInput.text.trim() !== "") { root.run(["deck", "save", lineInput.text.trim()]); root.saving = false; saveDone.start() }
                }
                RoundButton { glyph: "󰅖"; onClicked: { root.saving = false; root.filterOpen = false; root.filter = ""; stage.forceActiveFocus() } }
              }
              Timer { id: saveDone; interval: 800; onTriggered: root.readShelf() }
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
                      width: setList.width
                      height: 40
                      radius: Style.cornerRadius > 0 ? 4 : 0
                      color: wasHover.hovered ? Util.alpha(root.ink, 0.05) : "transparent"
                      opacity: wasHover.hovered ? 1 : 0.55
                      RowLayout {
                        anchors.fill: parent
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
                      anchors.leftMargin: 12; anchors.rightMargin: 12
                      spacing: 12
                      Label { text: strings.t("deck.nowShort").toUpperCase(); font.pixelSize: Style.font.caption; font.letterSpacing: 3; color: root.amber; Layout.preferredWidth: 34 }
                      Cover { url: root.now ? root.now.thumb || "" : ""; size: 32 }
                      Label {
                        Layout.fillWidth: true
                        text: root.now ? root.now.title + "  ·  " + root.now.artist : ""
                        font.bold: true
                        font.pixelSize: Style.font.caption
                      }
                      Equalizer { visible: root.deck.playing; on: root.deck.playing }
                      Label {
                        text: "−" + root.clock(root.nowLeft)
                        font.pixelSize: Style.font.caption
                        color: root.teal
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
                  required property real bpm
                  required property string key
                  required property real energy
                  readonly property var info: root.chapters[index] || ({ name: "", opens: false, head: -1, count: 0, seconds: 0 })
                  readonly property bool heading: info.opens && root.filter === ""
                  readonly property bool isFolded: heading && !!root.folded[uid]
                  readonly property bool shown: root.matches(title, artist) && !root.hiddenAt(index) && !isFolded
                  width: setList.width
                  height: (heading ? 36 : 0) + (shown ? 66 : 0)
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
                    height: 62
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
                      Cover { url: slot.thumb; size: 48 }
                      ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 0
                        RowLayout {
                          Layout.fillWidth: true
                          spacing: 8
                          Label { Layout.fillWidth: true; Layout.maximumWidth: implicitWidth; text: slot.title; font.bold: true }
                          // Key and tempo, from Beatport.
                          Rectangle {
                            visible: slot.key !== "" || slot.bpm > 0
                            implicitWidth: kt.implicitWidth + 10
                            implicitHeight: kt.implicitHeight + 2
                            radius: Style.cornerRadius > 0 ? 3 : 0
                            color: "transparent"
                            border.width: 1
                            border.color: Util.alpha(root.teal, 0.35)
                            Label {
                              id: kt
                              anchors.centerIn: parent
                              text: [slot.key, slot.bpm > 0 ? Math.round(slot.bpm) : ""].filter(x => x !== "").join(" · ")
                              font.pixelSize: Style.font.caption - 1
                              color: root.teal
                            }
                          }
                          Item { Layout.fillWidth: true }
                        }
                        Label {
                          Layout.fillWidth: true
                          text: slot.artist + "  ·  " + (slot.service === "applemusic" ? "Apple Music" : "YouTube Music")
                          font.pixelSize: Style.font.caption
                          opacity: 0.6
                        }
                        Label {
                          Layout.fillWidth: true
                          visible: slot.why !== "" || row.warns.length > 0
                          text: row.warns.length > 0
                                ? "◆ " + row.warns.map(w => strings.t("deck.warn." + w)).join("  ·  ")
                                : "✦ " + slot.why
                          font.pixelSize: Style.font.caption
                          color: row.warns.length > 0 ? Commons.Color.warning : root.amber
                          opacity: 0.85
                        }
                      }
                      // When it starts.
                      Label {
                        text: root.clockAt(root.startsAt[slot.index] || 0)
                        font.pixelSize: Style.font.caption
                        color: root.teal
                        opacity: 0.75
                      }
                      RoundButton { glyph: "󰐊"; tip: strings.t("deck.playNow"); onClicked: root.run(["deck", "play", slot.uid]) }
                      RoundButton { glyph: row.isPinned ? "󰐃" : "󰤰"; tip: row.isPinned ? strings.t("deck.unpin") : strings.t("deck.pin"); on: row.isPinned; onClicked: root.run(["deck", "pin", slot.uid]) }
                      RoundButton { glyph: "󰅖"; tip: strings.t("deck.remove"); onClicked: root.run(["deck", "remove", slot.uid]) }
                    }
                    HoverHandler { id: rowHover; cursorShape: root.dragging ? Qt.ClosedHandCursor : Qt.OpenHandCursor }
                    TapHandler {
                      id: rowTap
                      longPressThreshold: 0.35
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
                      onActiveChanged: {
                        if (active) { if (root.bloomOpen) root.bloomFlick = true; else root.beginDrag("set", slot.uid, null, slot.title, slot.thumb) }
                        else if (root.bloomFlick) root.releaseFlick()
                        else if (root.dragging) root.endDrag()
                      }
                      onCentroidChanged: if (active) {
                        const at = row.mapToItem(root.stageItem, centroid.position.x, centroid.position.y)
                        if (root.bloomFlick) root.aimBloom(at); else root.moveGhost(at)
                      }
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
                y: 54
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
              Column {
                anchors.right: parent.right; anchors.bottom: parent.bottom
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
              visible: setModel.count > 8
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

              RoomTile { Layout.alignment: Qt.AlignBottom; roomId: "laptop"; name: strings.t("deck.laptop"); laptop: true; here: !root.inSonos }

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
              glyph: root.bloomMany ? "󰲸" : "󰎈"
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
  component Cover: Rectangle {
    id: cover
    property string url: ""
    property int size: 48
    property string glyph: "󰎈"
    implicitWidth: size
    implicitHeight: size
    radius: Style.cornerRadius > 0 ? 3 : 0
    color: Qt.rgba(1, 1, 1, 0.05)
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
    }
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
                                : Qt.rgba(1, 1, 1, tileHover.hovered ? 0.05 : 0.025))
    border.width: 1
    border.color: tileDrop.containsDrag ? root.teal : here ? Util.alpha(root.amber, 0.8) : Qt.rgba(1, 1, 1, tileHover.hovered ? 0.2 : 0.1)
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
          text: tile.laptop ? "󰌢" : tile.lead && root.partyRooms.length > 1 ? "󰴸" : "󰓃"
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
                : strings.t("deck.dropHere")
          font.pixelSize: Style.font.caption
          color: tile.here ? root.amber : tile.busy ? root.teal : root.ink
          opacity: tile.here || tile.busy ? 0.95 : 0.4
          elide: Text.ElideRight
        }
      }
      Item { Layout.fillHeight: true }
      // Its own volume, in the capsule: drag along the line.
      Item {
        Layout.fillWidth: true
        implicitHeight: 12
        visible: tile.here && !tile.laptop && tile.volume !== null && tile.volume !== undefined
        Rectangle {
          anchors.verticalCenter: parent.verticalCenter
          width: parent.width
          height: 3
          radius: 2
          color: Qt.rgba(1, 1, 1, 0.1)
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
    HoverHandler { id: hlHover; cursorShape: Qt.PointingHandCursor }
    TapHandler { onTapped: hl.tapped() }
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
        if (!n) return
        const h = height, w = width, step = h / n
        const css = (c, a) => "rgba(" + Math.round(c.r * 255) + "," + Math.round(c.g * 255) + "," + Math.round(c.b * 255) + "," + a + ")"
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
        let started = false
        for (let i = 0; i < n; i++) {
          const e = map.set[i].energy || 0
          if (!e) continue
          const x = (w - 12) * (1 - (e - 1) / 9) + 2, y = (i + 0.5) * step
          if (!started) { g.moveTo(x, y); started = true } else g.lineTo(x, y)
        }
        g.stroke()
      }
      Connections { target: root; function onDeckChanged() { paint.requestPaint() } }
      onWidthChanged: requestPaint()
      onHeightChanged: requestPaint()
    }
    // What you can see.
    Rectangle {
      readonly property real total: Math.max(1, map.list.contentHeight)
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
    color: rbHover.hovered ? Qt.rgba(1, 1, 1, 0.08) : "transparent"
    Label {
      anchors.centerIn: parent
      text: rb.glyph
      font.family: "Iosevka Nerd Font Propo"
      color: rb.on ? root.amber : root.ink
      opacity: rbHover.hovered || rb.on ? 1 : 0.6
    }
    HoverHandler { id: rbHover; cursorShape: Qt.PointingHandCursor }
    TapHandler { onTapped: rb.clicked() }
  }
}
