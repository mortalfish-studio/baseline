import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Afterlight 2049's modes and tweaks, each drawn in what it changes: the mode
// cards in their own palettes, the schedule as a day across a strip, warmth
// from candle to daylight, dimming on two little windows.
Column {
  id: root
  property var host: null
  spacing: Style.space(12)

  readonly property var st: host ? host.afterState : null
  readonly property var cfg: st ? st.settings : null
  readonly property string mode: st ? st.mode : "other"
  property string editing: ""
  readonly property string edit: editing !== "" ? editing : (mode === "other" ? "day" : mode)
  readonly property var tw: cfg ? cfg.tweaks[edit] : null
  readonly property var pal: st && st.palettes ? st.palettes : ({})
  readonly property var editPal: pal[edit] || ({})

  readonly property color amber: Commons.Color.accent
  readonly property color teal: host ? host.themeCyan : Commons.Color.foreground

  // Live values while a slider is dragged, so the previews move with it.
  property real liveDim: tw ? tw.dim : 0
  property real liveTerminal: tw ? tw.terminalOpacity : 1
  property real liveWeb: tw && tw.webDim !== undefined ? tw.webDim : 0
  property real liveNightWall: cfg ? cfg.tweaks.night.wallpaperBrightness : 35
  property real liveBacklight: cfg ? cfg.tweaks.saver.backlight : 60
  onTwChanged: { liveDim = tw ? tw.dim : 0; liveTerminal = tw ? tw.terminalOpacity : 1; liveWeb = tw && tw.webDim !== undefined ? tw.webDim : 0 }
  onCfgChanged: {
    liveNightWall = cfg ? cfg.tweaks.night.wallpaperBrightness : 35
    liveBacklight = cfg ? cfg.tweaks.saver.backlight : 60
  }

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("../i18n") }

  function set(path, value) { host.afterlight(["set", path, JSON.stringify(value)]) }
  function pct(v) { return strings.t("percent").arg(Commons.I18n.formatNumber(Math.round(v))) }
  function c(p, key, fallback) { return p && p[key] ? p[key] : fallback }
  function minutes(hhmm) { const t = hhmm.split(":"); return parseInt(t[0]) * 60 + parseInt(t[1]) }
  function shift(hhmm, delta) {
    const total = (minutes(hhmm) + delta + 1440) % 1440
    const h = Math.floor(total / 60), m = total % 60
    return (h < 10 ? "0" : "") + h + ":" + (m < 10 ? "0" : "") + m
  }
  // Kelvin to a rough screen tint, for the warmth track and swatch.
  function kelvin(k) {
    const t = (k - 2500) / 4000
    return Qt.rgba(1, 0.62 + 0.36 * t, 0.32 + 0.66 * t, 1)
  }
  readonly property var nightThumb: {
    if (!st) return ""
    for (const w of st.wallpapers) if (w.night && !w.video && w.thumb) return w.thumb
    return ""
  }
  readonly property var dayThumb: {
    if (!st) return ""
    for (const w of st.wallpapers) if (w.day && !w.video && w.thumb) return w.thumb
    return ""
  }

  Label { visible: !root.cfg; text: strings.t("wall.loading") }

  // ======================================================== Look
  // The whole scheme: palette and wallpapers, in Day, Night and Saver alike.
  // Each card is the look itself: its pictures under its own colours.
  Column {
    id: lookPicker
    width: parent.width
    spacing: Style.space(8)
    visible: !!root.st && !!root.st.looks && root.st.looks.length > 1
    readonly property var looks: root.st && root.st.looks ? root.st.looks : []
    readonly property string current: root.st ? root.st.look : "afterlight"
    property string pending: ""
    function choose(id) {
      if (id === current || root.host.afterBusy) return
      pending = id
      root.host.afterlight(["look", "set", id])
    }
    function step(by) {
      if (looks.length === 0) return
      let at = 0
      for (let i = 0; i < looks.length; i++) if (looks[i].id === current) at = i
      choose(looks[(at + by + looks.length) % looks.length].id)
    }
    onCurrentChanged: pending = ""

    RowLayout {
      width: parent.width
      spacing: Style.space(6)
      Section { Layout.fillWidth: true; title: strings.t("theme.look"); amber: root.amber; teal: root.teal }
      ActionButton { icon: "󰏘"; text: strings.t("studio.open"); tone: root.teal; onClicked: root.host.openStudio("looks") }
      StepButton { text: Commons.I18n.rightToLeft ? "›" : "‹"; onClicked: lookPicker.step(-1) }
      StepButton { text: Commons.I18n.rightToLeft ? "‹" : "›"; onClicked: lookPicker.step(1) }
    }

    Grid {
      id: lookGrid
      width: parent.width
      columns: 2
      spacing: Style.space(8)
      readonly property real cardWidth: (width - spacing) / 2

      Repeater {
        model: lookPicker.looks
        delegate: Item {
          id: lookCard
          required property var modelData
          readonly property var p: modelData.palette || ({})
          readonly property bool current: lookPicker.current === modelData.id
          readonly property bool switching: lookPicker.pending === modelData.id
          readonly property color accent: root.c(p, "accent", "#f29a4a")
          readonly property color cyan: root.c(p, "cyan", "#6db5b9")
          readonly property color bg: root.c(p, "background", "#121417")
          width: lookGrid.cardWidth
          height: Style.space(84)

          // Frame: the look's own border gradient when it's on.
          Rectangle {
            anchors.fill: parent
            radius: Style.cornerRadius > 0 ? Style.space(5) : 0
            gradient: Gradient {
              orientation: Gradient.Horizontal
              GradientStop { position: 0; color: lookCard.current || lookCard.switching ? lookCard.accent : Qt.rgba(1, 1, 1, lookHover.hovered ? 0.28 : 0.12) }
              GradientStop { position: 1; color: lookCard.current || lookCard.switching ? lookCard.cyan : Qt.rgba(1, 1, 1, lookHover.hovered ? 0.28 : 0.12) }
            }
          }
          Rectangle {
            id: lookFace
            anchors.fill: parent
            anchors.margins: lookCard.current ? 2 : 1
            radius: Style.cornerRadius > 0 ? Style.space(4) : 0
            color: lookCard.bg
            clip: true

            // Its pictures as a strip of slices.
            Row {
              anchors.fill: parent
              Repeater {
                model: lookCard.modelData.thumbs
                SizedImage {
                  required property string modelData
                  width: lookFace.width / Math.max(1, lookCard.modelData.thumbs.length)
                  height: lookFace.height
                  crop: true
                  url: modelData ? "file://" + modelData : ""
                  opacity: lookCard.current || lookHover.hovered ? 0.95 : 0.6
                  Behavior on opacity { NumberAnimation { duration: Style.duration(180); easing.type: Easing.OutCubic } }
                }
              }
            }
            // Without pictures yet: the palette as a neon horizon.
            Rectangle {
              visible: lookCard.modelData.thumbs.length === 0
              anchors.fill: parent
              gradient: Gradient {
                GradientStop { position: 0; color: lookCard.bg }
                GradientStop { position: 0.62; color: Qt.darker(lookCard.accent, 2.6) }
                GradientStop { position: 0.64; color: lookCard.accent }
                GradientStop { position: 0.66; color: Qt.darker(lookCard.cyan, 2.8) }
                GradientStop { position: 1; color: lookCard.bg }
              }
            }
            // A shade from the look's ground, so the name reads on any picture.
            Rectangle {
              anchors.fill: parent
              gradient: Gradient {
                orientation: Gradient.Horizontal
                GradientStop { position: 0; color: Util.alpha(lookCard.bg, 0.92) }
                GradientStop { position: 0.55; color: Util.alpha(lookCard.bg, 0.45) }
                GradientStop { position: 1; color: Util.alpha(lookCard.bg, 0) }
              }
            }

            Column {
              x: Style.space(8)
              anchors.bottom: parent.bottom
              anchors.bottomMargin: Style.space(7)
              width: parent.width - Style.space(16)
              spacing: Style.space(2)
              Row {
                spacing: Style.space(4)
                Repeater {
                  model: ["accent", "cyan", "magenta", "blue"]
                  Rectangle {
                    required property string modelData
                    width: Style.space(6); height: width; radius: width / 2
                    color: root.c(lookCard.p, modelData, "transparent")
                  }
                }
              }
              Label {
                text: lookCard.modelData.name.toUpperCase()
                color: lookCard.accent
                font.bold: true
                font.letterSpacing: Style.space(1.5)
              }
              Label {
                width: parent.width
                text: lookCard.modelData.tagline
                color: root.c(lookCard.p, "foreground", "#e8dccf")
                opacity: 0.7
                font.pixelSize: Style.font.caption
              }
            }
            // On: a small lit tag; switching: a spinner in its place.
            Rectangle {
              visible: lookCard.current || lookCard.switching
              anchors.top: parent.top
              anchors.right: parent.right
              anchors.margins: Style.space(6)
              implicitWidth: tagLabel.implicitWidth + Style.space(10)
              implicitHeight: tagLabel.implicitHeight + Style.space(2)
              color: Util.alpha(lookCard.bg, 0.8)
              border.width: 1
              border.color: lookCard.accent
              radius: Style.cornerRadius > 0 ? Style.space(2) : 0
              Label {
                id: tagLabel
                anchors.centerIn: parent
                text: lookCard.switching ? "󰔟" : strings.t("theme.lookOn").toUpperCase()
                font.pixelSize: Style.font.caption
                font.letterSpacing: Style.space(1)
                color: lookCard.accent
              }
            }
          }
          HoverHandler { id: lookHover; cursorShape: Qt.PointingHandCursor }
          TapHandler { onTapped: lookPicker.choose(lookCard.modelData.id) }
        }
      }
    }
  }

  // ======================================================== Mode cards
  Column {
    width: parent.width
    spacing: Style.space(8)
    visible: !!root.cfg

    Section { width: parent.width; title: strings.t("theme.mode"); amber: root.amber; teal: root.teal }

    Row {
      id: cards
      width: parent.width
      spacing: Style.space(8)
      readonly property real cardWidth: (width - spacing * 2) / 3

      Repeater {
        model: [
          { mode: "day", glyph: "󰖨", sub: "theme.daySub" },
          { mode: "night", glyph: "󰖔", sub: "theme.nightSub" },
          { mode: "saver", glyph: "󰌪", sub: "theme.saverSub" }
        ]
        delegate: Item {
          id: card
          required property var modelData
          readonly property var p: root.pal[modelData.mode] || ({})
          readonly property bool current: root.mode === modelData.mode
          readonly property color accent: root.c(p, "accent", "#f29a4a")
          readonly property color cyan: root.c(p, "cyan", "#6db5b9")
          readonly property color fg: root.c(p, "foreground", "#e8dccf")
          width: cards.cardWidth
          height: Style.space(96)

          // Gradient frame in the mode's own border colours when it's on.
          Rectangle {
            anchors.fill: parent
            radius: Style.cornerRadius > 0 ? Style.space(5) : 0
            gradient: Gradient {
              orientation: Gradient.Horizontal
              GradientStop { position: 0; color: card.current ? card.accent : Qt.rgba(1, 1, 1, cardHover.hovered ? 0.25 : 0.12) }
              GradientStop { position: 1; color: card.current ? card.cyan : Qt.rgba(1, 1, 1, cardHover.hovered ? 0.25 : 0.12) }
            }
          }
          Rectangle {
            id: face
            anchors.fill: parent
            anchors.margins: card.current ? 2 : 1
            radius: Style.cornerRadius > 0 ? Style.space(4) : 0
            color: root.c(card.p, "background", "#121417")
            clip: true

            // A tiny desktop: two windows with the mode's border gradient.
            Rectangle {
              x: Style.space(8); y: Style.space(8)
              width: parent.width * 0.5; height: Style.space(30)
              color: root.c(card.p, "lighter_background", "#1f242a")
              border.width: 1
              border.color: card.accent
              Rectangle { x: 4; y: 5; width: parent.width * 0.6; height: 2; color: card.fg; opacity: 0.7 }
              Rectangle { x: 4; y: 10; width: parent.width * 0.4; height: 2; color: card.cyan; opacity: 0.8 }
              Rectangle { x: 4; y: 15; width: parent.width * 0.5; height: 2; color: card.fg; opacity: 0.4 }
            }
            Rectangle {
              x: parent.width * 0.5 + Style.space(12); y: Style.space(8)
              width: parent.width * 0.5 - Style.space(20); height: Style.space(30)
              color: root.c(card.p, "lighter_background", "#1f242a")
              border.width: 1
              border.color: card.cyan
              opacity: card.modelData.mode === "day" ? 0.75 : 0.45
            }

            Label {
              x: Style.space(8)
              anchors.bottom: parent.bottom
              anchors.bottomMargin: Style.space(22)
              text: card.modelData.glyph + "  " + strings.t("mode." + card.modelData.mode).toUpperCase()
              color: card.accent
              font.bold: true
              font.letterSpacing: Style.space(1)
            }
            Label {
              x: Style.space(8)
              width: parent.width - Style.space(16)
              anchors.bottom: parent.bottom
              anchors.bottomMargin: Style.space(7)
              text: strings.t(card.modelData.sub)
              color: card.fg
              opacity: 0.6
              font.pixelSize: Style.font.caption
            }
          }

          HoverHandler { id: cardHover; cursorShape: Qt.PointingHandCursor }
          TapHandler {
            onTapped: {
              root.editing = ""
              if (!card.current) root.host.afterlight(["mode", card.modelData.mode])
            }
          }
        }
      }
    }

    Label {
      width: parent.width
      visible: root.mode === "other"
      wrapMode: Text.WordWrap
      elide: Text.ElideNone
      opacity: 0.75
      text: strings.t("mode.other")
    }
  }

  // ======================================================== Schedule
  Column {
    width: parent.width
    spacing: Style.space(8)
    visible: !!root.cfg

    Section { width: parent.width; title: strings.t("theme.schedule"); amber: root.amber; teal: root.teal }

    OptionTile {
      width: parent.width
      icon: "󰔛"
      title: strings.t("theme.auto")
      detail: root.cfg ? strings.t("theme.autoHint").arg(root.cfg.schedule.night).arg(root.cfg.schedule.day) : ""
      checked: !!root.cfg && root.cfg.schedule.auto
      amber: root.amber; teal: root.teal
      onToggled: root.set("schedule.auto", !root.cfg.schedule.auto)
    }

    // A day across a strip: slate by day, black by night, a needle at now.
    Item {
      id: dayStrip
      width: parent.width
      height: Style.space(34)
      visible: !!root.cfg && root.cfg.schedule.auto
      readonly property real dayAt: root.cfg ? root.minutes(root.cfg.schedule.day) / 1440 : 0.29
      readonly property real nightAt: root.cfg ? root.minutes(root.cfg.schedule.night) / 1440 : 0.83
      property real nowAt: 0
      Timer {
        interval: 60000; repeat: true; triggeredOnStart: true; running: dayStrip.visible
        onTriggered: { const d = new Date(); dayStrip.nowAt = (d.getHours() * 60 + d.getMinutes()) / 1440 }
      }

      Rectangle {
        id: strip
        y: Style.space(4)
        width: parent.width
        height: Style.space(12)
        radius: Style.space(2)
        color: root.c(root.pal.night, "background", "#000000")
        border.width: 1
        border.color: Qt.rgba(1, 1, 1, 0.12)
        clip: true
        // Day stretch (handles a day that wraps past midnight too).
        Rectangle {
          readonly property bool wraps: dayStrip.dayAt > dayStrip.nightAt
          x: wraps ? 0 : parent.width * dayStrip.dayAt
          width: wraps ? parent.width * dayStrip.nightAt : parent.width * (dayStrip.nightAt - dayStrip.dayAt)
          height: parent.height
          gradient: Gradient {
            orientation: Gradient.Horizontal
            GradientStop { position: 0; color: Qt.darker(root.amber, 2.2) }
            GradientStop { position: 0.5; color: root.c(root.pal.day, "lighter_background", "#1f242a") }
            GradientStop { position: 1; color: Qt.darker(root.amber, 2.2) }
          }
        }
        Rectangle {
          visible: dayStrip.dayAt > dayStrip.nightAt
          x: parent.width * dayStrip.dayAt
          width: parent.width * (1 - dayStrip.dayAt)
          height: parent.height
          color: root.c(root.pal.day, "lighter_background", "#1f242a")
        }
      }
      // Now.
      Rectangle {
        x: dayStrip.width * dayStrip.nowAt - 1
        y: 0
        width: 2
        height: Style.space(20)
        color: root.teal
      }
      Label { x: 0; anchors.bottom: parent.bottom; text: "00"; font.pixelSize: Style.font.caption; opacity: 0.4 }
      Label { x: parent.width / 2 - width / 2; anchors.bottom: parent.bottom; text: "12"; font.pixelSize: Style.font.caption; opacity: 0.4 }
      Label { x: parent.width - width; anchors.bottom: parent.bottom; text: "24"; font.pixelSize: Style.font.caption; opacity: 0.4 }
    }

    RowLayout {
      width: parent.width
      visible: !!root.cfg && root.cfg.schedule.auto
      spacing: Style.space(10)
      TimeStepper {
        glyph: "󰖔"; tone: root.teal
        label: strings.t("theme.nightFrom")
        value: root.cfg ? root.cfg.schedule.night : "20:00"
        onStepped: function(v) { root.set("schedule.night", v) }
      }
      Item { Layout.fillWidth: true }
      TimeStepper {
        glyph: "󰖨"; tone: root.amber
        label: strings.t("theme.dayFrom")
        value: root.cfg ? root.cfg.schedule.day : "07:00"
        onStepped: function(v) { root.set("schedule.day", v) }
      }
    }

    OptionTile {
      width: parent.width
      icon: "󰂃"
      title: strings.t("theme.saverOnBattery")
      detail: strings.t("theme.saverOnBatteryHint")
      checked: !!root.cfg && root.cfg.schedule.saverOnBattery
      amber: root.amber; teal: root.teal
      onToggled: root.set("schedule.saverOnBattery", !root.cfg.schedule.saverOnBattery)
    }
  }

  // ======================================================== Bar style
  Column {
    width: parent.width
    spacing: Style.space(8)
    visible: !!root.cfg

    Section { width: parent.width; title: strings.t("theme.bar"); amber: root.amber; teal: root.teal }

    Row {
      id: bars
      width: parent.width
      spacing: Style.space(8)
      readonly property real tileWidth: (width - spacing * 2) / 3
      Repeater {
        model: ["glassy", "opaque", "none"]
        delegate: Item {
          id: barTile
          required property string modelData
          readonly property bool current: root.st && root.st.bar === modelData
          width: bars.tileWidth
          height: Style.space(46)

          // A slice of wallpaper with a bar across its top in this style.
          Rectangle {
            anchors.fill: parent
            radius: Style.space(3)
            color: "#000"
            border.width: barTile.current ? 2 : 1
            border.color: barTile.current ? root.amber : Qt.rgba(1, 1, 1, barHover.hovered ? 0.3 : 0.12)
            clip: true
            SizedImage {
              anchors.fill: parent
              anchors.margins: parent.border.width
              crop: true
              url: root.dayThumb ? "file://" + root.dayThumb : ""
            }
            Rectangle {
              x: parent.border.width; y: parent.border.width
              width: parent.width - parent.border.width * 2
              height: Style.space(11)
              color: barTile.modelData === "opaque" ? "#050608"
                : barTile.modelData === "glassy" ? Qt.rgba(0.02, 0.024, 0.03, 0.55) : "transparent"
              Row {
                anchors.verticalCenter: parent.verticalCenter
                x: Style.space(4)
                spacing: Style.space(3)
                Repeater { model: 4; Rectangle { width: Style.space(5); height: 2; color: root.amber } }
              }
            }
            Label {
              anchors.bottom: parent.bottom
              anchors.right: parent.right
              anchors.margins: Style.space(4)
              text: strings.t("bar." + barTile.modelData)
              font.pixelSize: Style.font.caption
              font.bold: barTile.current
              color: "white"
              style: Text.Outline
              styleColor: "black"
            }
          }
          HoverHandler { id: barHover; cursorShape: Qt.PointingHandCursor }
          TapHandler { onTapped: root.host.afterlight(["bar", barTile.modelData]) }
        }
      }
    }
  }

  // ======================================================== Tweaks
  Column {
    width: parent.width
    spacing: Style.space(9)
    visible: !!root.tw

    Section { width: parent.width; title: strings.t("theme.adjust"); amber: root.amber; teal: root.teal }

    // Which mode the controls below change, as three palette chips.
    Row {
      spacing: Style.space(6)
      Repeater {
        model: ["day", "night", "saver"]
        delegate: Rectangle {
          id: chip
          required property string modelData
          readonly property var p: root.pal[modelData] || ({})
          readonly property bool on: root.edit === modelData
          width: chipRow.implicitWidth + Style.space(14)
          height: chipRow.implicitHeight + Style.space(8)
          radius: Style.space(3)
          color: root.c(p, "background", "#000")
          border.width: on ? 2 : 1
          border.color: on ? root.c(p, "accent", "#f29a4a") : Qt.rgba(1, 1, 1, 0.14)
          Row {
            id: chipRow
            anchors.centerIn: parent
            spacing: Style.space(5)
            Rectangle { width: Style.space(6); height: width; radius: width / 2; color: root.c(chip.p, "accent", "#f29a4a"); anchors.verticalCenter: parent.verticalCenter }
            Rectangle { width: Style.space(6); height: width; radius: width / 2; color: root.c(chip.p, "cyan", "#6db5b9"); anchors.verticalCenter: parent.verticalCenter }
            Label { text: strings.t("mode." + chip.modelData); font.pixelSize: Style.font.caption; color: root.c(chip.p, "foreground", "#e8dccf") }
          }
          HoverHandler { cursorShape: Qt.PointingHandCursor }
          TapHandler { onTapped: root.editing = chip.modelData }
        }
      }
    }

    // Dimming, shown on two windows: the focused one lit, the other dimmed.
    RowLayout {
      width: parent.width
      spacing: Style.space(10)
      ThemedSlider {
        Layout.fillWidth: true
        icon: "󰃞"
        label: strings.t("tweak.dim")
        valueText: root.pct(root.liveDim * 100)
        value: root.tw ? root.tw.dim : 0
        minimum: 0; maximum: 0.9; step: 0.05
        fromColor: root.c(root.editPal, "accent", root.amber)
        toColor: root.c(root.editPal, "cyan", root.teal)
        onDragged: function(v) { root.liveDim = v }
        onCommitted: function(v) { root.set("tweaks." + root.edit + ".dim", v) }
      }
      Item {
        Layout.preferredWidth: Style.space(70)
        Layout.preferredHeight: Style.space(40)
        Rectangle {
          width: Style.space(38); height: Style.space(30)
          color: root.c(root.editPal, "lighter_background", "#1f242a")
          border.width: 1; border.color: Qt.rgba(1, 1, 1, 0.2)
          Rectangle { anchors.fill: parent; color: "black"; opacity: root.liveDim }
        }
        Rectangle {
          x: Style.space(28); y: Style.space(10)
          width: Style.space(40); height: Style.space(30)
          color: root.c(root.editPal, "lighter_background", "#1f242a")
          border.width: 1
          border.color: root.c(root.editPal, "accent", root.amber)
          Rectangle { x: 4; y: 6; width: parent.width * 0.6; height: 2; color: root.c(root.editPal, "foreground", "#e8dccf") }
          Rectangle { x: 4; y: 12; width: parent.width * 0.4; height: 2; color: root.c(root.editPal, "cyan", root.teal) }
        }
      }
    }

    // Terminal opacity, shown as a terminal over the wallpaper.
    RowLayout {
      width: parent.width
      spacing: Style.space(10)
      ThemedSlider {
        Layout.fillWidth: true
        icon: "󰆍"
        label: strings.t("tweak.terminal")
        valueText: root.pct(root.liveTerminal * 100)
        value: root.tw ? root.tw.terminalOpacity : 1
        minimum: 0.6; maximum: 1; step: 0.05
        fromColor: root.c(root.editPal, "accent", root.amber)
        toColor: root.c(root.editPal, "cyan", root.teal)
        onDragged: function(v) { root.liveTerminal = v }
        onCommitted: function(v) { root.set("tweaks." + root.edit + ".terminalOpacity", v) }
      }
      Rectangle {
        Layout.preferredWidth: Style.space(70)
        Layout.preferredHeight: Style.space(40)
        color: "black"
        clip: true
        SizedImage {
          anchors.fill: parent
          crop: true
          url: (root.edit === "day" ? root.dayThumb : root.nightThumb) ? "file://" + (root.edit === "day" ? root.dayThumb : root.nightThumb) : ""
          opacity: root.edit === "day" ? 1 : 0.4
        }
        Rectangle {
          anchors.fill: parent
          anchors.margins: Style.space(6)
          color: root.c(root.editPal, "background", "#121417")
          opacity: root.liveTerminal
          border.width: 1
          border.color: root.c(root.editPal, "accent", root.amber)
        }
        Label {
          x: Style.space(10); y: Style.space(9)
          text: "❯ _"
          font.pixelSize: Style.font.caption
          color: root.c(root.editPal, "cyan", root.teal)
        }
      }
    }

    // Dim the browser, shown as a white page fading into the dark.
    RowLayout {
      width: parent.width
      spacing: Style.space(10)
      ThemedSlider {
        Layout.fillWidth: true
        icon: "󰖟"
        label: strings.t("tweak.web")
        valueText: root.pct(root.liveWeb * 100)
        value: root.liveWeb
        minimum: 0; maximum: 0.6; step: 0.05
        fromColor: root.c(root.editPal, "accent", root.amber)
        toColor: root.c(root.editPal, "cyan", root.teal)
        onDragged: function(v) { root.liveWeb = v }
        onCommitted: function(v) { root.set("tweaks." + root.edit + ".webDim", v) }
      }
      Rectangle {
        Layout.preferredWidth: Style.space(70)
        Layout.preferredHeight: Style.space(40)
        color: "black"
        Rectangle {
          anchors.fill: parent
          anchors.margins: Style.space(6)
          color: "#f2f2f2"
          opacity: 1 - root.liveWeb
          Rectangle { x: 5; y: 6; width: parent.width * 0.55; height: 2; color: "#555" }
          Rectangle { x: 5; y: 12; width: parent.width * 0.35; height: 2; color: "#888" }
        }
      }
    }

    Row {
      width: parent.width
      spacing: Style.space(8)
      OptionTile {
        width: (parent.width - parent.spacing) / 2
        icon: "󰂵"
        title: strings.t("tweak.blur")
        detail: strings.t("tweak.blurDetail")
        checked: !!root.tw && root.tw.blur
        amber: root.c(root.editPal, "accent", root.amber); teal: root.teal
        onToggled: root.set("tweaks." + root.edit + ".blur", !root.tw.blur)
      }
      OptionTile {
        width: (parent.width - parent.spacing) / 2
        icon: "󰑮"
        title: strings.t("tweak.animations")
        detail: strings.t("tweak.animationsDetail")
        checked: !!root.tw && root.tw.animations
        amber: root.c(root.editPal, "accent", root.amber); teal: root.teal
        onToggled: root.set("tweaks." + root.edit + ".animations", !root.tw.animations)
      }
    }

    ThemedSlider {
      width: parent.width
      visible: !!root.tw && root.tw.blur && root.tw.blurBrightness !== undefined
      icon: "󰖙"
      label: strings.t("tweak.blurBrightness")
      valueText: root.tw && root.tw.blurBrightness !== undefined ? root.pct(root.tw.blurBrightness * 100) : ""
      value: root.tw && root.tw.blurBrightness !== undefined ? root.tw.blurBrightness : 0.6
      minimum: 0.2; maximum: 1; step: 0.05
      rangeGradient: true
      fromColor: "#0a0b0d"
      toColor: root.c(root.editPal, "foreground", "#e8dccf")
      onCommitted: function(v) { root.set("tweaks." + root.edit + ".blurBrightness", v) }
    }

    // Night: wallpaper darkness, on a real night wallpaper.
    RowLayout {
      width: parent.width
      visible: root.edit === "night"
      spacing: Style.space(10)
      ThemedSlider {
        Layout.fillWidth: true
        icon: "󰸉"
        label: strings.t("tweak.wallpaperBrightness")
        valueText: root.pct(root.liveNightWall)
        value: root.cfg ? root.cfg.tweaks.night.wallpaperBrightness : 35
        minimum: 10; maximum: 100; step: 5
        rangeGradient: true
        fromColor: "#000000"
        toColor: root.c(root.pal.night, "accent", root.amber)
        onDragged: function(v) { root.liveNightWall = v }
        onCommitted: function(v) { root.set("tweaks.night.wallpaperBrightness", Math.round(v)) }
      }
      Rectangle {
        Layout.preferredWidth: Style.space(70)
        Layout.preferredHeight: Style.space(40)
        color: "black"
        clip: true
        SizedImage {
          anchors.fill: parent
          crop: true
          url: root.nightThumb ? "file://" + root.nightThumb : ""
          opacity: root.liveNightWall / 100
        }
      }
    }

    // Night and Saver: each its own colour temperature (Day stays neutral).
    RowLayout {
      width: parent.width
      visible: root.edit === "night" || root.edit === "saver"
      spacing: Style.space(10)
      readonly property var modeTweaks: root.cfg && root.cfg.tweaks[root.edit] ? root.cfg.tweaks[root.edit] : null
      ThemedSlider {
        id: warmth
        Layout.fillWidth: true
        icon: "󰔄"
        label: strings.t("tweak.warmth")
        valueText: strings.t("tweak.kelvin").arg(Commons.I18n.formatNumber(Math.round(warmth.liveValue)))
        value: parent.modeTweaks && parent.modeTweaks.warmth !== undefined ? parent.modeTweaks.warmth : (root.edit === "night" ? 5000 : 4500)
        minimum: 2500; maximum: 6500; step: 250
        rangeGradient: true
        fromColor: root.kelvin(2500)
        toColor: root.kelvin(6500)
        onCommitted: function(v) { root.set("tweaks." + root.edit + ".warmth", Math.round(v)) }
      }
      Rectangle {
        Layout.preferredWidth: Style.space(70)
        Layout.preferredHeight: Style.space(40)
        radius: Style.space(3)
        color: root.kelvin(warmth.liveValue)
        opacity: 0.85
        Label { anchors.centerIn: parent; text: strings.t("tweak.screen"); color: "#222"; font.pixelSize: Style.font.caption }
      }
    }

    // Saver: what it does to the screen.
    Column {
      width: parent.width
      spacing: Style.space(9)
      visible: root.edit === "saver"
      readonly property var sv: root.cfg ? root.cfg.tweaks.saver : null

      RowLayout {
        width: parent.width
        spacing: Style.space(10)
        ThemedSlider {
          Layout.fillWidth: true
          icon: "󰃠"
          label: strings.t("tweak.backlight")
          valueText: root.pct(root.liveBacklight)
          value: parent.parent.sv ? parent.parent.sv.backlight : 60
          minimum: 5; maximum: 100; step: 5
          rangeGradient: true
          fromColor: "#000000"
          toColor: "#ffffff"
          onDragged: function(v) { root.liveBacklight = v }
          onCommitted: function(v) { root.set("tweaks.saver.backlight", Math.round(v)) }
        }
        // A little sun that fades with it.
        Label {
          Layout.preferredWidth: Style.space(70)
          horizontalAlignment: Text.AlignHCenter
          text: "󰖙"
          font.pixelSize: Style.font.icon * 2
          color: root.amber
          opacity: 0.2 + 0.8 * root.liveBacklight / 100
        }
      }
      Row {
        width: parent.width
        spacing: Style.space(8)
        OptionTile {
          width: (parent.width - parent.spacing) / 2
          icon: "󰌪"
          title: strings.t("tweak.powerSaver")
          detail: strings.t("tweak.powerSaverDetail")
          checked: !!parent.parent.sv && parent.parent.sv.powerSaver
          amber: root.c(root.pal.saver, "accent", root.amber); teal: root.teal
          onToggled: root.set("tweaks.saver.powerSaver", !parent.parent.sv.powerSaver)
        }
        OptionTile {
          width: (parent.width - parent.spacing) / 2
          icon: "󰕰"
          title: strings.t("tweak.opaqueBar")
          detail: strings.t("tweak.opaqueBarDetail")
          checked: !!parent.parent.sv && parent.parent.sv.opaqueBar
          amber: root.c(root.pal.saver, "accent", root.amber); teal: root.teal
          onToggled: root.set("tweaks.saver.opaqueBar", !parent.parent.sv.opaqueBar)
        }
      }

      // Wallpaper: pure black, or a dim still.
      Row {
        id: saverWalls
        width: parent.width
        spacing: Style.space(8)
        readonly property string chosen: parent.sv ? parent.sv.wallpaper : "black"
        Repeater {
          model: ["black", "night"]
          delegate: Rectangle {
            id: wallTile
            required property string modelData
            readonly property bool on: saverWalls.chosen === modelData
            width: (saverWalls.width - saverWalls.spacing) / 2
            height: Style.space(42)
            radius: Style.space(3)
            color: "black"
            border.width: on ? 2 : 1
            border.color: on ? root.amber : Qt.rgba(1, 1, 1, 0.14)
            clip: true
            SizedImage {
              visible: wallTile.modelData === "night"
              anchors.fill: parent
              anchors.margins: parent.border.width
              crop: true
              url: root.nightThumb ? "file://" + root.nightThumb : ""
              opacity: 0.25
            }
            Label {
              anchors.centerIn: parent
              text: strings.t(wallTile.modelData === "black" ? "tweak.wallpaperBlack" : "tweak.wallpaperNight")
              color: wallTile.on ? root.amber : Commons.Color.popups.text
              font.bold: wallTile.on
            }
            HoverHandler { cursorShape: Qt.PointingHandCursor }
            TapHandler { onTapped: root.set("tweaks.saver.wallpaper", wallTile.modelData) }
          }
        }
      }

      Label {
        width: parent.width
        wrapMode: Text.WordWrap
        elide: Text.ElideNone
        opacity: 0.6
        font.pixelSize: Style.font.caption
        text: strings.t("tweak.saverNote")
      }
    }
  }

  component TimeStepper: RowLayout {
    id: stepper
    property string glyph: ""
    property color tone: root.amber
    property string label: ""
    property string value: "00:00"
    signal stepped(string value)
    spacing: Style.space(5)
    Label { text: stepper.glyph; color: stepper.tone }
    Label { text: stepper.label; opacity: 0.75; font.pixelSize: Style.font.caption }
    StepButton { text: "‹"; onClicked: stepper.stepped(root.shift(stepper.value, -30)) }
    Label { text: stepper.value; font.bold: true; color: stepper.tone }
    StepButton { text: "›"; onClicked: stepper.stepped(root.shift(stepper.value, 30)) }
  }

  component StepButton: Rectangle {
    id: step
    property string text: ""
    signal clicked()
    width: Style.space(18); height: Style.space(18)
    radius: Style.space(3)
    color: stepHover.hovered ? Qt.rgba(1, 1, 1, 0.1) : Qt.rgba(1, 1, 1, 0.04)
    border.width: 1
    border.color: Qt.rgba(1, 1, 1, 0.14)
    Label { anchors.centerIn: parent; text: step.text }
    HoverHandler { id: stepHover; cursorShape: Qt.PointingHandCursor }
    TapHandler { onTapped: step.clicked() }
  }
}
