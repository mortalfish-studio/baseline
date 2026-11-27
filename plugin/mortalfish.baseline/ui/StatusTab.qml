import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Status: one card per source, each saying in a line whether it needs you.
// A summary on top counts the cards that do.
//
// Adding a source: give the host (BarWidget) whatever polling it needs, then
// drop another StatusCard below with an icon, title, summary, level and count.
// List it in `attention` if it can need you, so the summary counts it.
Column {
  id: root
  property var host: null
  spacing: Style.space(8)

  readonly property color amber: Commons.Color.accent
  readonly property color teal: host ? host.themeCyan : Commons.Color.foreground
  readonly property var gh: host ? host.github : null
  property var sw: null   // `superwhisper status`, read when the tab opens

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("../i18n") }

  // Only https://github.com/ URLs, handed to xdg-open as an argument.
  function openUrl(url) {
    if (!/^https:\/\/github\.com\/[A-Za-z0-9_.\/-]*$/.test(url)) return
    run(["xdg-open", url])
  }
  function run(argv) {
    root.host.close()
    Quickshell.execDetached(argv)
  }
  function n(v) { return Commons.I18n.formatNumber(v) }
  function ago(ts) {
    const minutes = Math.max(0, Math.round((Date.now() / 1000 - ts) / 60))
    if (minutes < 1) return strings.t("status.agoNow")
    if (minutes < 60) return strings.t("status.agoMin").arg(n(minutes))
    if (minutes < 1440) return strings.t("status.agoHour").arg(n(Math.round(minutes / 60)))
    return strings.t("status.agoDay").arg(n(Math.round(minutes / 1440)))
  }

  Process {
    id: swReader
    command: ["superwhisper", "status"]
    stdout: StdioCollector { onStreamFinished: { try { root.sw = JSON.parse(text) } catch (error) {} } }
  }
  // Baseline itself: new changes on GitHub (fetched at most every 6 hours),
  // and the last health check (written by `afterlight check|repair`).
  property var baselineInfo: null
  property var health: null
  Process {
    id: baselineReader
    command: [root.host ? root.host.afterlightPath : "afterlight", "updates", "--fetch"]
    stdout: StdioCollector { onStreamFinished: { try { root.baselineInfo = JSON.parse(text) } catch (error) {} } }
  }
  Commons.WatchedFile {
    path: Quickshell.env("HOME") + "/.local/state/afterlight/health.json"
    onTextChanged: { try { root.health = JSON.parse(text) } catch (error) { root.health = null } }
  }
  readonly property int baselineBehind: baselineInfo ? baselineInfo.total : 0
  readonly property int healthFailing: health ? health.failing : 0
  Component.onCompleted: { swReader.running = true; baselineReader.running = true; if (host) host.refreshStatus() }

  // ---- What each source says
  readonly property bool updateReady: !!host && host.updateAvailable
  readonly property int ghCount: gh && gh.ok ? gh.reviews.length + gh.notifications : 0
  readonly property string dictPhase: host ? host.dictationPhase : ""

  // Recent notifications, newest first, from the shell's history file. Ones
  // from apps outside the allow list went there without popping up.
  readonly property var shownApps: ["Grok Bot", "T3 Code", "Baseline"]
  property var recent: []
  Commons.WatchedFile {
    path: Quickshell.env("HOME") + "/.local/state/omarchy/notifications/history.json"
    onTextChanged: {
      try {
        const rows = JSON.parse(text)
        root.recent = Array.isArray(rows)
          ? rows.filter(r => r && r.summary).sort((a, b) => (b.ts || 0) - (a.ts || 0)).slice(0, 5) : []
      } catch (error) { root.recent = [] }
    }
  }
  readonly property int recentToday: recent.filter(r => Date.now() / 1000 - (r.ts || 0) < 86400).length
  function appGlyph(app) {
    return app === "T3 Code" ? "󰚩" : app === "Grok Bot" ? "󰭹" : app === "omasnap" ? "󰄀" : "󰂚"
  }

  readonly property var usage: host ? host.agentUsage : []
  readonly property bool usageHigh: !!host && host.usageHigh
  readonly property bool usageSignedOut: usage.some(p => (p.accounts || []).some(a => a.active && !a.signedIn))
  function untilText(iso) {
    const ms = Date.parse(iso) - Date.now()
    if (!isFinite(ms) || ms <= 0) return ""
    const h = Math.round(ms / 3600000)
    return h < 1 ? strings.t("status.resetsSoon")
      : h < 48 ? strings.t("status.resetsHours").arg(n(h)) : strings.t("status.resetsDays").arg(n(Math.round(h / 24)))
  }

  readonly property var attention: [updateReady, baselineBehind > 0 || healthFailing > 0, ghCount > 0, dictPhase === "offline", usageHigh || usageSignedOut]
  readonly property int needing: attention.filter(Boolean).length

  // ---- Summary: a section title like the other tabs', lit amber while
  // something needs you, with the refresh on its right.
  RowLayout {
    width: parent.width
    spacing: Style.space(6)
    Label {
      Layout.alignment: Qt.AlignTop
      text: root.needing > 0 ? "󰀦" : "󰄬"
      font.family: "Iosevka Nerd Font Propo"
      font.pixelSize: Style.font.caption
      color: root.needing > 0 ? root.amber : root.teal
    }
    Section {
      Layout.fillWidth: true
      title: root.needing > 0 ? strings.tn("status.needing", root.needing).arg(root.n(root.needing)) : strings.t("status.allClear")
      amber: root.needing > 0 ? root.amber : root.teal
      teal: root.teal
    }
    ActionButton {
      icon: "󰑐"
      tone: root.teal
      onClicked: { swReader.running = true; baselineReader.running = true; root.host.refreshStatus() }
    }
  }

  // ---- Omarchy updates
  StatusCard {
    width: parent.width
    amber: root.amber; teal: root.teal
    icon: root.updateReady ? "󰚰" : "󰄬"
    title: strings.t("status.updates")
    summary: strings.t(root.updateReady ? "status.updateReady" : "status.upToDate")
    level: root.updateReady ? "attention" : "ok"
    actions: [
      ActionButton {
        visible: root.updateReady
        icon: "󰚰"
        text: strings.t("status.updateNow")
        tone: root.amber
        onClicked: root.run(["omarchy-launch-floating-terminal-with-presentation", "omarchy-update"])
      }
    ]
  }

  // ---- Baseline: updates from GitHub, and its health
  StatusCard {
    width: parent.width
    amber: root.amber; teal: root.teal
    icon: root.baselineBehind > 0 ? "󰚰" : root.healthFailing > 0 ? "󰦛" : "󰄬"
    title: strings.t("status.baseline")
    summary: root.baselineBehind > 0 ? strings.tn("status.baselineBehind", root.baselineBehind).arg(root.n(root.baselineBehind))
      : root.healthFailing > 0 ? strings.tn("health.failing", root.healthFailing).arg(root.n(root.healthFailing))
      : strings.t("status.baselineOk")
    level: root.baselineBehind > 0 || root.healthFailing > 0 ? "attention" : "ok"
    actions: [
      ActionButton {
        visible: root.baselineBehind > 0
        icon: "󰚰"
        text: strings.t("status.updateNow")
        tone: root.amber
        onClicked: root.run(["omarchy-launch-floating-terminal-with-presentation", (root.host ? root.host.afterlightPath : "afterlight") + " update"])
      },
      ActionButton {
        visible: root.baselineBehind === 0 && root.healthFailing > 0
        icon: "󰦛"
        text: strings.t("health.repair")
        tone: root.amber
        onClicked: root.host.chooseTab("setup")
      }
    ]
  }

  // ---- Agent subscriptions
  StatusCard {
    width: parent.width
    amber: root.amber; teal: root.teal
    icon: "󰚩"
    title: strings.t("status.agents")
    level: root.usage.length === 0 ? "idle" : root.usageSignedOut ? "off" : root.usageHigh ? "attention" : "ok"
    summary: {
      const peak = root.host ? root.host.usagePeak : null
      if (root.usageSignedOut) return strings.t("status.agentsSignedOut")
      if (!peak) return strings.t("status.agentsLoading")
      return strings.t("status.agentsPeak").arg(peak.provider).arg(peak.label.replace(/\s*\(.*\)/, ""))
        .arg(n(Math.round(peak.percent * 100))) + (root.usageHigh && untilText(peak.resetsAt) ? " · " + untilText(peak.resetsAt) : "")
    }

    Repeater {
      model: root.usage
      delegate: Column {
        id: prov
        required property var modelData
        readonly property var account: (modelData.accounts || []).find(a => a.active) || null
        width: parent ? parent.width : 0
        spacing: Style.space(3)
        visible: !!account
        topPadding: Style.space(2)
        RowLayout {
          width: parent.width
          Label { text: prov.modelData.name; font.bold: true; color: root.teal }
          Label {
            Layout.fillWidth: true
            text: prov.account ? (prov.account.signedIn ? prov.account.plan.replace(/_/g, " ") : strings.t("status.signedOut")) : ""
            font.pixelSize: Style.font.caption
            opacity: 0.6
          }
        }
        Repeater {
          model: prov.account ? prov.account.limits : []
          delegate: RowLayout {
            id: lim
            required property var modelData
            readonly property real pct: Math.max(0, Math.min(1, modelData.percent))
            readonly property color tone: pct >= root.host.usageWarn ? root.amber : root.teal
            width: prov.width
            spacing: Style.space(8)
            Label {
              Layout.preferredWidth: Style.space(70)
              text: modelData.label.replace(/\s*\(.*\)/, "")
              font.pixelSize: Style.font.caption
              opacity: 0.8
            }
            Item {
              Layout.fillWidth: true
              implicitHeight: Style.space(6)
              Rectangle { anchors.fill: parent; radius: height / 2; color: Qt.rgba(1, 1, 1, 0.08) }
              Rectangle {
                width: parent.width * lim.pct
                height: parent.height
                radius: height / 2
                color: lim.tone
                Behavior on width { NumberAnimation { duration: Style.duration(240); easing.type: Easing.OutCubic } }
              }
            }
            Label {
              Layout.preferredWidth: Style.space(34)
              horizontalAlignment: Text.AlignRight
              text: strings.t("percent").arg(root.n(Math.round(lim.pct * 100)))
              font.pixelSize: Style.font.caption
              font.bold: true
              color: lim.tone
            }
            Label {
              Layout.preferredWidth: Style.space(62)
              horizontalAlignment: Text.AlignRight
              text: root.untilText(modelData.resetsAt)
              font.pixelSize: Style.font.caption
              opacity: 0.5
            }
          }
        }
      }
    }
  }

  // ---- GitHub
  StatusCard {
    width: parent.width
    amber: root.amber; teal: root.teal
    icon: "󰊤"
    title: strings.t("status.github")
    count: root.ghCount
    level: !root.gh ? "idle" : !root.gh.ok ? "off" : root.ghCount > 0 ? "attention" : "ok"
    summary: !root.gh ? strings.t("status.githubLoading")
      : !root.gh.ok ? strings.t("status.githubError").arg(root.gh.error || "")
      : root.ghCount === 0 ? strings.t("status.githubClear")
      : [root.gh.reviews.length ? strings.tn("status.reviewCount", root.gh.reviews.length).arg(root.n(root.gh.reviews.length)) : "",
         root.gh.notifications ? strings.tn("status.notifCount", root.gh.notifications).arg(root.n(root.gh.notifications)) : ""]
        .filter(Boolean).join(" · ")

    Repeater {
      model: root.gh && root.gh.ok ? root.gh.reviews.slice(0, 5) : []
      delegate: StatusRow {
        required property var modelData
        icon: "󰘬"
        tone: root.amber
        text: modelData.title
        note: modelData.repo.split("/").pop() + " #" + modelData.number
        onClicked: root.openUrl(modelData.url)
      }
    }
    Repeater {
      model: root.gh && root.gh.ok ? root.gh.items.slice(0, 5) : []
      delegate: StatusRow {
        required property var modelData
        icon: "󰊤"
        tone: root.teal
        text: modelData.title
        note: modelData.repo.split("/").pop()
        onClicked: root.openUrl(modelData.url)
      }
    }
    actions: [
      ActionButton {
        icon: "󰊤"
        text: strings.t("status.openGithub")
        tone: root.teal
        onClicked: root.openUrl("https://github.com/notifications")
      }
    ]
  }

  // ---- Superwhisper
  StatusCard {
    width: parent.width
    amber: root.amber; teal: root.teal
    icon: root.dictPhase === "offline" ? "󰍭" : "󰍬"
    title: strings.t("status.dictation")
    level: root.dictPhase === "offline" ? "off" : root.dictPhase === "recording" || root.dictPhase === "processing" ? "attention" : "ok"
    summary: {
      const state = root.dictPhase === "recording" ? strings.t("status.dictRecording")
        : root.dictPhase === "processing" ? strings.t("status.dictProcessing")
        : root.dictPhase === "offline" ? strings.t("status.dictOff") : strings.t("status.dictReady")
      const mode = root.sw && root.sw.workers ? String(root.sw.workers.asr_backend || "") : ""
      const key = root.sw && root.sw.shortcuts ? String(root.sw.shortcuts.toggle || "") : ""
      return [state, mode ? mode.charAt(0).toUpperCase() + mode.slice(1) : "", key].filter(Boolean).join(" · ")
    }
    expanded: false

    StatusRow {
      readonly property string last: root.sw && root.sw.last ? String(root.sw.last.text || "") : ""
      visible: last !== ""
      icon: "󰆏"
      tone: root.teal
      text: "“" + last + "”"
      note: strings.t("status.copyLast")
      onClicked: Quickshell.execDetached(["wl-copy", "--", last])
    }
    actions: [
      ActionButton { icon: "󰋚"; text: strings.t("status.history"); tone: root.teal; onClicked: root.run(["superwhisper", "settings", "history"]) },
      ActionButton { icon: "󰒓"; text: strings.t("status.settings"); tone: root.teal; onClicked: root.run(["superwhisper", "settings"]) }
    ]
  }

  // ---- Recent notifications
  StatusCard {
    width: parent.width
    amber: root.amber; teal: root.teal
    icon: "󰂚"
    title: strings.t("status.recent")
    level: "idle"
    summary: root.recentToday > 0 ? strings.tn("status.recentToday", root.recentToday).arg(root.n(root.recentToday))
      : strings.t("status.recentNone")
    expanded: false

    Repeater {
      model: root.recent
      delegate: StatusRow {
        required property var modelData
        readonly property bool quiet: root.shownApps.indexOf(String(modelData.app || "")) < 0
        icon: root.appGlyph(String(modelData.app || ""))
        tone: quiet ? Commons.Color.popups.text : root.teal
        dim: quiet
        text: modelData.summary + (modelData.body ? " — " + String(modelData.body).split("\n")[0] : "")
        note: root.ago(modelData.ts || 0)
        onClicked: root.run(["omarchy-shell", "notifications", "showHistory"])
      }
    }
    actions: [
      ActionButton { icon: "󰋚"; text: strings.t("status.allNotifications"); tone: root.teal; onClicked: root.run(["omarchy-shell", "notifications", "showHistory"]) }
    ]
  }

  // ---- Your keys: the shortcuts added on this machine, for when they slip.
  StatusCard {
    width: parent.width
    amber: root.amber; teal: root.teal
    icon: "󰌌"
    title: strings.t("status.keys")
    level: "idle"
    summary: strings.t("status.keysSummary")
    expanded: false
    Repeater {
      model: [
        ["Super+Shift+A", "keys.grok"],
        ["Super+Shift+M", "keys.beatport"],
        ["Super+Shift+Y", "keys.youtube"],
        ["Super+Shift+E", "keys.email"],
        ["Super+Shift+/", "keys.passwords"],
        ["Super+1…6", "keys.workspaces"],
        ["Super+Ctrl+1…4", "keys.columns"],
        ["Super+Alt+V (hold)", "keys.voice"],
        ["Super+Alt+T", "keys.type"],
        ["Super+Alt+B", "keys.baseline"],
        ["Super+Alt+O", "keys.swap"],
        ["Super+Alt+H", "keys.like"],
        ["Super+Alt+N", "keys.dnd"],
        ["Super+Ctrl+Alt+F", "keys.focus"],
        ["Ctrl+Alt+Space", "keys.dictate"],
        ["Super+Ctrl+Alt+C", "keys.screenshot"],
        ["Super+Shift+Alt+,", "keys.history"],
        ["Super+Ctrl+Alt+B", "keys.battery"],
        ["Omarchy menu › System", "keys.rescue"]
      ]
      delegate: StatusRow {
        required property var modelData
        clickable: false
        icon: "󰌌"
        tone: root.teal
        text: strings.t(modelData[1])
        note: modelData[0]
      }
    }
  }
}
