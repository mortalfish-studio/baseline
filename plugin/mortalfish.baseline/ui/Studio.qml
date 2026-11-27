import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Baseline Studio: a window of its own for the slower work. The library of
// every picture and which looks use it, the look maker (tune a look's colours
// on a live preview, or start a new one, from scratch or inspired by a
// picture, and share it), and the catalog of looks others have shared.
Item {
  id: root
  property var host: null
  property string page: "library"
  signal closed()

  readonly property string tool: host ? host.afterlightPath : ""
  readonly property color amber: Commons.Color.accent
  readonly property color teal: host ? host.themeCyan : Commons.Color.foreground
  readonly property color ground: Commons.Color.background
  readonly property color ink: Commons.Color.popups.text

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("../i18n") }

  function show(which) {
    if (which) page = which
    window.visible = true
    library.read()
  }

  // ------------------------------------------------------------ data
  QtObject {
    id: library
    property var data: null
    readonly property var items: data ? data.items : []
    readonly property var looks: data ? data.looks : []
    function read() { if (!libraryReader.running) libraryReader.running = true }
    function lookById(id) { for (const l of looks) if (l.id === id) return l; return null }
  }
  Process {
    id: libraryReader
    command: [root.tool, "library"]
    stdout: StdioCollector { onStreamFinished: { try { library.data = JSON.parse(text) } catch (error) {} } }
  }

  // One queue for every change, so clicks never race each other.
  property var queue: []
  property string status: ""
  property bool busy: runner.running
  function run(args, then) {
    queue = queue.concat([{ args: args, then: then || null }])
    if (!runner.running) next()
  }
  function next() {
    if (queue.length === 0) { library.read(); if (host) host.refresh(); return }
    const job = queue[0]
    queue = queue.slice(1)
    runner.job = job
    runner.command = [tool].concat(job.args)
    runner.running = true
  }
  Process {
    id: runner
    property var job: null
    stdout: StdioCollector { id: runOut }
    stderr: StdioCollector { id: runErr }
    onExited: function(code) { Qt.callLater(root.finish, code) }
  }
  function finish(code) {
    const job = runner.job
    if (code !== 0) root.status = runErr.text.trim().split("\n").pop() || strings.t("studio.failed")
    else if (job && job.then) job.then(runOut.text.trim())
    next()
  }

  FloatingWindow {
    id: window
    title: "Baseline Studio"
    visible: false
    color: root.ground
    implicitWidth: 1240
    implicitHeight: 840
    minimumSize: Qt.size(980, 680)
    onVisibleChanged: if (!visible) root.closed()

    Item {
      anchors.fill: parent
      focus: true
      Keys.onEscapePressed: window.visible = false

      // A faint neon horizon behind everything, in the look's colours.
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
        spacing: 16

        // ---- header: brand, pages, close
        RowLayout {
          Layout.fillWidth: true
          spacing: 18
          ColumnLayout {
            spacing: 2
            Label {
              text: strings.t("studio.brand")
              font.pixelSize: Style.font.caption
              font.letterSpacing: 4
              color: root.amber
            }
            Label {
              text: strings.t("studio.title").toUpperCase()
              font.pixelSize: 22
              font.bold: true
              font.letterSpacing: 3
              color: root.teal
            }
          }
          Item { Layout.fillWidth: true }
          Repeater {
            model: [{ value: "library", icon: "󰸉" }, { value: "looks", icon: "󰏘" }, { value: "browse", icon: "󰖟" }]
            delegate: Item {
              id: pageTab
              required property var modelData
              readonly property bool on: root.page === modelData.value
              implicitWidth: pageRow.implicitWidth + 28
              implicitHeight: pageRow.implicitHeight + 16
              Row {
                id: pageRow
                anchors.centerIn: parent
                spacing: 8
                Label { text: pageTab.modelData.icon; font.family: "Iosevka Nerd Font Propo"; font.pixelSize: Style.font.iconLarge; color: pageTab.on ? root.amber : root.ink; opacity: pageTab.on || pageHover.hovered ? 1 : 0.6 }
                Label { anchors.verticalCenter: parent.verticalCenter; text: strings.t("studio." + pageTab.modelData.value).toUpperCase(); font.letterSpacing: 2; font.bold: pageTab.on; color: pageTab.on ? root.amber : root.ink; opacity: pageTab.on || pageHover.hovered ? 1 : 0.6 }
              }
              Rectangle {
                anchors.bottom: parent.bottom
                anchors.horizontalCenter: parent.horizontalCenter
                width: pageTab.on ? pageRow.implicitWidth + 8 : 0
                height: 2
                color: root.amber
                Behavior on width { NumberAnimation { duration: Style.duration(180); easing.type: Easing.Bezier; easing.bezierCurve: Style.easeOut } }
              }
              HoverHandler { id: pageHover; cursorShape: Qt.PointingHandCursor }
              TapHandler { onTapped: root.page = pageTab.modelData.value }
            }
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

        StackLayout {
          Layout.fillWidth: true
          Layout.fillHeight: true
          currentIndex: root.page === "looks" ? 1 : root.page === "browse" ? 2 : 0
          LibraryPage {}
          LooksPage {}
          BrowsePage {}
        }

        // Status line: what just went wrong, or what's busy.
        RowLayout {
          Layout.fillWidth: true
          spacing: 8
          Label {
            visible: root.busy
            text: "󰔟"
            color: root.teal
            RotationAnimation on rotation { running: root.busy && !Style.reduceMotion; loops: Animation.Infinite; from: 0; to: 360; duration: 1200 }
          }
          Label {
            Layout.fillWidth: true
            text: root.status
            color: Commons.Color.urgent
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }

  // ================================================================ Library
  component LibraryPage: Item {
    id: lib
    property string filter: "all"      // all | <look id> | extra
    property var addTo: []              // looks new pictures join
    readonly property var shown: library.items.filter(function(item) {
      if (lib.filter === "all") return true
      if (lib.filter === "extra") return item.owner === "extra"
      const use = item.looks[lib.filter]
      return item.owner === lib.filter || (use && (use.day || use.night))
    })
    function add(sources) {
      const looks = addTo.length ? ["--looks", addTo.join(",")] : []
      root.status = ""
      root.run(["wallpaper", "add"].concat(sources).concat(looks))
    }

    RowLayout {
      anchors.fill: parent
      spacing: 20

      // ---- filter rail
      ColumnLayout {
        Layout.preferredWidth: 230
        Layout.maximumWidth: 230
        Layout.fillWidth: false
        Layout.fillHeight: true
        spacing: 6
        SectionTitle { text: strings.t("studio.show") }
        Repeater {
          model: [{ id: "all", name: strings.t("studio.allPictures") }].concat(library.looks.map(function(l) { return { id: l.id, name: l.name, look: l } })).concat([{ id: "extra", name: strings.t("studio.yourOwn") }])
          delegate: Rectangle {
            id: railItem
            required property var modelData
            readonly property bool on: lib.filter === modelData.id
            readonly property var p: modelData.look ? modelData.look.palette : null
            Layout.fillWidth: true
            implicitHeight: 38
            radius: 4
            color: on ? Util.alpha(root.amber, 0.12) : railHover.hovered ? Qt.rgba(1, 1, 1, 0.05) : "transparent"
            border.width: on ? 1 : 0
            border.color: Util.alpha(root.amber, 0.5)
            RowLayout {
              anchors.fill: parent
              anchors.leftMargin: 12
              anchors.rightMargin: 12
              spacing: 8
              Row {
                spacing: 3
                visible: !!railItem.p
                Repeater {
                  model: railItem.p ? [railItem.p.accent, railItem.p.cyan] : []
                  Rectangle { required property string modelData; width: 8; height: 8; radius: 4; color: modelData }
                }
              }
              Label { Layout.fillWidth: true; text: railItem.modelData.name; color: railItem.on ? root.amber : root.ink }
              Label {
                text: {
                  const id = railItem.modelData.id
                  if (id === "all") return String(library.items.length)
                  let n = 0
                  for (const it of library.items) {
                    if (id === "extra" ? it.owner === "extra" : (it.owner === id || (it.looks[id] && (it.looks[id].day || it.looks[id].night)))) n++
                  }
                  return String(n)
                }
                opacity: 0.45
                font.pixelSize: Style.font.caption
              }
            }
            HoverHandler { id: railHover; cursorShape: Qt.PointingHandCursor }
            TapHandler { onTapped: lib.filter = railItem.modelData.id }
          }
        }
        Item { Layout.fillHeight: true }

        // ---- add pictures
        SectionTitle { text: strings.t("studio.add") }
        Rectangle {
          id: dropWell
          Layout.fillWidth: true
          implicitHeight: 96
          radius: 6
          color: drop.containsDrag ? Util.alpha(root.amber, 0.14) : Qt.rgba(1, 1, 1, 0.03)
          border.width: 1
          border.color: drop.containsDrag ? root.amber : Qt.rgba(1, 1, 1, 0.14)
          Column {
            anchors.centerIn: parent
            spacing: 4
            Label { anchors.horizontalCenter: parent.horizontalCenter; text: "󰉍"; font.family: "Iosevka Nerd Font Propo"; font.pixelSize: Style.font.iconLarge; color: root.amber }
            Label { anchors.horizontalCenter: parent.horizontalCenter; text: strings.t("studio.drop"); font.pixelSize: Style.font.caption; opacity: 0.7 }
          }
          DropArea {
            id: drop
            anchors.fill: parent
            onDropped: function(event) {
              const urls = event.urls.map(function(u) { return u.toString() })
              if (urls.length) lib.add(urls)
              else if (event.text) lib.add([event.text.trim()])
            }
          }
        }
        RowLayout {
          Layout.fillWidth: true
          spacing: 6
          Rectangle {
            Layout.fillWidth: true
            implicitHeight: 30
            radius: 4
            color: Qt.rgba(1, 1, 1, 0.04)
            border.width: 1
            border.color: linkInput.activeFocus ? root.amber : Qt.rgba(1, 1, 1, 0.14)
            TextInput {
              id: linkInput
              anchors.verticalCenter: parent.verticalCenter
              x: 8
              width: parent.width - 16
              clip: true
              color: root.ink
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              onAccepted: if (text.trim() !== "") { lib.add([text.trim()]); text = "" }
              Text {
                visible: linkInput.text === ""
                text: strings.t("studio.link")
                color: root.ink
                opacity: 0.35
                font: linkInput.font
              }
            }
          }
          ActionButton {
            icon: "󰆒"
            tone: root.teal
            onClicked: {
              root.status = ""
              root.run(["wallpaper", "paste"].concat(lib.addTo.length ? ["--looks", lib.addTo.join(",")] : []))
            }
          }
        }
        Label { text: strings.t("studio.addTo"); font.pixelSize: Style.font.caption; opacity: 0.55 }
        Flow {
          Layout.fillWidth: true
          spacing: 5
          Repeater {
            model: library.looks
            delegate: Rectangle {
              id: addChip
              required property var modelData
              readonly property bool on: lib.addTo.indexOf(modelData.id) >= 0
              implicitWidth: addChipText.implicitWidth + 16
              implicitHeight: 24
              radius: 12
              color: on ? Util.alpha(modelData.palette.accent, 0.25) : "transparent"
              border.width: 1
              border.color: on ? modelData.palette.accent : Qt.rgba(1, 1, 1, 0.18)
              Label { id: addChipText; anchors.centerIn: parent; text: addChip.modelData.name; font.pixelSize: Style.font.caption; color: addChip.on ? addChip.modelData.palette.accent : root.ink }
              HoverHandler { cursorShape: Qt.PointingHandCursor }
              TapHandler {
                onTapped: {
                  const list = lib.addTo.slice()
                  const at = list.indexOf(addChip.modelData.id)
                  if (at >= 0) list.splice(at, 1); else list.push(addChip.modelData.id)
                  lib.addTo = list
                }
              }
            }
          }
        }
      }

      // ---- the grid
      ColumnLayout {
        Layout.fillWidth: true
        Layout.fillHeight: true
        spacing: 10
        RowLayout {
          Layout.fillWidth: true
          SectionTitle { text: strings.tn("studio.count", lib.shown.length).arg(Commons.I18n.formatNumber(lib.shown.length)) }
          Item { Layout.fillWidth: true }
          Label { text: strings.t("studio.legend"); font.pixelSize: Style.font.caption; opacity: 0.5 }
        }
        GridView {
          id: grid
          Layout.fillWidth: true
          Layout.fillHeight: true
          clip: true
          cellWidth: Math.floor(width / Math.max(1, Math.floor(width / 250)))
          cellHeight: 232
          model: lib.shown
          boundsBehavior: Flickable.StopAtBounds
          delegate: Item {
            id: card
            required property var modelData
            readonly property var owner: library.lookById(modelData.owner)
            width: grid.cellWidth
            height: grid.cellHeight
            Rectangle {
              anchors.fill: parent
              anchors.margins: 6
              radius: 6
              color: Qt.rgba(1, 1, 1, cardHover.hovered ? 0.06 : 0.03)
              border.width: 1
              border.color: cardHover.hovered ? Util.alpha(root.amber, 0.5) : Qt.rgba(1, 1, 1, 0.08)
              HoverHandler { id: cardHover }

              ColumnLayout {
                anchors.fill: parent
                anchors.margins: 8
                spacing: 6
                Rectangle {
                  Layout.fillWidth: true
                  Layout.preferredHeight: 118
                  radius: 4
                  color: "#000"
                  clip: true
                  SizedImage { anchors.fill: parent; crop: true; url: card.modelData.thumb ? "file://" + card.modelData.thumb : "" }
                  Rectangle {
                    visible: card.modelData.video
                    anchors.right: parent.right; anchors.top: parent.top; anchors.margins: 6
                    width: 22; height: 18; radius: 3; color: Qt.rgba(0, 0, 0, 0.6)
                    Label { anchors.centerIn: parent; text: "󰕧"; font.family: "Iosevka Nerd Font Propo"; color: "white" }
                  }
                  // Hover actions: make a look from it, or bin one of yours.
                  Row {
                    visible: cardHover.hovered
                    anchors.left: parent.left; anchors.bottom: parent.bottom; anchors.margins: 6
                    spacing: 6
                    IconChip {
                      glyph: "󰏘"
                      tip: strings.t("studio.inspire")
                      onClicked: { root.page = "looks"; root.looksPageInspire(card.modelData.id) }
                    }
                    IconChip {
                      visible: card.modelData.owner === "extra"
                      glyph: "󰆴"
                      tip: strings.t("studio.remove")
                      danger: true
                      onClicked: root.run(["wallpaper", "remove", card.modelData.id])
                    }
                  }
                }
                RowLayout {
                  Layout.fillWidth: true
                  spacing: 6
                  Label { Layout.fillWidth: true; text: card.modelData.name.replace(/^\d+-/, "").replace(/-/g, " "); font.pixelSize: Style.font.caption }
                  Label {
                    text: card.owner ? card.owner.name : strings.t("studio.yours")
                    font.pixelSize: Style.font.caption
                    color: card.owner ? card.owner.palette.accent : root.teal
                    opacity: 0.8
                  }
                }
                // Which looks use it: per look, a day half and a night half.
                Flow {
                  Layout.fillWidth: true
                  spacing: 5
                  Repeater {
                    model: library.looks
                    delegate: Item {
                      id: use
                      required property var modelData
                      readonly property var uses: card.modelData.looks[modelData.id] || ({ day: false, night: false })
                      readonly property color tone: modelData.palette.accent
                      implicitWidth: 46
                      implicitHeight: 24
                      Rectangle {
                        anchors.bottom: parent.bottom
                        width: parent.width; height: 2; radius: 1
                        color: use.tone
                        opacity: use.uses.day || use.uses.night ? 1 : 0.45
                      }
                      Row {
                        Repeater {
                          model: ["day", "night"]
                          Rectangle {
                            id: half
                            required property string modelData
                            readonly property bool on: use.uses[modelData]
                            width: 23; height: 20
                            radius: 3
                            color: on ? Util.alpha(use.tone, halfHover.hovered ? 0.55 : 0.4) : halfHover.hovered ? Qt.rgba(1, 1, 1, 0.08) : "transparent"
                            border.width: 1
                            border.color: on ? use.tone : Qt.rgba(1, 1, 1, 0.16)
                            Label {
                              anchors.centerIn: parent
                              text: half.modelData === "day" ? "󰖨" : "󰖔"
                              font.family: "Iosevka Nerd Font Propo"
                              font.pixelSize: Style.font.caption
                              color: half.on ? "white" : root.ink
                              opacity: half.on ? 1 : 0.35
                            }
                            HoverHandler { id: halfHover; cursorShape: Qt.PointingHandCursor }
                            PanelToolTip { visible: halfHover.hovered; text: use.modelData.name + " · " + strings.t("mode." + half.modelData) }
                            TapHandler {
                              onTapped: {
                                // Show it straight away; the queue does the real work.
                                const items = library.data.items
                                for (const it of items) if (it.id === card.modelData.id) it.looks[use.modelData.id][half.modelData] = !half.on
                                library.data = Object.assign({}, library.data)
                                root.run(["assign", card.modelData.id, use.modelData.id, half.modelData, half.on ? "on" : "off"])
                              }
                            }
                          }
                        }
                      }
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
  }

  // Set by the library's "make a look from this" (the Looks page listens).
  signal inspireRequested(string pictureId)
  function looksPageInspire(id) { inspireRequested(id) }

  // ================================================================ Looks
  component LooksPage: Item {
    id: maker
    property string editing: ""         // look id, or "" for a new look
    property var draft: null            // {id, name, tagline, colours, derive, inspiredBy, builtin}
    property bool dirty: false
    property string slot: "accent"      // which colour the picker edits
    property var swatches: []           // colours found in the inspiring picture
    property bool showAll: false

    readonly property var keySlots: ["accent", "cyan", "background", "foreground"]
    readonly property var allKeys: ["background", "dark_background", "darker_background", "lighter_background", "selection", "muted",
      "foreground", "dark_foreground", "light_foreground", "bright_foreground", "accent", "cyan",
      "red", "yellow", "orange", "green", "blue", "magenta", "brown",
      "bright_red", "bright_yellow", "bright_green", "bright_cyan", "bright_blue", "bright_magenta"]
    function c(key) { return draft && draft.colours[key] ? draft.colours[key] : "#000000" }
    readonly property var inspiring: {
      if (!draft || !draft.inspiredBy) return null
      for (const it of library.items) if (it.id === draft.inspiredBy) return it
      return null
    }
    // The picture the preview sits on: what inspired it, else its first own.
    readonly property string previewThumb: {
      if (inspiring && inspiring.thumb) return inspiring.thumb
      const look = draft ? library.lookById(draft.id) : null
      return look && look.thumbs.length ? look.thumbs[0] : ""
    }

    function open(id) {
      editing = id
      swatches = []
      dirty = false
      root.status = ""
      root.run(["look", "show", id], function(out) {
        try {
          const d = JSON.parse(out)
          maker.draft = { id: d.id, name: d.name, tagline: d.tagline, colours: d.colours, builtin: d.builtin, shared: !!d.shared, author: d.author || "", inspiredBy: d.inspiredBy, derive: false }
        } catch (error) {}
      })
    }
    function fresh(from) {
      editing = ""
      dirty = true
      swatches = []
      const base = draft ? JSON.parse(JSON.stringify(draft.colours)) : {}
      draft = { id: "", name: from ? strings.t("studio.copyOf").arg(from) : strings.t("studio.newName"), tagline: "", colours: base, builtin: false, inspiredBy: "", derive: true }
    }
    function setColour(key, value) {
      const d = JSON.parse(JSON.stringify(draft))
      d.colours[key] = value
      draft = d
      dirty = true
      // A key colour re-derives the rest (keeping any the user set by hand
      // would need tracking; the key four are what shapes a look).
      if (keySlots.indexOf(key) >= 0 && d.derive) rederive()
    }
    function rederive() {
      const seed = {}
      for (const k of keySlots) seed[k] = draft.colours[k]
      root.run(["look", "derive", JSON.stringify(seed)], function(out) {
        try {
          const d = JSON.parse(JSON.stringify(maker.draft))
          d.colours = JSON.parse(out)
          maker.draft = d
        } catch (error) {}
      })
    }
    function inspire(pictureId) {
      if (!draft) fresh("")
      root.status = ""
      root.run(["look", "inspire", pictureId], function(out) {
        try {
          const found = JSON.parse(out)
          const d = JSON.parse(JSON.stringify(maker.draft))
          d.colours = found.palette
          d.inspiredBy = pictureId.indexOf("/") > 0 && pictureId.indexOf("://") < 0 ? pictureId : d.inspiredBy
          d.derive = true
          maker.draft = d
          maker.swatches = found.swatches
          maker.dirty = true
        } catch (error) {}
      })
    }
    function saveDraft(apply) {
      if (!draft) return
      const body = { name: draft.name, tagline: draft.tagline, colours: draft.colours, derive: false, inspiredBy: draft.inspiredBy }
      if (editing !== "" && !draft.builtin) body.id = editing
      root.status = ""
      root.run(["look", "save", JSON.stringify(body)], function(out) {
        const id = out.split("\n").pop()
        maker.dirty = false
        maker.editing = id
        const d = JSON.parse(JSON.stringify(maker.draft)); d.id = id; d.builtin = false; maker.draft = d
        if (apply) root.run(["look", "set", id])
      })
    }

    Connections {
      target: root
      function onInspireRequested(pictureId) { maker.fresh(""); maker.inspire(pictureId) }
    }
    Component.onCompleted: if (library.data) open(library.data.look)
    Connections {
      target: library
      function onDataChanged() { if (!maker.draft && library.data) maker.open(library.data.look) }
    }

    RowLayout {
      anchors.fill: parent
      spacing: 20

      // ---- looks rail
      ColumnLayout {
        Layout.preferredWidth: 230
        Layout.maximumWidth: 230
        Layout.fillWidth: false
        Layout.fillHeight: true
        spacing: 8
        SectionTitle { text: strings.t("studio.looks") }
        Repeater {
          model: library.looks
          delegate: Rectangle {
            id: lookRow
            required property var modelData
            readonly property bool on: maker.editing === modelData.id
            readonly property bool live: library.data && library.data.look === modelData.id
            Layout.fillWidth: true
            implicitHeight: 58
            radius: 5
            color: modelData.palette.background || "#000"
            border.width: on ? 2 : 1
            border.color: on ? modelData.palette.accent : Qt.rgba(1, 1, 1, lookRowHover.hovered ? 0.3 : 0.12)
            clip: true
            SizedImage {
              anchors.right: parent.right
              anchors.top: parent.top
              anchors.bottom: parent.bottom
              anchors.margins: parent.border.width
              width: parent.width * 0.45
              crop: true
              opacity: 0.55
              url: lookRow.modelData.thumbs.length ? "file://" + lookRow.modelData.thumbs[0] : ""
            }
            Rectangle {
              anchors.fill: parent
              anchors.margins: parent.border.width
              gradient: Gradient {
                orientation: Gradient.Horizontal
                GradientStop { position: 0.45; color: lookRow.modelData.palette.background || "#000" }
                GradientStop { position: 1; color: "transparent" }
              }
            }
            Column {
              anchors.verticalCenter: parent.verticalCenter
              x: 12
              spacing: 3
              Label { text: lookRow.modelData.name.toUpperCase(); font.bold: true; font.letterSpacing: 1.5; color: lookRow.modelData.palette.accent }
              Row {
                spacing: 4
                Repeater {
                  model: ["accent", "cyan", "magenta", "blue", "foreground"]
                  Rectangle { required property string modelData; width: 9; height: 9; radius: 5; color: lookRow.modelData.palette[modelData] || "transparent" }
                }
                Label { visible: lookRow.live; text: "  " + strings.t("studio.live").toUpperCase(); font.pixelSize: Style.font.caption; font.letterSpacing: 1; color: lookRow.modelData.palette.cyan }
                Label { visible: lookRow.modelData.id.indexOf("c-") === 0; text: "  󰖟 " + strings.t("studio.fromCatalog").toUpperCase(); font.pixelSize: Style.font.caption; font.letterSpacing: 1; color: lookRow.modelData.palette.foreground; opacity: 0.6 }
              }
            }
            HoverHandler { id: lookRowHover; cursorShape: Qt.PointingHandCursor }
            TapHandler { onTapped: maker.open(lookRow.modelData.id) }
          }
        }
        Item { Layout.fillHeight: true }
        ActionButton { Layout.fillWidth: true; icon: "󰐕"; text: strings.t("studio.newLook"); tone: root.amber; onClicked: maker.fresh("") }
        ActionButton {
          Layout.fillWidth: true
          icon: "󰆏"
          text: strings.t("studio.duplicate")
          tone: root.teal
          enabled: !!maker.draft
          onClicked: maker.fresh(maker.draft.name)
        }
      }

      // ---- editor
      Flickable {
        Layout.fillWidth: true
        Layout.fillHeight: true
        clip: true
        contentHeight: editor.implicitHeight
        boundsBehavior: Flickable.StopAtBounds

        ColumnLayout {
          id: editor
          width: parent.width
          spacing: 16
          visible: !!maker.draft

          // Name and line.
          RowLayout {
            Layout.fillWidth: true
            spacing: 14
            Field {
              Layout.preferredWidth: 280
              Layout.maximumWidth: 280
              Layout.fillWidth: false
              label: strings.t("studio.name")
              value: maker.draft ? maker.draft.name : ""
              big: true
              onEdited: function(v) { const d = JSON.parse(JSON.stringify(maker.draft)); d.name = v; maker.draft = d; maker.dirty = true }
            }
            Field {
              Layout.fillWidth: true
              label: strings.t("studio.tagline")
              value: maker.draft ? maker.draft.tagline : ""
              onEdited: function(v) { const d = JSON.parse(JSON.stringify(maker.draft)); d.tagline = v; maker.draft = d; maker.dirty = true }
            }
          }

          RowLayout {
            Layout.fillWidth: true
            spacing: 18

            // ---- live preview: a little desktop in the look
            Rectangle {
              id: preview
              Layout.fillWidth: true
              Layout.minimumWidth: 420
              Layout.preferredHeight: 400
              radius: 6
              color: maker.c("background")
              clip: true
              SizedImage {
                anchors.fill: parent
                crop: true
                url: maker.previewThumb ? "file://" + maker.previewThumb : ""
                opacity: 0.85
              }
              Rectangle { anchors.fill: parent; color: "black"; opacity: 0.25 }

              // Terminal.
              Rectangle {
                x: parent.width * 0.05; y: parent.height * 0.08
                width: parent.width * 0.52; height: parent.height * 0.62
                radius: 4
                color: Util.alpha(maker.c("background"), 0.92)
                border.width: 0
                Rectangle {
                  anchors.fill: parent
                  radius: 4
                  color: "transparent"
                  border.width: 2
                  border.color: maker.c("accent")
                }
                Rectangle {
                  anchors.right: parent.right; anchors.bottom: parent.bottom
                  width: parent.width * 0.6; height: 2
                  gradient: Gradient {
                    orientation: Gradient.Horizontal
                    GradientStop { position: 0; color: maker.c("accent") }
                    GradientStop { position: 1; color: maker.c("cyan") }
                  }
                }
                Column {
                  x: 14; y: 12
                  spacing: 5
                  Row { spacing: 8; Mono { text: "~/city"; color: maker.c("blue") } Mono { text: "❯"; color: maker.c("accent") } Mono { text: "ls -la"; color: maker.c("foreground") } }
                  Row { spacing: 8; Mono { text: "drwxr-xr-x"; color: maker.c("muted") } Mono { text: "neon/"; color: maker.c("cyan") } Mono { text: "rain.sh"; color: maker.c("green") } }
                  Row { spacing: 8; Mono { text: "modified:"; color: maker.c("red") } Mono { text: "skyline.qml"; color: maker.c("foreground") } }
                  Row { spacing: 8; Mono { text: "warning:"; color: maker.c("yellow") } Mono { text: "low light"; color: maker.c("dark_foreground") } }
                  Row { spacing: 8; Mono { text: "info:"; color: maker.c("cyan") } Mono { text: "spinner"; color: maker.c("magenta") } Mono { text: "inbound"; color: maker.c("orange") } }
                  Rectangle {
                    width: 210; height: 18
                    color: maker.c("selection")
                    Mono { x: 4; anchors.verticalCenter: parent.verticalCenter; text: "selected text"; color: maker.c("foreground") }
                  }
                }
              }
              // A second, unfocused window.
              Rectangle {
                x: parent.width * 0.61; y: parent.height * 0.08
                width: parent.width * 0.34; height: parent.height * 0.42
                radius: 4
                color: Util.alpha(maker.c("lighter_background"), 0.9)
                border.width: 1
                border.color: Util.alpha(maker.c("muted"), 0.8)
                Column {
                  x: 12; y: 12
                  spacing: 6
                  Mono { text: "BASELINE"; color: maker.c("accent"); font.letterSpacing: 2 }
                  Rectangle { width: 120; height: 4; radius: 2; color: maker.c("cyan") }
                  Rectangle { width: 80; height: 4; radius: 2; color: maker.c("accent") }
                  Rectangle { width: 100; height: 4; radius: 2; color: maker.c("muted") }
                }
              }
              // A notification.
              Rectangle {
                x: parent.width * 0.61; y: parent.height * 0.55
                width: parent.width * 0.34; height: parent.height * 0.16
                radius: 4
                color: maker.c("background")
                border.width: 1
                border.color: maker.c("accent")
                Mono { x: 10; anchors.verticalCenter: parent.verticalCenter; text: "Cells interlinked."; color: maker.c("foreground") }
              }
              // The bar.
              Rectangle {
                anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom
                height: 26
                color: maker.c("background")
                Row {
                  x: 10; anchors.verticalCenter: parent.verticalCenter
                  spacing: 10
                  Repeater {
                    model: ["1", "2", "3", "4", "5", "6"]
                    Mono {
                      required property string modelData
                      required property int index
                      text: modelData
                      color: index === 2 ? maker.c("accent") : maker.c("muted")
                      font.bold: index === 2
                    }
                  }
                }
                Mono { anchors.centerIn: parent; text: "20:49"; color: maker.c("foreground") }
                Row {
                  anchors.right: parent.right; anchors.rightMargin: 10; anchors.verticalCenter: parent.verticalCenter
                  spacing: 10
                  Mono { text: "CPU 12%"; color: maker.c("cyan") }
                  Mono { text: "BAT 97%"; color: maker.c("accent") }
                }
              }
            }

            // ---- key colours and the picker
            ColumnLayout {
              Layout.preferredWidth: 300
              Layout.maximumWidth: 300
              Layout.fillWidth: false
              Layout.alignment: Qt.AlignTop
              spacing: 10
              SectionTitle { text: strings.t("studio.keyColours") }
              GridLayout {
                Layout.fillWidth: true
                columns: 2
                columnSpacing: 8
                rowSpacing: 8
                Repeater {
                  model: maker.keySlots
                  delegate: Rectangle {
                    id: keyTile
                    required property string modelData
                    readonly property bool on: maker.slot === modelData
                    Layout.fillWidth: true
                    implicitHeight: 52
                    radius: 5
                    color: Qt.rgba(1, 1, 1, 0.03)
                    border.width: on ? 2 : 1
                    border.color: on ? root.amber : Qt.rgba(1, 1, 1, 0.12)
                    RowLayout {
                      anchors.fill: parent
                      anchors.margins: 8
                      spacing: 8
                      Rectangle { Layout.preferredWidth: 34; Layout.preferredHeight: 34; radius: 4; color: maker.c(keyTile.modelData); border.width: 1; border.color: Qt.rgba(1, 1, 1, 0.25) }
                      ColumnLayout {
                        spacing: 0
                        Label { text: strings.t("studio.key." + keyTile.modelData); font.pixelSize: Style.font.caption }
                        Label { text: maker.c(keyTile.modelData).toUpperCase(); font.pixelSize: Style.font.caption; opacity: 0.5 }
                      }
                    }
                    HoverHandler { cursorShape: Qt.PointingHandCursor }
                    TapHandler { onTapped: maker.slot = keyTile.modelData }
                  }
                }
              }
              ColourPicker {
                Layout.fillWidth: true
                value: maker.c(maker.slot)
                onPicked: function(v) { maker.setColour(maker.slot, v) }
              }
              Label {
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                elide: Text.ElideNone
                text: strings.t(maker.draft && maker.draft.derive ? "studio.deriveOn" : "studio.deriveOff")
                font.pixelSize: Style.font.caption
                opacity: 0.5
              }
            }
          }

          // ---- inspired by a picture
          SectionTitle { text: strings.t("studio.inspiredBy") }
          RowLayout {
            Layout.fillWidth: true
            spacing: 12
            Rectangle {
              Layout.preferredWidth: 150
              Layout.preferredHeight: 84
              radius: 5
              color: inspireDrop.containsDrag ? Util.alpha(root.amber, 0.15) : Qt.rgba(1, 1, 1, 0.03)
              border.width: 1
              border.color: inspireDrop.containsDrag ? root.amber : Qt.rgba(1, 1, 1, 0.16)
              clip: true
              SizedImage { anchors.fill: parent; anchors.margins: 1; crop: true; visible: !!maker.inspiring; url: maker.inspiring && maker.inspiring.thumb ? "file://" + maker.inspiring.thumb : "" }
              Label { visible: !maker.inspiring; anchors.centerIn: parent; width: parent.width - 16; horizontalAlignment: Text.AlignHCenter; wrapMode: Text.WordWrap; elide: Text.ElideNone; text: strings.t("studio.dropInspire"); font.pixelSize: Style.font.caption; opacity: 0.6 }
              DropArea {
                id: inspireDrop
                anchors.fill: parent
                onDropped: function(event) {
                  const url = event.urls.length ? event.urls[0].toString() : (event.text || "").trim()
                  if (url) maker.inspire(url)
                }
              }
            }
            ColumnLayout {
              Layout.fillWidth: true
              spacing: 6
              Label { text: strings.t("studio.pickInspire"); font.pixelSize: Style.font.caption; opacity: 0.6 }
              ListView {
                Layout.fillWidth: true
                Layout.preferredHeight: 52
                orientation: ListView.Horizontal
                spacing: 6
                clip: true
                model: library.items.filter(function(i) { return !i.video })
                delegate: Rectangle {
                  id: pick
                  required property var modelData
                  width: 80; height: 50
                  radius: 3
                  color: "#000"
                  border.width: maker.draft && maker.draft.inspiredBy === modelData.id ? 2 : 1
                  border.color: maker.draft && maker.draft.inspiredBy === modelData.id ? root.amber : Qt.rgba(1, 1, 1, pickHover.hovered ? 0.4 : 0.12)
                  clip: true
                  SizedImage { anchors.fill: parent; anchors.margins: parent.border.width; crop: true; url: pick.modelData.thumb ? "file://" + pick.modelData.thumb : "" }
                  HoverHandler { id: pickHover; cursorShape: Qt.PointingHandCursor }
                  TapHandler { onTapped: maker.inspire(pick.modelData.id) }
                }
              }
              // Colours found in it: click one to put it in the chosen slot.
              RowLayout {
                visible: maker.swatches.length > 0
                spacing: 5
                Label { text: strings.t("studio.found"); font.pixelSize: Style.font.caption; opacity: 0.6 }
                Repeater {
                  model: maker.swatches.slice(0, 14)
                  Rectangle {
                    id: sw
                    required property string modelData
                    width: 22; height: 22; radius: 4
                    color: modelData
                    border.width: 1
                    border.color: Qt.rgba(1, 1, 1, swHover.hovered ? 0.6 : 0.2)
                    HoverHandler { id: swHover; cursorShape: Qt.PointingHandCursor }
                    PanelToolTip { visible: swHover.hovered; text: strings.t("studio.useFor").arg(strings.t("studio.key." + maker.slot)) }
                    TapHandler { onTapped: maker.setColour(maker.slot, sw.modelData) }
                  }
                }
              }
            }
          }

          // ---- every colour
          RowLayout {
            Layout.fillWidth: true
            SectionTitle { text: strings.t("studio.allColours") }
            Item { Layout.fillWidth: true }
            Label {
              text: (maker.showAll ? "󰅃 " : "󰅀 ") + strings.t(maker.showAll ? "studio.hide" : "studio.showAll")
              font.pixelSize: Style.font.caption
              color: root.teal
              HoverHandler { cursorShape: Qt.PointingHandCursor }
              TapHandler { onTapped: maker.showAll = !maker.showAll }
            }
          }
          GridLayout {
            Layout.fillWidth: true
            visible: maker.showAll
            columns: 5
            columnSpacing: 6
            rowSpacing: 6
            Repeater {
              model: maker.allKeys
              delegate: Rectangle {
                id: colourTile
                required property string modelData
                readonly property bool on: maker.slot === modelData
                Layout.fillWidth: true
                implicitHeight: 40
                radius: 4
                color: Qt.rgba(1, 1, 1, 0.03)
                border.width: on ? 2 : 1
                border.color: on ? root.amber : Qt.rgba(1, 1, 1, 0.1)
                RowLayout {
                  anchors.fill: parent
                  anchors.margins: 6
                  spacing: 6
                  Rectangle { Layout.preferredWidth: 24; Layout.preferredHeight: 24; radius: 3; color: maker.c(colourTile.modelData); border.width: 1; border.color: Qt.rgba(1, 1, 1, 0.2) }
                  Label { Layout.fillWidth: true; text: colourTile.modelData.replace(/_/g, " "); font.pixelSize: Style.font.caption; opacity: 0.75 }
                }
                HoverHandler { cursorShape: Qt.PointingHandCursor }
                TapHandler {
                  onTapped: {
                    maker.slot = colourTile.modelData
                    // Hand-tuning one colour stops the key colours re-deriving it.
                    if (maker.keySlots.indexOf(colourTile.modelData) < 0 && maker.draft.derive) {
                      const d = JSON.parse(JSON.stringify(maker.draft)); d.derive = false; maker.draft = d
                    }
                  }
                }
              }
            }
          }

          // ---- save
          RowLayout {
            Layout.fillWidth: true
            spacing: 10
            Label {
              Layout.fillWidth: true
              wrapMode: Text.WordWrap
              elide: Text.ElideNone
              text: maker.draft && maker.draft.shared ? strings.t("studio.sharedNote").arg(maker.draft.author || strings.t("studio.someone"))
                : maker.draft && maker.draft.builtin ? strings.t("studio.builtinNote") : strings.t("studio.saveNote")
              font.pixelSize: Style.font.caption
              opacity: 0.5
            }
            ActionButton {
              visible: maker.editing !== "" && !!maker.draft && !maker.draft.shared && !maker.dirty
              icon: "󰒖"
              text: strings.t("studio.share")
              tone: root.teal
              enabled: !root.busy
              onClicked: shareSheet.begin(maker.editing)
            }
            ActionButton {
              visible: maker.editing !== "" && maker.draft && (!maker.draft.builtin || maker.draft.shared)
              icon: "󰆴"
              text: strings.t(maker.draft && maker.draft.shared ? "studio.browseRemove" : "studio.delete")
              tone: Commons.Color.urgent
              onClicked: confirmDelete.visible = true
            }
            ActionButton {
              icon: "󰆓"
              text: strings.t(maker.draft && maker.draft.builtin ? "studio.saveCopy" : "studio.save")
              tone: root.teal
              enabled: !!maker.draft && (maker.dirty || maker.draft.builtin) && !root.busy
              onClicked: {
                if (maker.draft.builtin) { const d = JSON.parse(JSON.stringify(maker.draft)); d.name = strings.t("studio.copyOf").arg(d.name); d.builtin = false; maker.draft = d; maker.editing = "" }
                maker.saveDraft(false)
              }
            }
            ActionButton {
              icon: "󰄬"
              text: strings.t("studio.saveApply")
              tone: root.amber
              enabled: !!maker.draft && !maker.draft.builtin && !root.busy
              onClicked: maker.saveDraft(true)
            }
          }
          Rectangle {
            id: confirmDelete
            visible: false
            Layout.fillWidth: true
            implicitHeight: 44
            radius: 5
            color: Util.alpha(Commons.Color.urgent, 0.12)
            border.width: 1
            border.color: Commons.Color.urgent
            RowLayout {
              anchors.fill: parent
              anchors.margins: 10
              Label { Layout.fillWidth: true; text: strings.t("studio.confirmDelete").arg(maker.draft ? maker.draft.name : "") }
              ActionButton { text: strings.t("studio.keep"); tone: root.teal; onClicked: confirmDelete.visible = false }
              ActionButton {
                text: strings.t("studio.delete")
                tone: Commons.Color.urgent
                onClicked: {
                  confirmDelete.visible = false
                  const id = maker.editing
                  root.run(["look", "delete", id], function() { maker.draft = null; maker.editing = ""; if (library.data) maker.open(library.data.look) })
                }
              }
            }
          }
        }
      }
    }

    // ---- Share: exactly what would be published, then a pull request.
    Rectangle {
      id: shareSheet
      anchors.fill: parent
      visible: false
      color: Util.alpha(root.ground, 0.94)
      property var preview: null
      property string author: ""
      property var picked: ({})          // picture id -> false when left out
      property string prUrl: ""
      property string failure: ""
      readonly property bool authorOk: /^[A-Za-z0-9 _.-]{2,40}$/.test(shareSheet.author.trim())
      readonly property bool working: sharePreviewer.running || sharePublisher.running
      readonly property var chosen: preview && preview.pictures ? preview.pictures.filter(function(p) { return p.ok && shareSheet.picked[p.id] !== false }).map(function(p) { return p.id }) : []
      function begin(lookId) {
        shareSheet.preview = null
        shareSheet.prUrl = ""
        shareSheet.failure = ""
        shareSheet.picked = ({})
        shareSheet.visible = true
        sharePreviewer.command = [root.tool, "share", lookId, "--preview"]
        sharePreviewer.running = true
      }
      function publish() {
        shareSheet.failure = ""
        sharePublisher.command = [root.tool, "share", shareSheet.preview.lookId, "--author=" + shareSheet.author.trim(), "--include=" + shareSheet.chosen.join(",")]
        sharePublisher.running = true
      }
      Process {
        id: sharePreviewer
        stdout: StdioCollector { id: previewOut }
        stderr: StdioCollector { id: previewErr }
        onExited: function(code) {
          Qt.callLater(function() {
            if (code !== 0) { shareSheet.failure = previewErr.text.trim().split("\n").pop() || strings.t("studio.failed"); return }
            try {
              shareSheet.preview = JSON.parse(previewOut.text)
              shareSheet.author = shareSheet.preview.author || ""
            } catch (e) { shareSheet.failure = strings.t("studio.failed") }
          })
        }
      }
      Process {
        id: sharePublisher
        stdout: StdioCollector { id: publishOut }
        stderr: StdioCollector { id: publishErr }
        onExited: function(code) {
          Qt.callLater(function() {
            if (code !== 0) { shareSheet.failure = publishErr.text.trim().split("\n").pop() || strings.t("studio.failed"); return }
            try { shareSheet.prUrl = JSON.parse(publishOut.text.trim().split("\n").pop()).url } catch (e) { shareSheet.failure = strings.t("studio.failed") }
          })
        }
      }
      // Clicks stop here, not on the editor underneath.
      MouseArea { anchors.fill: parent; hoverEnabled: true; onWheel: function(w) { w.accepted = true } }

      Rectangle {
        id: shareCard
        anchors.centerIn: parent
        width: Math.min(760, parent.width - 40)
        height: Math.min(shareBody.implicitHeight + 44, parent.height - 20)
        radius: 8
        color: root.ground
        border.width: 1
        border.color: Util.alpha(root.amber, 0.5)
        Rectangle {
          anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
          anchors.margins: 1
          height: 2
          gradient: Gradient {
            orientation: Gradient.Horizontal
            GradientStop { position: 0; color: shareSheet.preview ? shareSheet.preview.colours.accent : root.amber }
            GradientStop { position: 1; color: shareSheet.preview ? shareSheet.preview.colours.cyan : root.teal }
          }
        }
        Flickable {
          anchors.fill: parent
          anchors.margins: 22
          clip: true
          contentHeight: shareBody.implicitHeight
          boundsBehavior: Flickable.StopAtBounds
          ColumnLayout {
            id: shareBody
            width: parent.width
            spacing: 12

            SectionTitle { text: strings.t("studio.shareTitle") }
            Label {
              visible: !shareSheet.preview && !shareSheet.failure
              text: "󰔟  " + strings.t("studio.sharePreparing")
              opacity: 0.6
            }

            // The look as it will appear in the catalog.
            ColumnLayout {
              visible: !!shareSheet.preview
              Layout.fillWidth: true
              spacing: 4
              Label {
                Layout.fillWidth: true
                text: shareSheet.preview ? shareSheet.preview.name : ""
                font.pixelSize: 22; font.bold: true; font.letterSpacing: 1.5
                color: shareSheet.preview ? shareSheet.preview.colours.accent : root.amber
              }
              Label {
                Layout.fillWidth: true
                visible: !!shareSheet.preview && shareSheet.preview.tagline !== ""
                text: shareSheet.preview ? shareSheet.preview.tagline : ""
                opacity: 0.75
              }
              Label {
                text: !shareSheet.preview ? "" : (shareSheet.preview.update
                  ? strings.t("studio.shareUpdate").arg(shareSheet.preview.id).arg(shareSheet.preview.version)
                  : strings.t("studio.shareNew").arg(shareSheet.preview.id))
                font.pixelSize: Style.font.caption
                color: root.teal
              }
              Flow {
                Layout.fillWidth: true
                Layout.topMargin: 6
                spacing: 3
                Repeater {
                  model: shareSheet.preview ? Object.keys(shareSheet.preview.colours) : []
                  Rectangle {
                    required property string modelData
                    width: 22; height: 22; radius: 3
                    color: shareSheet.preview.colours[modelData]
                    border.width: 1; border.color: Qt.rgba(1, 1, 1, 0.15)
                    HoverHandler { id: swatchHover }
                    PanelToolTip { visible: swatchHover.hovered; text: parent.modelData.replace(/_/g, " ") + "  " + shareSheet.preview.colours[parent.modelData] }
                  }
                }
              }
            }

            Field {
              visible: !!shareSheet.preview && shareSheet.prUrl === ""
              Layout.preferredWidth: 320
              Layout.maximumWidth: 320
              Layout.fillWidth: false
              label: strings.t("studio.shareAuthor")
              value: shareSheet.author
              onEdited: function(v) { shareSheet.author = v }
            }
            Label {
              visible: !!shareSheet.preview && shareSheet.prUrl === "" && !shareSheet.authorOk
              text: strings.t("studio.shareAuthorHint")
              font.pixelSize: Style.font.caption
              color: root.amber
            }

            // Pictures: links only, each with where it came from.
            SectionTitle { visible: !!shareSheet.preview; text: strings.t("studio.sharePictures") }
            Label {
              visible: !!shareSheet.preview && shareSheet.preview.pictures.length === 0
              Layout.fillWidth: true
              wrapMode: Text.WordWrap; elide: Text.ElideNone
              text: strings.t("studio.sharePaletteOnly")
              font.pixelSize: Style.font.caption
              opacity: 0.6
            }
            Repeater {
              model: shareSheet.preview ? shareSheet.preview.pictures : []
              delegate: RowLayout {
                id: picRow
                required property var modelData
                readonly property bool on: modelData.ok && shareSheet.picked[modelData.id] !== false
                Layout.fillWidth: true
                spacing: 10
                Rectangle {
                  Layout.preferredWidth: 18; Layout.preferredHeight: 18
                  Layout.alignment: Qt.AlignTop
                  radius: 3
                  color: picRow.on ? Util.alpha(root.amber, 0.3) : "transparent"
                  border.width: 1
                  border.color: picRow.modelData.ok ? root.amber : Qt.rgba(1, 1, 1, 0.2)
                  Label {
                    anchors.centerIn: parent
                    text: picRow.modelData.ok ? (picRow.on ? "󰄬" : "") : "󰅖"
                    font.family: "Iosevka Nerd Font Propo"
                    font.pixelSize: Style.font.caption
                    color: picRow.modelData.ok ? root.amber : root.ink
                    opacity: picRow.modelData.ok ? 1 : 0.4
                  }
                  HoverHandler { cursorShape: picRow.modelData.ok && shareSheet.prUrl === "" ? Qt.PointingHandCursor : Qt.ArrowCursor }
                  TapHandler {
                    enabled: picRow.modelData.ok && shareSheet.prUrl === ""
                    onTapped: {
                      const next = Object.assign({}, shareSheet.picked)
                      next[picRow.modelData.id] = !picRow.on
                      shareSheet.picked = next
                    }
                  }
                }
                ColumnLayout {
                  Layout.fillWidth: true
                  spacing: 1
                  opacity: picRow.modelData.ok ? 1 : 0.55
                  Label { Layout.fillWidth: true; text: picRow.modelData.title || picRow.modelData.id; font.bold: picRow.on }
                  Label {
                    Layout.fillWidth: true
                    visible: text !== ""
                    text: picRow.modelData.ok ? [picRow.modelData.credit, picRow.modelData.page].filter(function(t) { return !!t }).join("  ·  ") : picRow.modelData.reason
                    font.pixelSize: Style.font.caption
                    color: picRow.modelData.ok ? root.ink : root.amber
                    opacity: 0.65
                  }
                }
              }
            }
            Label {
              visible: !!shareSheet.preview && shareSheet.preview.withoutSource > 0
              Layout.fillWidth: true
              wrapMode: Text.WordWrap; elide: Text.ElideNone
              text: !shareSheet.preview ? "" : strings.tn("studio.shareWithoutSource", shareSheet.preview.withoutSource).arg(Commons.I18n.formatNumber(shareSheet.preview.withoutSource))
              font.pixelSize: Style.font.caption
              opacity: 0.6
            }

            // Consent, then the one button that publishes.
            Rectangle {
              visible: !!shareSheet.preview && shareSheet.prUrl === ""
              Layout.fillWidth: true
              implicitHeight: consent.implicitHeight + 20
              radius: 5
              color: Util.alpha(root.teal, 0.07)
              border.width: 1
              border.color: Util.alpha(root.teal, 0.35)
              Label {
                id: consent
                anchors.left: parent.left; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                anchors.margins: 12
                wrapMode: Text.WordWrap; elide: Text.ElideNone
                text: strings.t("studio.shareConsent").arg(shareSheet.preview ? shareSheet.preview.catalog.replace("https://", "") : "")
                font.pixelSize: Style.font.caption
              }
            }
            Label {
              visible: shareSheet.failure !== ""
              Layout.fillWidth: true
              wrapMode: Text.WordWrap; elide: Text.ElideNone
              text: shareSheet.failure
              color: Commons.Color.urgent
              font.pixelSize: Style.font.caption
            }
            // Done: the pull request.
            Rectangle {
              visible: shareSheet.prUrl !== ""
              Layout.fillWidth: true
              implicitHeight: doneRow.implicitHeight + 20
              radius: 5
              color: Util.alpha(root.amber, 0.08)
              border.width: 1
              border.color: Util.alpha(root.amber, 0.45)
              RowLayout {
                id: doneRow
                anchors.left: parent.left; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                anchors.margins: 12
                spacing: 10
                ColumnLayout {
                  Layout.fillWidth: true
                  spacing: 2
                  Label { text: strings.t("studio.shareDone"); color: root.amber; font.bold: true }
                  Label { Layout.fillWidth: true; text: shareSheet.prUrl; font.pixelSize: Style.font.caption; opacity: 0.7 }
                }
                ActionButton { icon: "󰏌"; text: strings.t("studio.openLink"); tone: root.amber; onClicked: Quickshell.execDetached(["xdg-open", shareSheet.prUrl]) }
              }
            }
            RowLayout {
              Layout.fillWidth: true
              Layout.topMargin: 4
              spacing: 10
              Label {
                visible: shareSheet.working
                text: "󰔟"
                color: root.teal
                RotationAnimation on rotation { running: shareSheet.working && !Style.reduceMotion; loops: Animation.Infinite; from: 0; to: 360; duration: 1200 }
              }
              Item { Layout.fillWidth: true }
              ActionButton {
                text: strings.t(shareSheet.prUrl !== "" ? "studio.shareClose" : "studio.shareCancel")
                tone: root.teal
                enabled: !sharePublisher.running
                onClicked: shareSheet.visible = false
              }
              ActionButton {
                visible: shareSheet.prUrl === ""
                icon: "󰊤"
                text: strings.t("studio.sharePublish")
                tone: root.amber
                enabled: !!shareSheet.preview && shareSheet.authorOk && !shareSheet.working
                onClicked: shareSheet.publish()
              }
            }
          }
        }
      }
    }
  }

  // ================================================================ Browse
  // Looks others have shared, from the public catalog. Drawn from their
  // palettes alone: nothing remote is shown until you add one.
  component BrowsePage: Item {
    id: browse
    property var catalog: null        // what `afterlight catalog list` said
    property bool loaded: false
    property var skipPictures: ({})     // catalog id -> true when Add should leave pictures out
    property string working: ""         // catalog id being changed
    readonly property var looks: (catalog && catalog.looks) || []
    readonly property string current: library.data ? library.data.look : ""
    function read(refresh) {
      if (lister.running) return
      lister.command = [root.tool, "catalog", "list"].concat(refresh ? ["--refresh"] : [])
      lister.running = true
    }
    function act(id, args) {
      working = id
      root.status = ""
      root.run(args, function() { browse.read(false) })
    }
    Process {
      id: lister
      stdout: StdioCollector { id: listOut }
      onExited: function(code) {
        Qt.callLater(function() {
          try { browse.catalog = JSON.parse(listOut.text) } catch (e) { browse.catalog = { reachable: false, looks: [], url: "" } }
          browse.loaded = true
        })
      }
    }
    Connections {
      target: root
      function onPageChanged() { if (root.page === "browse" && !lister.running) browse.read(false) }
      function onBusyChanged() { if (!root.busy && browse.working !== "") { browse.working = ""; browse.read(false) } }
    }
    Component.onCompleted: if (root.page === "browse") read(false)

    ColumnLayout {
      anchors.fill: parent
      spacing: 12

      RowLayout {
        Layout.fillWidth: true
        spacing: 10
        SectionTitle { text: strings.tn("studio.browseCount", browse.looks.length).arg(Commons.I18n.formatNumber(browse.looks.length)) }
        Label {
          visible: lister.running
          text: "󰔟"
          color: root.teal
          RotationAnimation on rotation { running: lister.running && !Style.reduceMotion; loops: Animation.Infinite; from: 0; to: 360; duration: 1200 }
        }
        Item { Layout.fillWidth: true }
        ActionButton {
          icon: "󰊤"
          text: strings.t("studio.browseOnGithub")
          tone: root.teal
          onClicked: Quickshell.execDetached(["xdg-open", browse.catalog && browse.catalog.url ? browse.catalog.url : "https://github.com/mortalfish-studio/baseline-looks"])
        }
        ActionButton {
          icon: "󰑓"
          text: strings.t("studio.browseRefresh")
          tone: root.teal
          enabled: !lister.running
          onClicked: browse.read(true)
        }
      }

      // The ground rules, always in view.
      Rectangle {
        Layout.fillWidth: true
        implicitHeight: disclaimer.implicitHeight + 18
        radius: 5
        color: Util.alpha(root.teal, 0.06)
        border.width: 1
        border.color: Util.alpha(root.teal, 0.3)
        RowLayout {
          id: disclaimer
          anchors.left: parent.left; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
          anchors.margins: 12
          spacing: 10
          Label { text: "󰋽"; font.family: "Iosevka Nerd Font Propo"; color: root.teal }
          Label {
            Layout.fillWidth: true
            wrapMode: Text.WordWrap; elide: Text.ElideNone
            text: strings.t("studio.browseDisclaimer")
            font.pixelSize: Style.font.caption
            opacity: 0.8
          }
        }
      }

      // Offline, or not yet read.
      ColumnLayout {
        visible: browse.loaded && !!browse.catalog && !browse.catalog.reachable
        Layout.fillWidth: true
        Layout.fillHeight: true
        spacing: 10
        Item { Layout.fillHeight: true }
        Label { Layout.alignment: Qt.AlignHCenter; text: "󰖪"; font.family: "Iosevka Nerd Font Propo"; font.pixelSize: 34; color: root.teal; opacity: 0.6 }
        Label { Layout.alignment: Qt.AlignHCenter; text: strings.t("studio.browseOffline"); opacity: 0.7 }
        ActionButton { Layout.alignment: Qt.AlignHCenter; icon: "󰑓"; text: strings.t("studio.browseRetry"); tone: root.teal; onClicked: browse.read(true) }
        Item { Layout.fillHeight: true }
      }
      Label {
        visible: !browse.loaded
        Layout.fillWidth: true
        Layout.fillHeight: true
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        text: strings.t("studio.browseLoading")
        opacity: 0.5
      }

      GridView {
        id: catalogGrid
        visible: browse.loaded && !!browse.catalog && browse.catalog.reachable
        Layout.fillWidth: true
        Layout.fillHeight: true
        clip: true
        cellWidth: Math.floor(width / Math.max(1, Math.floor(width / 360)))
        cellHeight: 300
        model: browse.looks
        boundsBehavior: Flickable.StopAtBounds
        delegate: Item {
          id: entry
          required property var modelData
          readonly property bool broken: !!modelData.problem
          readonly property var col: modelData.colours || ({})
          readonly property bool live: !broken && browse.current === modelData.lookId
          readonly property bool busyHere: browse.working === modelData.id && root.busy
          readonly property int pictureCount: modelData.pictures ? modelData.pictures.length : 0
          function c(key, fallback) { return col[key] || fallback }
          width: catalogGrid.cellWidth
          height: catalogGrid.cellHeight

          Rectangle {
            anchors.fill: parent
            anchors.margins: 7
            radius: 7
            color: Qt.rgba(1, 1, 1, entryHover.hovered && !entry.broken ? 0.055 : 0.03)
            border.width: entry.live ? 2 : 1
            border.color: entry.live ? entry.c("accent", root.amber) : entryHover.hovered && !entry.broken ? Util.alpha(entry.c("accent", root.amber), 0.55) : Qt.rgba(1, 1, 1, 0.08)
            opacity: entry.broken ? 0.55 : 1
            HoverHandler { id: entryHover }

            ColumnLayout {
              anchors.fill: parent
              anchors.margins: 10
              spacing: 7

              // A tiny desktop in the look, from its palette alone.
              Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 120
                radius: 4
                color: entry.c("background", "#111")
                clip: true
                visible: !entry.broken
                Rectangle {
                  x: parent.width * 0.06; y: 12
                  width: parent.width * 0.56; height: parent.height - 44
                  radius: 3
                  color: entry.c("background", "#111")
                  border.width: 0
                  Rectangle {
                    anchors.fill: parent
                    radius: 3
                    color: "transparent"
                    border.width: 2
                    border.color: entry.c("accent", "#888")
                  }
                  Rectangle {
                    anchors.right: parent.right; anchors.bottom: parent.bottom
                    width: parent.width * 0.65; height: 2
                    gradient: Gradient {
                      orientation: Gradient.Horizontal
                      GradientStop { position: 0; color: entry.c("accent", "#888") }
                      GradientStop { position: 1; color: entry.c("cyan", "#888") }
                    }
                  }
                  Column {
                    x: 9; y: 9
                    spacing: 5
                    Rectangle { width: 70; height: 4; radius: 2; color: entry.c("blue", "#888") }
                    Rectangle { width: 110; height: 4; radius: 2; color: entry.c("foreground", "#ccc") }
                    Rectangle { width: 52; height: 4; radius: 2; color: entry.c("cyan", "#888") }
                    Rectangle { width: 90; height: 4; radius: 2; color: entry.c("magenta", "#888") }
                  }
                }
                Rectangle {
                  x: parent.width * 0.67; y: 12
                  width: parent.width * 0.27; height: (parent.height - 44) * 0.55
                  radius: 3
                  color: entry.c("lighter_background", "#222")
                  Column {
                    x: 7; y: 8
                    spacing: 4
                    Rectangle { width: 40; height: 3; radius: 2; color: entry.c("accent", "#888") }
                    Rectangle { width: 26; height: 3; radius: 2; color: entry.c("cyan", "#888") }
                  }
                }
                // The bar along the bottom.
                Rectangle {
                  anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom
                  height: 18
                  color: entry.c("lighter_background", "#222")
                  Row {
                    x: 8; anchors.verticalCenter: parent.verticalCenter
                    spacing: 5
                    Repeater {
                      model: 5
                      Rectangle { required property int index; width: 5; height: 5; radius: 3; color: index === 1 ? entry.c("accent", "#888") : Util.alpha(entry.c("foreground", "#ccc"), 0.35) }
                    }
                  }
                  Row {
                    anchors.right: parent.right; anchors.rightMargin: 8; anchors.verticalCenter: parent.verticalCenter
                    spacing: 4
                    Repeater {
                      model: ["accent", "cyan", "magenta", "blue"]
                      Rectangle { required property string modelData; width: 9; height: 9; radius: 5; color: entry.c(modelData, "#888") }
                    }
                  }
                }
              }
              Label {
                visible: entry.broken
                Layout.fillWidth: true
                Layout.preferredHeight: 120
                wrapMode: Text.WordWrap; elide: Text.ElideNone
                verticalAlignment: Text.AlignVCenter
                text: strings.t("studio.browseBroken").arg(entry.modelData.problem || "")
                font.pixelSize: Style.font.caption
              }

              RowLayout {
                Layout.fillWidth: true
                spacing: 8
                Label {
                  Layout.fillWidth: true
                  text: (entry.modelData.name || entry.modelData.id).toUpperCase()
                  font.bold: true
                  font.letterSpacing: 1.5
                  color: entry.broken ? root.ink : entry.c("accent", root.amber)
                }
                Label {
                  visible: entry.live || (!!entry.modelData.installed && !entry.broken)
                  text: (entry.live ? strings.t("studio.live") : strings.t("studio.browseAdded")).toUpperCase()
                  font.pixelSize: Style.font.caption
                  font.letterSpacing: 1
                  color: entry.c("cyan", root.teal)
                }
              }
              Label {
                Layout.fillWidth: true
                Layout.preferredHeight: implicitHeight
                maximumLineCount: 2
                wrapMode: Text.WordWrap
                text: entry.modelData.tagline || ""
                font.pixelSize: Style.font.caption
                opacity: 0.75
              }
              Label {
                Layout.fillWidth: true
                visible: !entry.broken
                text: [entry.modelData.author ? strings.t("studio.browseBy").arg(entry.modelData.author) : "",
                       "v" + (entry.modelData.version || 1),
                       entry.pictureCount > 0 ? strings.tn("studio.browsePictures", entry.pictureCount).arg(entry.pictureCount) : strings.t("studio.browsePaletteOnly")]
                      .filter(function(t) { return t !== "" }).join("  ·  ")
                font.pixelSize: Style.font.caption
                opacity: 0.5
              }
              Item { Layout.fillHeight: true }

              // Add: with or without fetching its pictures.
              RowLayout {
                visible: !entry.broken && !entry.modelData.installed && entry.pictureCount > 0
                Layout.fillWidth: true
                spacing: 8
                readonly property bool fetch: browse.skipPictures[entry.modelData.id] !== true
                Rectangle {
                  Layout.preferredWidth: 16; Layout.preferredHeight: 16
                  radius: 3
                  color: parent.fetch ? Util.alpha(entry.c("accent", root.amber), 0.3) : "transparent"
                  border.width: 1
                  border.color: entry.c("accent", root.amber)
                  Label { anchors.centerIn: parent; text: parent.parent.fetch ? "󰄬" : ""; font.family: "Iosevka Nerd Font Propo"; font.pixelSize: Style.font.caption; color: entry.c("accent", root.amber) }
                }
                Label {
                  Layout.fillWidth: true
                  wrapMode: Text.WordWrap; elide: Text.ElideNone
                  text: strings.tn("studio.browseFetch", entry.pictureCount).arg(entry.pictureCount)
                  font.pixelSize: Style.font.caption
                  opacity: 0.8
                }
                HoverHandler { cursorShape: Qt.PointingHandCursor }
                TapHandler {
                  onTapped: {
                    const next = Object.assign({}, browse.skipPictures)
                    next[entry.modelData.id] = !next[entry.modelData.id]
                    browse.skipPictures = next
                  }
                }
              }
              RowLayout {
                visible: !entry.broken
                Layout.fillWidth: true
                spacing: 6
                Label {
                  visible: entry.busyHere
                  text: "󰔟"
                  color: root.teal
                  RotationAnimation on rotation { running: entry.busyHere && !Style.reduceMotion; loops: Animation.Infinite; from: 0; to: 360; duration: 1200 }
                }
                Item { Layout.fillWidth: true }
                ActionButton {
                  visible: !entry.modelData.installed
                  icon: "󰐕"
                  text: strings.t("studio.browseAdd")
                  tone: entry.c("accent", root.amber)
                  enabled: !root.busy
                  onClicked: browse.act(entry.modelData.id, ["catalog", "add", entry.modelData.id].concat(browse.skipPictures[entry.modelData.id] ? ["--no-pictures"] : []))
                }
                ActionButton {
                  visible: !!entry.modelData.installed && !!entry.modelData.update
                  icon: "󰚰"
                  text: strings.t("studio.browseUpdate").arg(entry.modelData.version)
                  tone: entry.c("accent", root.amber)
                  enabled: !root.busy
                  onClicked: browse.act(entry.modelData.id, ["catalog", "update", entry.modelData.id])
                }
                ActionButton {
                  visible: !!entry.modelData.installed && !entry.live
                  icon: "󰄬"
                  text: strings.t("studio.browseUse")
                  tone: entry.c("cyan", root.teal)
                  enabled: !root.busy
                  onClicked: browse.act(entry.modelData.id, ["look", "set", entry.modelData.lookId])
                }
                ActionButton {
                  visible: !!entry.modelData.installed
                  icon: "󰆴"
                  text: strings.t("studio.browseRemove")
                  tone: Commons.Color.urgent
                  enabled: !root.busy
                  onClicked: browse.act(entry.modelData.id, ["catalog", "remove", entry.modelData.id])
                }
              }
            }
          }
        }
      }
    }
  }

  // ================================================================ pieces
  component SectionTitle: Label {
    font.pixelSize: Style.font.caption
    font.letterSpacing: 3
    color: root.amber
    font.capitalization: Font.AllUppercase
  }

  component Mono: Text {
    textFormat: Text.PlainText
    font.family: Style.font.family
    font.pixelSize: 12
  }

  component IconChip: Rectangle {
    id: chip
    property string glyph: ""
    property string tip: ""
    property bool danger: false
    signal clicked()
    width: 28; height: 24; radius: 4
    color: chipHover.hovered ? (danger ? Commons.Color.urgent : root.amber) : Qt.rgba(0, 0, 0, 0.65)
    Label { anchors.centerIn: parent; text: chip.glyph; font.family: "Iosevka Nerd Font Propo"; color: chipHover.hovered ? "black" : "white" }
    HoverHandler { id: chipHover; cursorShape: Qt.PointingHandCursor }
    PanelToolTip { visible: chipHover.hovered; text: chip.tip }
    TapHandler { onTapped: chip.clicked() }
  }

  component Field: ColumnLayout {
    id: field
    property string label: ""
    property string value: ""
    property bool big: false
    signal edited(string value)
    spacing: 4
    Label { text: field.label.toUpperCase(); font.pixelSize: Style.font.caption; font.letterSpacing: 2; opacity: 0.55 }
    Rectangle {
      Layout.fillWidth: true
      implicitHeight: field.big ? 38 : 34
      radius: 4
      color: Qt.rgba(1, 1, 1, 0.04)
      border.width: 1
      border.color: input.activeFocus ? root.amber : Qt.rgba(1, 1, 1, 0.14)
      TextInput {
        id: input
        anchors.verticalCenter: parent.verticalCenter
        x: 10
        width: parent.width - 20
        clip: true
        text: field.value
        color: field.big ? root.amber : root.ink
        font.family: Style.font.family
        font.pixelSize: field.big ? Style.font.subtitle : Style.font.body
        font.bold: field.big
        onTextEdited: field.edited(text)
      }
    }
  }

  // Hue strip, a saturation/brightness square, and a hex box.
  component ColourPicker: ColumnLayout {
    id: picker
    property string value: "#000000"
    signal picked(string value)
    property real h: 0
    property real s: 0
    property real v: 0
    spacing: 8
    function load() {
      const c = Qt.color(value)
      if (c.hsvHue >= 0) h = c.hsvHue
      s = c.hsvSaturation; v = c.hsvValue
      hex.text = value.toUpperCase()
    }
    onValueChanged: load()
    Component.onCompleted: load()
    function emit() { picked(Qt.hsva(h, s, v, 1).toString()) }

    Rectangle {
      id: square
      Layout.fillWidth: true
      Layout.preferredHeight: 150
      radius: 4
      color: Qt.hsva(picker.h, 1, 1, 1)
      Rectangle {
        anchors.fill: parent
        radius: 4
        gradient: Gradient {
          orientation: Gradient.Horizontal
          GradientStop { position: 0; color: "white" }
          GradientStop { position: 1; color: "transparent" }
        }
      }
      Rectangle {
        anchors.fill: parent
        radius: 4
        gradient: Gradient {
          GradientStop { position: 0; color: "transparent" }
          GradientStop { position: 1; color: "black" }
        }
      }
      Rectangle {
        x: picker.s * square.width - 7
        y: (1 - picker.v) * square.height - 7
        width: 14; height: 14; radius: 7
        color: "transparent"
        border.width: 2
        border.color: picker.v > 0.5 ? "black" : "white"
      }
      MouseArea {
        anchors.fill: parent
        cursorShape: Qt.CrossCursor
        function at(mouse) {
          picker.s = Math.max(0, Math.min(1, mouse.x / width))
          picker.v = Math.max(0, Math.min(1, 1 - mouse.y / height))
        }
        onPressed: function(mouse) { at(mouse) }
        onPositionChanged: function(mouse) { if (pressed) at(mouse) }
        onReleased: picker.emit()
      }
    }
    Rectangle {
      id: hueStrip
      Layout.fillWidth: true
      Layout.preferredHeight: 14
      radius: 7
      gradient: Gradient {
        orientation: Gradient.Horizontal
        GradientStop { position: 0.0; color: "#ff0000" }
        GradientStop { position: 0.17; color: "#ffff00" }
        GradientStop { position: 0.33; color: "#00ff00" }
        GradientStop { position: 0.5; color: "#00ffff" }
        GradientStop { position: 0.67; color: "#0000ff" }
        GradientStop { position: 0.83; color: "#ff00ff" }
        GradientStop { position: 1.0; color: "#ff0000" }
      }
      Rectangle {
        x: picker.h * hueStrip.width - 3
        y: -2
        width: 6; height: 18; radius: 3
        color: "white"
        border.width: 1
        border.color: "black"
      }
      MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        function at(mouse) { picker.h = Math.max(0, Math.min(0.999, mouse.x / width)) }
        onPressed: function(mouse) { at(mouse) }
        onPositionChanged: function(mouse) { if (pressed) at(mouse) }
        onReleased: picker.emit()
      }
    }
    RowLayout {
      Layout.fillWidth: true
      spacing: 8
      Rectangle { Layout.preferredWidth: 30; Layout.preferredHeight: 26; radius: 4; color: Qt.hsva(picker.h, picker.s, picker.v, 1); border.width: 1; border.color: Qt.rgba(1, 1, 1, 0.25) }
      Rectangle {
        Layout.fillWidth: true
        implicitHeight: 28
        radius: 4
        color: Qt.rgba(1, 1, 1, 0.04)
        border.width: 1
        border.color: hex.activeFocus ? root.amber : Qt.rgba(1, 1, 1, 0.14)
        TextInput {
          id: hex
          anchors.verticalCenter: parent.verticalCenter
          x: 8
          width: parent.width - 16
          color: root.ink
          font.family: Style.font.family
          font.pixelSize: Style.font.body
          maximumLength: 7
          onAccepted: {
            const t = text.trim()
            if (/^#?[0-9a-fA-F]{6}$/.test(t)) picker.picked((t[0] === "#" ? t : "#" + t).toLowerCase())
          }
        }
      }
    }
  }
}
