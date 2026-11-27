import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Services.Mpris
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Mini player over MPRIS: whatever is playing (Beatport in Chrome, Spotify, a
// video), with a seek bar and a way back to wherever it plays. A home-made plugin can't
// borrow Omarchy's media service, so it reads Quickshell's player list itself.
Column {
  id: root
  property var host: null
  spacing: Style.space(18)

  readonly property color amber: Commons.Color.accent
  readonly property color teal: host ? host.themeCyan : Commons.Color.foreground

  // Playing beats paused; among those, one with a title.
  readonly property var player: {
    const list = Mpris.players ? Mpris.players.values : []
    let best = null, bestScore = -1
    for (const candidate of list) {
      if (!candidate) continue
      const score = (candidate.isPlaying ? 2 : 0) + (candidate.trackTitle ? 1 : 0)
      if (score > bestScore) { best = candidate; bestScore = score }
    }
    return best
  }
  readonly property bool hasTrack: !!player && !!(player.trackTitle || player.trackArtist)

  // MPRIS doesn't push the playhead; ask for it while the tab is up.
  property real position: 0
  Timer {
    interval: 1000
    repeat: true
    triggeredOnStart: true
    running: root.hasTrack && root.visible
    onTriggered: {
      if (!root.player) return
      root.player.positionChanged()
      root.position = root.player.position
    }
  }

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("../i18n") }

  // Speaker or headphones, first: it's what you reach for before pressing play.
  OutputSwitch { id: output; width: parent.width; host: root.host }

  function clock(seconds) {
    if (!(seconds >= 0) || !isFinite(seconds)) return "–:––"
    const total = Math.floor(seconds)
    const m = Math.floor(total / 60), s = total % 60
    return m + ":" + (s < 10 ? "0" : "") + s
  }

  // Chrome's tabs (Beatport, YouTube Music, YouTube) share one media player
  // to the system, which can pick the wrong tab; afterlight's add-on knows
  // which one you're listening to. Other apps get the usual controls.
  function control(action) {
    if (!player) return
    if (player.identity === "Chrome") {
      Quickshell.execDetached([tool, "media", action])
      return
    }
    if (action === "previous") player.previous()
    else if (action === "next") player.next()
    else player.togglePlaying()
  }
  readonly property var source: host ? host.musicSourceInfo : ({ name: "Beatport", icon: "󰝚" })

  // ---- Liked tracks: saved with the heart (or Super+Alt+H), for hearting
  // on Beatport later.
  readonly property string tool: host ? host.afterlightPath : ""
  property var liked: []
  Commons.WatchedFile {
    path: Quickshell.env("HOME") + "/.local/state/afterlight/liked.json"
    onTextChanged: { try { const v = JSON.parse(text); root.liked = Array.isArray(v) ? v : [] } catch (error) { root.liked = [] } }
  }
  property string addingId: ""
  function addToHeart(id) {
    addingId = id
    addingDone.restart()
    Quickshell.execDetached([tool, "like", "add", id])
  }
  // liked.json changes when it lands; the OSD says if it couldn't.
  Timer { id: addingDone; interval: 40000; onTriggered: root.addingId = "" }
  onLikedChanged: addingId = ""
  readonly property bool currentLiked: hasTrack && liked.some(i =>
    i.title.toLowerCase() === String(player.trackTitle || "").toLowerCase()
    && i.artist.toLowerCase() === String(player.trackArtist || "").toLowerCase())
  readonly property int toAdd: liked.filter(i => !i.added).length
  function likeAction(args) { Quickshell.execDetached([tool, "like"].concat(args)) }

  // ---- Now playing: one group, so the gap above its title is wider than inside it.
  // The laptop's player: hidden while a Sonos room plays (the Deck moved
  // there, or you picked it above, which shows what the room plays); it's
  // back when you pick the laptop's speaker or headphones again.
  Column {
  width: parent.width
  spacing: Style.space(10)
  visible: !output.sonosOn

  Section {
    width: parent.width
    title: root.hasTrack && root.player.isPlaying ? strings.t("player.nowPlaying") : strings.t("player.title")
    amber: root.amber
    teal: root.teal
  }

  // ---- Nothing playing
  Column {
    width: parent.width
    spacing: Style.space(4)
    visible: !root.hasTrack
    Label { text: strings.t("player.nothing"); font.bold: true; color: root.teal }
    Label { width: parent.width; wrapMode: Text.WordWrap; elide: Text.ElideNone; opacity: 0.65; text: strings.t("player.nothingHint") }
  }

  // ---- Now playing: artwork framed in the border gradient
  RowLayout {
    width: parent.width
    spacing: Style.space(12)
    visible: root.hasTrack

    Rectangle {
      Layout.preferredWidth: Style.space(92)
      Layout.preferredHeight: Style.space(92)
      gradient: Gradient {
        orientation: Gradient.Horizontal
        GradientStop { position: 0; color: root.amber }
        GradientStop { position: 1; color: root.teal }
      }
      Rectangle {
        anchors.fill: parent
        anchors.margins: 1
        color: "black"
        clip: true
        SizedImage {
          anchors.fill: parent
          crop: true
          url: root.player && root.player.trackArtUrl ? root.player.trackArtUrl : ""
          visible: url !== ""
        }
        Label {
          anchors.centerIn: parent
          visible: !root.player || !root.player.trackArtUrl
          text: "󰎆"
          font.pixelSize: Style.font.icon * 1.6
          color: root.amber
          opacity: 0.6
        }
      }
    }

    ColumnLayout {
      Layout.fillWidth: true
      spacing: Style.space(3)
      Label {
        Layout.fillWidth: true
        text: root.player ? root.player.trackTitle || "" : ""
        font.bold: true
        font.pixelSize: Style.font.subtitle
        color: root.amber
      }
      Label {
        Layout.fillWidth: true
        text: root.player ? root.player.trackArtist || "" : ""
      }
      Label {
        Layout.fillWidth: true
        opacity: 0.55
        font.pixelSize: Style.font.caption
        text: {
          if (!root.player) return ""
          // The app it's coming from, not just "Chrome".
          const album = root.player.trackAlbum || ""
          const source = root.player.identity === "Chrome" || !root.player.identity ? root.source.name : root.player.identity
          return album && source ? album + " · " + source : album || source
        }
      }
    }
  }

  // ---- Seek: click or drag to move, when the player allows it.
  Column {
    width: parent.width
    spacing: Style.space(2)
    visible: root.hasTrack && root.player.lengthSupported && root.player.length > 0

    ThemedSlider {
      width: parent.width
      minimum: 0
      maximum: root.player && root.player.length > 0 ? root.player.length : 1
      value: root.position
      step: 1
      fromColor: root.amber
      toColor: root.teal
      enabled: !!root.player && root.player.canSeek
      onCommitted: function(v) {
        if (!root.player || !root.player.canSeek) return
        root.player.position = v
        root.position = v
      }
    }
    RowLayout {
      width: parent.width
      Label { Layout.fillWidth: true; text: root.clock(root.position); font.pixelSize: Style.font.caption; color: root.amber }
      Label { text: root.clock(root.player ? root.player.length : -1); font.pixelSize: Style.font.caption; opacity: 0.6 }
    }
  }

  // ---- Controls: ⏮  ( ⏯ )  ⏭  ............  OPEN <SOURCE>
  RowLayout {
    width: parent.width
    spacing: Style.space(8)

    ActionButton {
      visible: root.hasTrack
      icon: "󰒮"
      tone: Commons.Color.popups.text
      enabled: !!root.player && root.player.canGoPrevious
      onClicked: root.control("previous")
    }
    Rectangle {
      visible: root.hasTrack
      implicitWidth: Style.space(38)
      implicitHeight: Style.space(38)
      radius: width / 2
      color: playHover.hovered ? Qt.rgba(root.amber.r, root.amber.g, root.amber.b, 0.25) : Qt.rgba(root.amber.r, root.amber.g, root.amber.b, 0.12)
      border.width: 1
      border.color: root.amber
      Label {
        anchors.centerIn: parent
        text: root.player && root.player.isPlaying ? "󰏤" : "󰐊"
        font.pixelSize: Style.font.icon * 1.2
        color: root.amber
      }
      HoverHandler { id: playHover; cursorShape: Qt.PointingHandCursor }
      TapHandler { onTapped: root.control("toggle") }
    }
    ActionButton {
      visible: root.hasTrack
      icon: "󰒭"
      tone: Commons.Color.popups.text
      enabled: !!root.player && root.player.canGoNext
      onClicked: root.control("next")
    }
    ActionButton {
      visible: root.hasTrack
      icon: root.currentLiked ? "󰋑" : "󰋕"
      tone: root.currentLiked ? Commons.Color.urgent : root.amber
      onClicked: if (!root.currentLiked) root.likeAction(["now"])
    }
    Item { Layout.fillWidth: true }
    // Opens whichever app the music is coming from.
    ActionButton {
      icon: root.source.icon
      text: strings.t("player.openSource").arg(root.source.name)
      tone: root.teal
      onClicked: if (root.host) root.host.openMusicSource()
    }
  }
  }

  // ---- Beatport: genre Top 100s and your playlists, opened in the Beatport app
  // The chart list lives in afterlight (BEATPORT_GENRES), shared with voice.
  readonly property var genres: host && host.afterState && host.afterState.beatportGenres
    ? host.afterState.beatportGenres : []
  readonly property var pins: host && host.afterState && host.afterState.settings.beatport
    ? host.afterState.settings.beatport.pins : []
  // Playlists the Baseline for Beatport extension read from Beatport's sidebar.
  property var bpPlaylists: []
  Commons.WatchedFile {
    path: Quickshell.env("HOME") + "/.local/state/afterlight/beatport.json"
    onTextChanged: {
      try {
        const v = JSON.parse(text)
        root.bpPlaylists = v && Array.isArray(v.playlists) ? v.playlists : []
      } catch (error) { root.bpPlaylists = [] }
    }
  }
  // The extension loads the page in the open Beatport window and presses
  // Play, so Baseline stays open and nothing moves.
  property string loadingUrl: ""
  function openPage(url) {
    loadingUrl = url
    loadingClear.restart()
    Quickshell.execDetached([tool, "beatport", "play", url])
  }
  Timer { id: loadingClear; interval: 4000; onTriggered: root.loadingUrl = "" }

  component Chip: Rectangle {
    id: chip
    property string text: ""
    property color tone: root.teal
    property bool removable: false
    property string url: ""
    readonly property bool loading: url !== "" && url === root.loadingUrl
    signal clicked()
    signal removed()
    implicitWidth: chipRow.implicitWidth + Style.space(12)
    implicitHeight: chipRow.implicitHeight + Style.space(6)
    radius: Style.cornerRadius > 0 ? Style.space(3) : 0
    color: chipHover.hovered ? Qt.rgba(tone.r, tone.g, tone.b, 0.18) : Qt.rgba(1, 1, 1, 0.03)
    border.width: 1
    border.color: Qt.rgba(tone.r, tone.g, tone.b, chipHover.hovered || loading ? 0.8 : 0.35)
    Row {
      id: chipRow
      anchors.centerIn: parent
      spacing: Style.space(6)
      Label {
        text: (chip.loading ? "󰐊  " : "") + chip.text
        textFormat: Text.PlainText
        font.family: "Iosevka Nerd Font Propo"
        font.pixelSize: Style.font.caption
        color: chipHover.hovered || chip.loading ? chip.tone : Commons.Color.popups.text
      }
      Label {
        visible: chip.removable
        text: "󰅖"
        font.family: "Iosevka Nerd Font Propo"
        font.pixelSize: Style.font.caption
        opacity: removeHover.hovered ? 1 : 0.4
        HoverHandler { id: removeHover; cursorShape: Qt.PointingHandCursor }
        TapHandler { onTapped: chip.removed() }
      }
    }
    HoverHandler { id: chipHover; cursorShape: Qt.PointingHandCursor }
    TapHandler { onTapped: chip.clicked() }
  }

  // ---- Find music: search YouTube Music or Apple Music, play it in that
  // service's window. The service picked here is also where "play …" said
  // to OmaRelay looks (settings music.service).
  readonly property string savedService: host && host.afterState && host.afterState.settings.music
    ? host.afterState.settings.music.service || "ytmusic" : "ytmusic"
  property string pickedService: ""
  readonly property string service: pickedService !== "" ? pickedService : savedService
  function pickService(name) {
    if (name === service) return
    pickedService = name
    ytResults = []
    Quickshell.execDetached([tool, "set", "music.service", name])
    if (ytQuery.text.trim() !== "") ytFind(ytQuery.text)
  }
  property var ytResults: []
  property bool ytSearching: false
  property string ytPlaying: ""
  property var ytPlaylists: []
  Process {
    id: ytSearch
    onRunningChanged: root.ytSearching = running
    onExited: if (root.ytPending !== "") { const q = root.ytPending; root.ytPending = ""; root.ytFind(q) }
    stdout: StdioCollector {
      onStreamFinished: { try { const v = JSON.parse(text); root.ytResults = Array.isArray(v) ? v : [] } catch (error) { root.ytResults = [] } }
    }
  }
  Commons.WatchedFile {
    path: Quickshell.env("HOME") + "/.local/state/afterlight/ytmusic.json"
    onTextChanged: {
      try { const v = JSON.parse(text); root.ytPlaylists = v && Array.isArray(v.playlists) ? v.playlists : [] }
      catch (error) { root.ytPlaylists = [] }
    }
  }
  // Refreshes from your library at most once a day.
  Process { id: ytPlaylistReader; command: [root.tool, "ytmusic", "playlists"] }
  Component.onCompleted: ytPlaylistReader.running = true
  property string ytPending: ""
  function ytFind(query) {
    if (query.trim() === "") { ytResults = []; return }
    // A search typed while one is running goes next, not nowhere.
    if (ytSearch.running) { ytPending = query.trim(); return }
    ytSearch.command = [tool, service, "search", query.trim()]
    ytSearch.running = true
  }
  function ytPlay(item) {
    ytPlaying = item.kind + item.title
    ytPlayingClear.restart()
    Quickshell.execDetached([tool, item.service || service, "play", JSON.stringify(item)])
  }
  Timer { id: ytPlayingClear; interval: 6000; onTriggered: root.ytPlaying = "" }

  // ---- Suggestions: when "play …" (said or typed) has no clear match, nothing
  // plays; the closest results show here at once and Grok's ideas follow.
  property var suggestion: null
  Commons.WatchedFile {
    path: Quickshell.env("HOME") + "/.local/state/afterlight/suggest.json"
    onTextChanged: {
      try {
        const v = JSON.parse(text)
        root.suggestion = v && typeof v.at === "number" && Date.now() / 1000 - v.at < 1800 ? v : null
      } catch (error) { root.suggestion = null }
    }
  }
  function askGrok(query) {
    if (query.trim() === "") return
    Quickshell.execDetached([tool, "music", "suggest", service, query.trim()])
  }
  function trySearch(words) {
    ytQuery.text = words
    if (root.suggestion && root.suggestion.service) pickedService = root.suggestion.service
    ytFind(words)
  }
  component SuggestRow: Rectangle {
    id: sRow
    property var item: ({})
    property string service: "ytmusic"
    property bool fromGrok: false
    readonly property bool starting: root.ytPlaying === item.kind + item.title
    width: parent ? parent.width : 0
    implicitHeight: sRowLayout.implicitHeight + Style.space(6)
    radius: Style.cornerRadius > 0 ? Style.space(3) : 0
    color: sHover.hovered || starting ? Qt.rgba(root.amber.r, root.amber.g, root.amber.b, 0.12) : "transparent"
    RowLayout {
      id: sRowLayout
      anchors.verticalCenter: parent.verticalCenter
      x: Style.space(4)
      width: parent.width - Style.space(8)
      spacing: Style.space(8)
      Rectangle {
        Layout.preferredWidth: Style.space(34)
        Layout.preferredHeight: Style.space(34)
        radius: Style.cornerRadius > 0 ? Style.space(2) : 0
        color: Qt.rgba(1, 1, 1, 0.05)
        clip: true
        Image {
          anchors.fill: parent
          fillMode: Image.PreserveAspectCrop
          asynchronous: true
          source: /^https:\/\//.test(sRow.item.thumb || "") ? sRow.item.thumb : ""
        }
        Label {
          anchors.centerIn: parent
          visible: !(sRow.item.thumb)
          text: sRow.starting ? "󰐊" : (root.ytIcons[sRow.item.kind] || "󰎈")
          font.family: "Iosevka Nerd Font Propo"
          color: sRow.fromGrok ? root.amber : root.teal
        }
      }
      ColumnLayout {
        Layout.fillWidth: true
        spacing: 0
        Label {
          Layout.fillWidth: true
          text: sRow.item.title || ""
          textFormat: Text.PlainText
          elide: Text.ElideRight
          font.pixelSize: Style.font.caption
          font.bold: true
        }
        Label {
          Layout.fillWidth: true
          text: strings.t("ytmusic.kind." + sRow.item.kind) + (sRow.item.subtitle ? " · " + sRow.item.subtitle : "")
          textFormat: Text.PlainText
          elide: Text.ElideRight
          font.pixelSize: Style.font.caption
          opacity: 0.65
        }
        Label {
          Layout.fillWidth: true
          visible: !!sRow.item.why
          text: sRow.item.why || ""
          textFormat: Text.PlainText
          elide: Text.ElideRight
          font.pixelSize: Style.font.caption
          color: root.amber
        }
      }
    }
    HoverHandler { id: sHover; cursorShape: Qt.PointingHandCursor }
    TapHandler { onTapped: root.ytPlay(Object.assign({}, sRow.item, { service: sRow.service })) }
  }
  readonly property var ytIcons: ({ song: "󰎈", video: "󰗃", album: "󰀥", artist: "󰠃", playlist: "󰲸" })

  Column {
    width: parent.width
    spacing: Style.space(8)
    Section { width: parent.width; title: strings.t("music.title"); amber: root.amber; teal: root.teal }
    Row {
      spacing: Style.space(6)
      Repeater {
        model: [{ id: "ytmusic", name: "YouTube Music", icon: "󰗃" }, { id: "applemusic", name: "Apple Music", icon: "󰀵" }]
        delegate: Chip {
          required property var modelData
          text: modelData.icon + "  " + modelData.name
          tone: root.service === modelData.id ? root.amber : root.teal
          border.color: root.service === modelData.id ? root.amber : Qt.rgba(tone.r, tone.g, tone.b, 0.35)
          onClicked: root.pickService(modelData.id)
        }
      }
      Chip {
        text: "󰲸  " + strings.t("deck.open")
        tone: root.amber
        onClicked: if (root.host) root.host.openDeck()
      }
    }
    RowLayout {
      width: parent.width
      spacing: Style.space(6)
      Rectangle {
        Layout.fillWidth: true
        implicitHeight: ytQuery.implicitHeight + Style.space(10)
        radius: Style.cornerRadius > 0 ? Style.space(3) : 0
        color: Qt.rgba(1, 1, 1, 0.05)
        border.width: 1
        border.color: ytQuery.activeFocus ? root.amber : Qt.rgba(1, 1, 1, 0.15)
        TextInput {
          id: ytQuery
          anchors.verticalCenter: parent.verticalCenter
          x: Style.space(8)
          width: parent.width - Style.space(16)
          color: Commons.Color.popups.text
          font.family: Style.font.family
          font.pixelSize: Style.font.body
          clip: true
          onAccepted: root.ytFind(text)
          Text {
            visible: ytQuery.text === ""
            text: strings.t(root.service === "applemusic" ? "applemusic.search" : "ytmusic.search")
            textFormat: Text.PlainText
            color: Commons.Color.popups.text
            opacity: 0.4
            font: ytQuery.font
          }
        }
        TapHandler { onTapped: ytQuery.forceActiveFocus() }
      }
      ActionButton {
        icon: root.ytSearching ? "󰔟" : "󰍉"
        tone: root.amber
        onClicked: root.ytFind(ytQuery.text)
      }
      ActionButton {
        visible: root.ytResults.length > 0
        icon: "󰅖"
        tone: Commons.Color.popups.text
        onClicked: { root.ytResults = []; ytQuery.text = "" }
      }
    }
    Repeater {
      model: root.ytResults.slice(0, 10)
      delegate: Rectangle {
        id: ytRow
        required property var modelData
        readonly property bool starting: root.ytPlaying === modelData.kind + modelData.title
        width: parent ? parent.width : 0
        implicitHeight: ytRowLayout.implicitHeight + Style.space(6)
        radius: Style.cornerRadius > 0 ? Style.space(3) : 0
        color: ytHover.hovered || starting ? Qt.rgba(root.amber.r, root.amber.g, root.amber.b, 0.12) : "transparent"
        RowLayout {
          id: ytRowLayout
          anchors.verticalCenter: parent.verticalCenter
          x: Style.space(4)
          width: parent.width - Style.space(8)
          spacing: Style.space(8)
          Label {
            text: ytRow.starting ? "󰐊" : (root.ytIcons[ytRow.modelData.kind] || "󰎈")
            font.family: "Iosevka Nerd Font Propo"
            font.pixelSize: Style.font.iconLarge
            color: ytRow.modelData.top ? root.amber : root.teal
            Layout.preferredWidth: Style.font.iconLarge * 1.4
          }
          ColumnLayout {
            Layout.fillWidth: true
            spacing: 0
            Label {
              Layout.fillWidth: true
              text: ytRow.modelData.title
              textFormat: Text.PlainText
              elide: Text.ElideRight
              font.pixelSize: Style.font.caption
              font.bold: true
              color: ytRow.modelData.top ? root.amber : Commons.Color.popups.text
            }
            Label {
              Layout.fillWidth: true
              text: strings.t("ytmusic.kind." + ytRow.modelData.kind) + (ytRow.modelData.subtitle ? " · " + ytRow.modelData.subtitle : "")
              textFormat: Text.PlainText
              elide: Text.ElideRight
              font.pixelSize: Style.font.caption
              opacity: 0.65
            }
          }
        }
        HoverHandler { id: ytHover; cursorShape: Qt.PointingHandCursor }
        TapHandler { onTapped: root.ytPlay(ytRow.modelData) }
      }
    }
    Chip {
      visible: ytQuery.text.trim() !== "" && !root.ytSearching
      text: "✦  " + strings.t("suggest.ask")
      tone: root.amber
      onClicked: root.askGrok(ytQuery.text)
    }
    Column {
      width: parent.width
      spacing: Style.space(4)
      visible: !!root.suggestion
      RowLayout {
        width: parent.width
        Label {
          Layout.fillWidth: true
          text: root.suggestion ? strings.t("suggest.none").arg(root.suggestion.query) : ""
          textFormat: Text.PlainText
          wrapMode: Text.Wrap
          font.pixelSize: Style.font.caption
          color: root.amber
        }
        ActionButton {
          icon: "󰅖"
          tone: Commons.Color.popups.text
          onClicked: { root.suggestion = null; Quickshell.execDetached([root.tool, "music", "clear"]) }
        }
      }
      Label {
        visible: !!root.suggestion && root.suggestion.close.length > 0
        text: strings.t("suggest.closest")
        font.pixelSize: Style.font.caption
        opacity: 0.6
      }
      Repeater {
        model: root.suggestion ? root.suggestion.close.slice(0, 5) : []
        delegate: SuggestRow {
          required property var modelData
          item: modelData
          service: root.suggestion.service
        }
      }
      Label {
        visible: !!root.suggestion && (root.suggestion.pending || root.suggestion.grok.length > 0)
        text: root.suggestion && root.suggestion.pending ? "✦  " + strings.t("suggest.grokWaiting") : "✦  " + strings.t("suggest.grok")
        font.family: "Iosevka Nerd Font Propo"
        font.pixelSize: Style.font.caption
        color: root.amber
      }
      Repeater {
        model: root.suggestion ? root.suggestion.grok : []
        delegate: SuggestRow {
          required property var modelData
          item: modelData
          service: root.suggestion.service
          fromGrok: true
        }
      }
      Flow {
        width: parent.width
        spacing: Style.space(6)
        visible: !!root.suggestion && root.suggestion["try"].length > 0
        Repeater {
          model: root.suggestion ? root.suggestion["try"] : []
          delegate: Chip {
            required property var modelData
            text: "󰍉  " + modelData
            tone: root.amber
            onClicked: root.trySearch(modelData)
          }
        }
      }
    }
    Flow {
      width: parent.width
      spacing: Style.space(6)
      visible: root.ytPlaylists.length > 0 && root.service === "ytmusic"
      Repeater {
        model: root.ytPlaylists
        delegate: Chip {
          required property var modelData
          text: modelData.name
          tone: root.teal
          onClicked: root.ytPlay({ service: "ytmusic", kind: "playlist", title: modelData.name, playlist: modelData.playlist, video: "", browse: "", subtitle: "" })
        }
      }
    }
  }

  Column {
    width: parent.width
    spacing: Style.space(8)
    Section { width: parent.width; title: strings.t("beatport.top100"); amber: root.amber; teal: root.teal }
    Flow {
      width: parent.width
      spacing: Style.space(6)
      Repeater {
        model: root.genres
        delegate: Chip {
          required property var modelData
          text: modelData.name
          tone: root.amber
          url: "https://www.beatport.com/" + modelData.path
          onClicked: root.openPage(url)
        }
      }
    }
  }

  Column {
    width: parent.width
    spacing: Style.space(8)
    Section { width: parent.width; title: strings.t("beatport.playlists"); amber: root.amber; teal: root.teal }
    Flow {
      width: parent.width
      spacing: Style.space(6)
      Repeater {
        model: root.bpPlaylists
        delegate: Chip {
          required property var modelData
          text: modelData.name
          url: modelData.url
          onClicked: root.openPage(url)
        }
      }
      Chip {
        visible: root.bpPlaylists.length === 0
        text: "󰋑  " + strings.t("beatport.mine")
        url: "https://www.beatport.com/library/playlists"
        onClicked: root.openPage(url)
      }
      Repeater {
        model: root.pins
        delegate: Chip {
          required property var modelData
          text: modelData.name
          url: modelData.url
          removable: true
          onClicked: root.openPage(url)
          onRemoved: Quickshell.execDetached([root.tool, "beatport", "unpin", modelData.url])
        }
      }
      Chip {
        text: "+  " + strings.t("beatport.pin")
        tone: root.amber
        onClicked: { Quickshell.execDetached([root.tool, "beatport", "pin"]); pinRefresh.start() }
      }
    }
    Timer { id: pinRefresh; interval: 800; onTriggered: if (root.host) root.host.refreshAfterlight() }
  }

  // ---- Liked
  Column {
    width: parent.width
    spacing: Style.space(8)
    visible: root.liked.length > 0
    Section {
      width: parent.width
      title: root.toAdd > 0 ? strings.t("liked.titleToAdd").arg(Commons.I18n.formatNumber(root.toAdd)) : strings.t("liked.title")
      amber: root.amber; teal: root.teal
    }
    Repeater {
      model: root.liked.slice(0, 8)
      delegate: RowLayout {
        id: likedRow
        required property var modelData
        width: parent ? parent.width : 0
        spacing: Style.space(8)
        opacity: modelData.added ? 0.5 : 1
        Rectangle {
          Layout.preferredWidth: Style.space(30)
          Layout.preferredHeight: Style.space(30)
          color: "black"
          radius: Style.cornerRadius > 0 ? Style.space(2) : 0
          clip: true
          SizedImage { anchors.fill: parent; crop: true; url: likedRow.modelData.art ? "file://" + likedRow.modelData.art : ""; visible: url !== "" }
          Label { anchors.centerIn: parent; visible: !likedRow.modelData.art; text: "󰋑"; font.family: "Iosevka Nerd Font Propo"; color: Commons.Color.urgent }
        }
        ColumnLayout {
          Layout.fillWidth: true
          spacing: 0
          Label { Layout.fillWidth: true; text: likedRow.modelData.title; font.pixelSize: Style.font.caption; font.bold: true; color: root.amber }
          Label { Layout.fillWidth: true; text: likedRow.modelData.artist; font.pixelSize: Style.font.caption; opacity: 0.7 }
        }
        // Find it on Beatport and add it to <3 from a background tab.
        ActionButton {
          visible: !likedRow.modelData.added
          readonly property bool working: root.addingId === likedRow.modelData.id
          icon: working ? "󰔟" : "󰐕"
          tone: root.amber
          enabled: root.addingId === ""
          onClicked: root.addToHeart(likedRow.modelData.id)
        }
        ActionButton {
          icon: likedRow.modelData.added ? "󰄬" : "󰄱"
          tone: likedRow.modelData.added ? root.teal : Commons.Color.popups.text
          onClicked: root.likeAction([likedRow.modelData.added ? "unadded" : "added", likedRow.modelData.id])
        }
        ActionButton {
          icon: "󰅖"
          tone: Commons.Color.popups.text
          onClicked: root.likeAction(["remove", likedRow.modelData.id])
        }
      }
    }
  }
}
