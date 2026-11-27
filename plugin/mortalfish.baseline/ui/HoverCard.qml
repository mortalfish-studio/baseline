import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// The hover readout: a status plate in the film's two lights. Amber is the
// mode and anything nearing its limit; teal is the baseline holding; red is
// off baseline. Each meter carries a tick at its limit.
Column {
  id: root
  property var host: null
  spacing: Style.space(7)

  readonly property color teal: host ? host.themeCyan : Commons.Color.foreground
  readonly property color amber: Commons.Color.accent
  readonly property color red: Commons.Color.urgent
  readonly property color text: Commons.Color.popups.text
  readonly property bool off: !!host && host.offBaseline
  readonly property var st: host ? host.afterState : null

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("../i18n") }

  function n(v, d) { return Commons.I18n.formatNumber(v, d || 0) }

  // ---- Header: the look's name ............ [ NIGHT ]
  RowLayout {
    width: parent.width
    spacing: Style.space(8)
    Label {
      Layout.fillWidth: true
      text: {
          const look = root.st && root.st.looks ? root.st.looks.find(l => l.id === root.st.look) : null
          return look ? strings.t("hover.brandLook").arg(look.name.toUpperCase()) : strings.t("hover.brand")
        }
      font.pixelSize: Style.font.caption
      font.letterSpacing: Style.space(3)
      color: root.amber
      opacity: 0.9
    }
    Rectangle {
      visible: modeLabel.text !== ""
      implicitWidth: modeLabel.implicitWidth + Style.space(12)
      implicitHeight: modeLabel.implicitHeight + Style.space(4)
      color: "transparent"
      border.width: 1
      border.color: root.amber
      radius: Style.cornerRadius > 0 ? Style.space(3) : 0
      Label {
        id: modeLabel
        anchors.centerIn: parent
        text: root.st && root.st.mode !== "other" ? strings.t("mode." + root.st.mode).toUpperCase() : ""
        font.pixelSize: Style.font.caption
        font.letterSpacing: Style.space(2)
        color: root.amber
      }
    }
  }

  // ---- Status: ◇ WITHIN BASELINE, with a hairline that takes its colour
  Column {
    width: parent.width
    spacing: Style.space(4)
    Label {
      text: (root.off ? strings.t("baseline.glyphOff") : strings.t("baseline.glyphWithin")) + "  "
        + strings.t(root.off ? "baseline.headerOff" : "baseline.headerWithin").toUpperCase()
      font.pixelSize: Style.font.subtitle
      font.bold: true
      font.letterSpacing: Style.space(2)
      color: root.off ? root.red : root.teal
    }
    Rectangle {
      width: parent.width
      height: 1
      gradient: Gradient {
        orientation: Gradient.Horizontal
        GradientStop { position: 0; color: root.off ? root.red : root.amber }
        GradientStop { position: 1; color: Qt.rgba(root.teal.r, root.teal.g, root.teal.b, 0.15) }
      }
    }
  }

  // ---- Meters
  Column {
    width: parent.width
    spacing: Style.space(5)

    Meter {
      width: parent.width; teal: root.teal; amber: root.amber; red: root.red; nameWidth: Style.space(52)
      name: strings.t("baseline.cpu")
      value: root.host ? root.host.baselineCpuAvg : -1
      limit: root.host ? root.host.cpuLimit : 85
      alarm: !!root.host && root.host.cpuOff
      reading: root.host ? strings.t("percent").arg(root.n(Math.round(root.host.baselineCpuAvg))) : ""
    }
    Meter {
      width: parent.width; teal: root.teal; amber: root.amber; red: root.red; nameWidth: Style.space(52)
      name: strings.t("baseline.mem")
      value: root.host ? root.host.baselineMemory : -1
      limit: root.host ? root.host.memoryLimit : 90
      alarm: !!root.host && root.host.memoryOff
      reading: root.host ? strings.t("percent").arg(root.n(Math.round(root.host.baselineMemory))) : ""
    }
    Meter {
      width: parent.width; teal: root.teal; amber: root.amber; red: root.red; nameWidth: Style.space(52)
      // 0-100 °C on the bar.
      name: strings.t("baseline.temp")
      value: root.host ? root.host.baselineTemp : -1
      limit: root.host ? root.host.tempLimit : 75
      alarm: !!root.host && root.host.tempOff
      reading: root.host ? strings.t("hover.degrees").arg(root.n(Math.round(root.host.baselineTemp))) : ""
    }
    Meter {
      width: parent.width; teal: root.teal; amber: root.amber; red: root.red; nameWidth: Style.space(52)
      // Disk shows how much is free, so the bar empties as it fills.
      name: strings.t("baseline.disk")
      value: root.host ? root.host.baselineDiskFree : -1
      limit: root.host ? root.host.diskLimit : 10
      low: true
      alarm: !!root.host && root.host.diskOff
      reading: root.host ? strings.t("percent").arg(root.n(Math.round(root.host.baselineDiskFree))) : ""
    }
    Meter {
      width: parent.width; teal: root.teal; amber: root.amber; red: root.red; nameWidth: Style.space(52)
      name: strings.t("baseline.bat")
      value: root.host ? root.host.baselineBattery : -1
      limit: root.host ? root.host.batteryLimit : 15
      low: true
      alarm: !!root.host && root.host.batteryOff
      reading: root.host ? strings.t("percent").arg(root.n(Math.round(root.host.baselineBattery))) : ""
    }

    // A quiet rule between the system and the agents.
    Item {
      width: parent.width
      height: Style.space(7)
      visible: !!root.host && root.host.agentUsage.length > 0
      Rectangle { anchors.verticalCenter: parent.verticalCenter; width: parent.width; height: 1; color: root.text; opacity: 0.12 }
    }

    // Agent subscriptions: each one's fullest limit, with Omarchy's switch
    // threshold as the tick (amber as it nears, red past it).
    Repeater {
      model: root.host ? root.host.agentUsage : []
      delegate: Meter {
        required property var modelData
        readonly property var account: (modelData.accounts || []).find(a => a.active && a.signedIn) || null
        readonly property real peak: account ? Math.max(0, ...(account.limits || []).map(l => l.percent)) * 100 : -1
        visible: !!account
        width: parent.width; teal: root.teal; amber: root.amber; red: root.red; nameWidth: Style.space(52)
        name: String(modelData.name).toUpperCase()
        value: peak
        limit: modelData.threshold || 95
        alarm: peak >= (modelData.threshold || 95)
        reading: strings.t("percent").arg(root.n(Math.round(peak)))
      }
    }
  }

  // ---- Now playing
  Rectangle {
    width: parent.width
    height: 1
    color: root.text
    opacity: 0.12
    visible: nowPlaying.visible || sonosPlaying.visible
  }
  // What's playing: a small cover beside the title and artist.
  RowLayout {
    id: nowPlaying
    readonly property var player: root.host ? root.host.playingPlayer : null
    width: parent.width
    visible: !!player
    spacing: Style.space(8)
    Rectangle {
      Layout.preferredWidth: Style.space(38)
      Layout.preferredHeight: Style.space(38)
      color: "black"
      radius: Style.cornerRadius > 0 ? Style.space(3) : 0
      border.width: 1
      border.color: Qt.rgba(root.amber.r, root.amber.g, root.amber.b, 0.4)
      clip: true
      SizedImage {
        anchors.fill: parent
        anchors.margins: 1
        crop: true
        url: nowPlaying.player && nowPlaying.player.trackArtUrl ? nowPlaying.player.trackArtUrl : ""
        visible: url !== ""
      }
      Label {
        anchors.centerIn: parent
        visible: !nowPlaying.player || !nowPlaying.player.trackArtUrl
        text: "󰎆"
        font.family: "Iosevka Nerd Font Propo"
        color: root.amber
      }
    }
    ColumnLayout {
      Layout.fillWidth: true
      spacing: 0
      Label {
        Layout.fillWidth: true
        text: nowPlaying.player ? nowPlaying.player.trackTitle : ""
        font.pixelSize: Style.font.caption
        font.bold: true
        color: root.amber
      }
      Label {
        Layout.fillWidth: true
        visible: text !== ""
        text: nowPlaying.player ? [nowPlaying.player.trackArtist || "", root.host && (nowPlaying.player.identity === "Chrome" || !nowPlaying.player.identity)
          ? root.host.musicSourceInfo.name : nowPlaying.player.identity || ""].filter(x => x !== "").join(" · ") : ""
        font.pixelSize: Style.font.caption
        opacity: 0.75
      }
      Label {
        Layout.fillWidth: true
        visible: text !== ""
        text: root.host && root.host.laptopOutput ? "󰓃  " + strings.t("hover.playingOn").arg(root.host.laptopOutput) : ""
        font.family: "Iosevka Nerd Font Propo"
        font.pixelSize: Style.font.caption
        color: root.teal
      }
    }
  }
  // And the Sonos room, when one is picked and playing.
  RowLayout {
    id: sonosPlaying
    readonly property var room: root.host ? root.host.sonosNow : null
    readonly property var track: room ? room.track : null
    width: parent.width
    visible: !!room && room.playing && !!track && track.title !== ""
    spacing: Style.space(8)
    Rectangle {
      Layout.preferredWidth: Style.space(38)
      Layout.preferredHeight: Style.space(38)
      color: "black"
      radius: Style.cornerRadius > 0 ? Style.space(3) : 0
      border.width: 1
      border.color: Qt.rgba(root.teal.r, root.teal.g, root.teal.b, 0.4)
      clip: true
      SizedImage {
        anchors.fill: parent
        anchors.margins: 1
        crop: true
        url: sonosPlaying.track && sonosPlaying.track.art ? "file://" + sonosPlaying.track.art : ""
        visible: url !== ""
      }
      Label {
        anchors.centerIn: parent
        visible: !sonosPlaying.track || !sonosPlaying.track.art
        text: "󰜟"
        font.family: "Iosevka Nerd Font Propo"
        color: root.teal
      }
    }
    ColumnLayout {
      Layout.fillWidth: true
      spacing: 0
      Label {
        Layout.fillWidth: true
        textFormat: Text.PlainText
        elide: Text.ElideRight
        text: sonosPlaying.track ? sonosPlaying.track.title : ""
        font.pixelSize: Style.font.caption
        font.bold: true
        color: root.amber
      }
      Label {
        Layout.fillWidth: true
        textFormat: Text.PlainText
        elide: Text.ElideRight
        visible: text !== ""
        text: sonosPlaying.track ? sonosPlaying.track.artist || "" : ""
        font.pixelSize: Style.font.caption
        opacity: 0.75
      }
      Label {
        Layout.fillWidth: true
        textFormat: Text.PlainText
        elide: Text.ElideRight
        text: sonosPlaying.room ? "󰜟  " + strings.t("hover.playingIn").arg(sonosPlaying.room.name) : ""
        font.family: "Iosevka Nerd Font Propo"
        font.pixelSize: Style.font.caption
        color: root.teal
      }
    }
  }
  // What the Deck plays next.
  Label {
    width: parent.width
    visible: !!root.host && !!root.host.deckNext
    textFormat: Text.PlainText
    elide: Text.ElideRight
    text: root.host && root.host.deckNext
      ? "󰒭  " + strings.t("hover.deckNext").arg(root.host.deckNext.title + (root.host.deckNext.artist ? " · " + root.host.deckNext.artist : ""))
      : ""
    font.family: "Iosevka Nerd Font Propo"
    font.pixelSize: Style.font.caption
    color: root.amber
    opacity: 0.9
  }


}
