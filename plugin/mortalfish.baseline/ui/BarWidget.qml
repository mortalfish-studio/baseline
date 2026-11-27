import QtQuick
import Quickshell
import Quickshell.Services.Pipewire
import Quickshell.Io
import Quickshell.Services.Mpris
import Quickshell.Wayland
import Quickshell.Hyprland
import Quickshell.Services.UPower
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Baseline: the bar's live system readout, and the Afterlight 2049 control
// panel behind it (System, Player, Status, Wallpapers, Theme). Theme changes go
// through the `afterlight` command, which owns settings.json.
BarWidget {
  id: root

  moduleName: "mortalfish.baseline"
  implicitWidth: button.implicitWidth + (statusMark.visible ? statusMark.implicitWidth : 0)
  implicitHeight: button.implicitHeight

  property bool popupOpen: false
  property bool popupLoaded: false
  property string tab: "system"
  property var snapshot: null
  property bool failed: false

  // What `afterlight state` last reported, and whether a change is running.
  property var afterState: null
  property bool afterBusy: false
  property var afterQueue: []
  property string afterError: ""   // the last change's complaint, shown in the panel
  readonly property string afterlightPath: Quickshell.env("HOME") + "/.local/bin/afterlight"
  // Baseline readout: a light sysfs/proc sample every few seconds drives the
  // bar label, independent of the heavier snapshot the card runs. The label
  // shows live figures; off baseline it names only what is out of range.
  property real baselineCpu: -1       // last sample
  property real baselineCpuAvg: -1    // smoothed, so one spike doesn't flip the state
  property real baselineMemory: -1
  property real baselineTemp: -1
  property real baselineBattery: -1
  property string baselineBatteryStatus: ""
  property real baselineDiskFree: -1   // percent of home filesystem free
  property real baselineDiskFreeGib: -1
  property var lastCpuSample: null
  property real drawAvg: 0             // smoothed battery draw in watts
  property real batteryHours: -1       // time left on battery; -1 when not draining

  readonly property real cpuLimit: 85
  readonly property real memoryLimit: 90
  readonly property real tempLimit: 75
  readonly property real batteryLimit: 15
  readonly property real diskLimit: 10      // percent free

  readonly property bool cpuOff: baselineCpuAvg >= cpuLimit
  readonly property bool memoryOff: baselineMemory >= memoryLimit
  readonly property bool tempOff: baselineTemp >= tempLimit
  readonly property bool batteryOff: baselineBattery >= 0 && baselineBattery <= batteryLimit
    && baselineBatteryStatus === "Discharging"
  readonly property bool diskOff: baselineDiskFree >= 0 && baselineDiskFree <= diskLimit
  readonly property bool offBaseline: cpuOff || memoryOff || tempOff || batteryOff || diskOff

  // Off baseline for a full minute: say so once, until it settles again.
  property real offSince: 0
  property bool alerted: false
  onOffBaselineChanged: {
    offSince = offBaseline ? Date.now() : 0
    if (!offBaseline) alerted = false
  }

  function checkAlert() {
    if (!offBaseline || alerted || offSince === 0 || Date.now() - offSince < 60000) return
    alerted = true
    const parts = []
    if (cpuOff) parts.push(strings.t("baseline.lineCpu").arg(baselinePercent(baselineCpu)).arg(baselinePercent(baselineCpuAvg)))
    if (memoryOff) parts.push(strings.t("baseline.lineMem").arg(baselinePercent(baselineMemory)))
    if (tempOff) parts.push(strings.t("baseline.lineTemp").arg(baselinePercent(baselineTemp)))
    if (batteryOff) parts.push(strings.t("baseline.lineBat").arg(baselinePercent(baselineBattery)).arg(baselineBatteryStatus))
    if (diskOff) parts.push(strings.t("baseline.lineDisk").arg(baselinePercent(baselineDiskFree)).arg(Commons.I18n.formatNumber(baselineDiskFreeGib, 1)))
    Quickshell.execDetached(["omarchy-notification-send", "-u", "normal", strings.t("baseline.alertTitle"), parts.join("\n")])
  }

  function baselinePercent(value) {
    return Commons.I18n.formatNumber(Math.round(value))
  }

  // Figure-space padding keeps the label from jittering the bar as digits change.
  function padded(value) {
    const text = baselinePercent(value)
    return text.length < 2 ? " " + text : text
  }

  function labelPart(nameKey, value, isTemp) {
    return strings.t(isTemp ? "baseline.labelTemp" : "baseline.labelPercent")
      .arg(strings.t(nameKey)).arg(padded(value))
  }

  // The bar's clock lives here now: "Thu 21:01" at the end of the readout.
  property date now: new Date()
  Timer {
    // Wake just after each minute turns, then every minute.
    interval: 60000 - (Date.now() % 60000) + 50
    running: true
    repeat: true
    onTriggered: { root.now = new Date(); interval = 60000 - (Date.now() % 60000) + 50 }
  }
  readonly property string clockText: now.toLocaleString(Qt.locale(Commons.I18n.formatLocale), "ddd HH:mm")
  readonly property string clockTextVertical: now.toLocaleString(Qt.locale(Commons.I18n.formatLocale), "HH:mm")

  // The bar's battery lives here now: a level glyph while draining (with the
  // time left), a bolt while charging, a plug when full on the charger.
  readonly property string batteryGlyph: {
    if (baselineBattery < 0) return ""
    if (baselineBatteryStatus === "Charging") return "󰂄"
    if (baselineBatteryStatus !== "Discharging") return "󰚥"
    const levels = ["󰂎", "󰁺", "󰁻", "󰁼", "󰁽", "󰁾", "󰁿", "󰂀", "󰂁", "󰂂", "󰁹"]
    return levels[Math.max(0, Math.min(10, Math.round(baselineBattery / 10)))]
  }
  readonly property string batteryText: {
    if (batteryGlyph === "") return ""
    let text = batteryGlyph + " " + strings.t("percent").arg(baselinePercent(baselineBattery))
    if (batteryHours >= 0) {
      const minutes = Math.round(batteryHours * 60)
      text += " " + strings.t("baseline.labelTime").arg(Commons.I18n.formatNumber(Math.floor(minutes / 60)))
        .arg(String(minutes % 60).padStart(2, "0"))
    }
    return text
  }

  readonly property string barLabel: readout + (root.bar && root.bar.vertical ? "\n" + clockTextVertical : "   " + clockText)
  readonly property string readout: {
    if (dictationPhase === "recording") return strings.t("status.barDictating")
    if (dictationPhase === "processing") return strings.t("relay.barTranscribing")
    if (voicePhase === "listening") return strings.t("relay.barListening")
    if (voicePhase === "processing") return strings.t("relay.barTranscribing")
    if (baselineCpuAvg < 0 && baselineMemory < 0) return strings.t("baseline.glyphWithin")
    if (root.bar && root.bar.vertical) {
      const glyph = strings.t(offBaseline ? "baseline.glyphOff" : "baseline.glyphWithin")
      const lead = diskOff ? baselineDiskFree : tempOff ? baselineTemp : batteryOff ? baselineBattery
        : memoryOff && !cpuOff ? baselineMemory : Math.max(baselineCpuAvg, 0)
      return glyph + "\n" + baselinePercent(lead)
    }
    const parts = []
    if (!offBaseline || cpuOff) parts.push(labelPart("baseline.cpu", Math.max(baselineCpuAvg, 0), false))
    if (!offBaseline || memoryOff) parts.push(labelPart("baseline.mem", Math.max(baselineMemory, 0), false))
    if (tempOff) parts.push(labelPart("baseline.temp", baselineTemp, true))
    if (batteryText !== "") parts.push(batteryText)
    if (diskOff) parts.push(labelPart("baseline.disk", baselineDiskFree, false))
    return strings.t(offBaseline ? "baseline.glyphOff" : "baseline.glyphWithin") + " " + parts.join("  ")
  }

  function parseBaseline(text) {
    const lines = text.split("\n")
    const fields = lines[0].trim().split(/\s+/).slice(1, 9).map(Number)
    if (fields.length === 8 && fields.every(n => isFinite(n))) {
      const total = fields.reduce((a, b) => a + b, 0)
      const idle = fields[3] + fields[4]
      if (root.lastCpuSample && total > root.lastCpuSample.total) {
        const dt = total - root.lastCpuSample.total
        const cpu = Math.max(0, Math.min(100, 100 * (dt - (idle - root.lastCpuSample.idle)) / dt))
        root.baselineCpu = cpu
        root.baselineCpuAvg = root.baselineCpuAvg < 0 ? cpu : root.baselineCpuAvg * 0.6 + cpu * 0.4
      }
      root.lastCpuSample = { total: total, idle: idle }
    }
    let batteryMicroWatts = NaN, batteryMicroWattHours = NaN
    let memTotal = 0, memAvailable = 0, temp = -1, battery = -1, batteryStatus = ""
    for (const line of lines) {
      if (line.startsWith("MemTotal:")) memTotal = Number(line.split(/\s+/)[1])
      else if (line.startsWith("MemAvailable:")) memAvailable = Number(line.split(/\s+/)[1])
      else if (line.startsWith("THERM ")) {
        const milli = Number(line.split(/\s+/)[2])
        if (milli > 0 && milli < 150000) temp = Math.max(temp, milli / 1000)
      } else if (line.startsWith("BATCAP ")) battery = Number(line.split(/\s+/)[1])
      else if (line.startsWith("BATSTAT ")) batteryStatus = line.slice(8).trim()
      else if (line.startsWith("BATPOW ")) batteryMicroWatts = Number(line.split(/\s+/)[1])
      else if (line.startsWith("BATENERGY ")) batteryMicroWattHours = Number(line.split(/\s+/)[1])
      else if (line.startsWith("DISK ")) {
        const d = line.split(/\s+/).map(Number)
        if (d[2] > 0) {
          root.baselineDiskFree = 100 * d[1] / d[2]
          root.baselineDiskFreeGib = d[1] / (1024 * 1024)
        }
      }
    }
    if (memTotal > 0) root.baselineMemory = Math.max(0, Math.min(100, 100 * (memTotal - memAvailable) / memTotal))
    root.baselineTemp = temp
    root.baselineBattery = isFinite(battery) ? battery : -1
    root.baselineBatteryStatus = batteryStatus
    if (isFinite(batteryMicroWatts)) {
      const watts = Math.abs(batteryMicroWatts) / 1e6
      // Hours left on battery: stored energy over a smoothed draw, so a
      // brief spike doesn't swing the estimate.
      if (batteryStatus === "Discharging" && watts > 0.3 && batteryMicroWattHours > 0) {
        root.drawAvg = root.drawAvg > 0 ? root.drawAvg * 0.85 + watts * 0.15 : watts
        const hours = batteryMicroWattHours / 1e6 / root.drawAvg
        root.batteryHours = hours > 0 && hours < 48 ? hours : -1
      } else {
        root.drawAvg = 0
        root.batteryHours = -1
      }
    }
    root.checkAlert()
  }

  Process {
    id: baselineSampler
    command: ["sh", "-c",
      "cat /proc/stat /proc/meminfo; " +
      "for z in /sys/class/thermal/thermal_zone*; do t=$(cat $z/type 2>/dev/null); " +
      "case $t in cpu*|x86_pkg_temp*|soc_thermal*) echo \"THERM $t $(cat $z/temp 2>/dev/null)\";; esac; done; " +
      "for b in /sys/class/power_supply/*; do [ \"$(cat $b/type 2>/dev/null)\" = Battery ] || continue; " +
      "echo \"BATCAP $(cat $b/capacity)\"; echo \"BATSTAT $(cat $b/status)\"; " +
      "echo \"BATPOW $(cat $b/power_now 2>/dev/null)\"; echo \"BATENERGY $(cat $b/energy_now 2>/dev/null)\"; break; done; " +
      "df -Pk \"$HOME\" | awk 'NR==2 {print \"DISK\", $4, $2}'"]
    stdout: StdioCollector { onStreamFinished: root.parseBaseline(text) }
  }

  // Every 4 s while the panel or hover card is up, every 10 s otherwise.
  Timer {
    interval: root.popupOpen || root.hoverOpen ? 4000 : 10000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: if (!baselineSampler.running) baselineSampler.running = true
  }


  // ---- Afterlight control

  // A change made while a read is running needs a fresh read after it.
  property bool refreshPending: false
  function refreshAfterlight() {
    if (afterStateReader.running) refreshPending = true
    else afterStateReader.running = true
  }

  // Run `afterlight <args>`, one at a time, then re-read its state.
  function afterlight(args) {
    afterQueue = afterQueue.concat([args])
    runNextAfterlight()
  }

  function runNextAfterlight() {
    if (afterRunner.running || afterQueue.length === 0) return
    const next = afterQueue[0]
    afterQueue = afterQueue.slice(1)
    afterBusy = true
    afterError = ""
    afterRunner.command = [afterlightPath].concat(next)
    afterRunner.running = true
  }

  Process {
    id: afterRunner
    stderr: StdioCollector {
      onStreamFinished: {
        const message = text.trim().split("\n").pop() || ""
        if (message !== "") root.afterError = message.slice(0, 240)
      }
    }
    onExited: {
      root.afterBusy = root.afterQueue.length > 0
      root.refreshAfterlight()
      root.runNextAfterlight()
    }
  }

  Process {
    id: afterStateReader
    command: [root.afterlightPath, "state"]
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          const parsed = JSON.parse(text)
          if (parsed && typeof parsed === "object") root.afterState = parsed
        } catch (error) {}
      }
    }
    onExited: if (root.refreshPending) { root.refreshPending = false; root.refreshAfterlight() }
  }

  // The firmware may forget the charge limit across a restart; put it back.
  Component.onCompleted: {
    refreshAfterlight()
    Quickshell.execDetached([afterlightPath, "battery", "apply"])
  }

  // The last tab opened survives restarts: it lives in settings.json.
  property bool tabRestored: false
  onAfterStateChanged: {
    if (afterState && afterState.settings.deck && afterState.settings.deck.home && !deckWanted) {
      deckSilent = true
      deckWanted = true
    }
    if (tabRestored || !afterState || !afterState.settings.ui) return
    tabRestored = true
    if (!popupOpen && tabNames.indexOf(afterState.settings.ui.tab) >= 0) tab = afterState.settings.ui.tab
  }

  function chooseTab(name) {
    if (tab === name) return
    tab = name
    tabRestored = true
    // Remembered quietly: no busy spinner for a tab click.
    Quickshell.execDetached([afterlightPath, "set", "ui.tab", name])
  }

  readonly property var afterSettings: afterState ? afterState.settings : null

  // Wallpaper cycling, only while a period is set.
  Timer {
    interval: Math.max(1, root.afterSettings ? root.afterSettings.wallpapers.cycleMinutes : 0) * 60000
    repeat: true
    running: !!root.afterSettings && root.afterSettings.wallpapers.cycleMinutes > 0
    onTriggered: root.afterlight(["wallpaper", "next"])
  }

  // Scroll over the readout for volume (with Omarchy's OSD).
  WheelHandler {
    acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
    property real pending: 0
    onWheel: function(event) {
      pending += event.angleDelta.y
      if (Math.abs(pending) < 120) return
      root.bar.run(Quickshell.env("HOME") + "/.local/bin/baseline-volume " + (pending > 0 ? "raise" : "lower"))
      pending = 0
    }
  }

  // ---- Panel

  function close() {
    popupOpen = false
  }

  function refresh() {
    if (!sampler.running) sampler.running = true
  }

  function openTab(name) {
    chooseTab(name)
    popupLoaded = true
    popupOpen = true
  }

  onPopupOpenChanged: {
    if (popupOpen) hoverOpen = false
    if (!popupOpen) return
    refresh()
    refreshAfterlight()
    if (tab === "status") refreshStatus()
  }

  Commons.Translations {
    id: strings
    directory: Qt.resolvedUrl("../i18n")
  }

  WidgetButton {
    id: button
    anchors.left: parent.left
    anchors.top: parent.top
    anchors.bottom: parent.bottom
    width: implicitWidth
    bar: root.bar
    text: root.barLabel
    fontSize: Style.font.body * 0.9
    tooltipText: ""
    active: true
    activeColor: root.voicePhase !== "ready" || root.dictationBusy ? root.themeCyan
      : root.offBaseline ? Commons.Color.urgent : Commons.Color.accent
    dimmed: false
    pressFeedbackButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
    onPressed: function(mouseButton) {
      if (mouseButton === Qt.MiddleButton) {
        root.openRelayWindow("compose")
        return
      }
      if (mouseButton === Qt.RightButton) {
        root.close()
        root.bar.run("omarchy-launch-or-focus-tui btop")
        return
      }
      if (mouseButton !== Qt.LeftButton) return
      root.popupLoaded = true
      root.popupOpen = !root.popupOpen
    }
  }

  // omarchy-shell mortalfish.baseline open [system|player|wallpapers|theme]
  Commons.ShellIpc {
    target: "mortalfish.baseline"
    function open(): void { root.openTab(root.tab) }
    function openTab(name: string): void {
      root.openTab(root.tabNames.indexOf(name) >= 0 ? name : "system")
    }
    function toggle(): void {
      root.popupLoaded = true
      root.popupOpen = !root.popupOpen
    }
    // Baseline Studio: the picture library or the look maker.
    function studio(page: string): void { root.openStudio(page === "looks" || page === "browse" ? page : "library") }
    // The Deck: the set of songs to arrange, play and send to a room.
    function deck(): void { root.openDeck() }
    // Scroll the open tab to a fraction (0-1) of its height: for screenshots.
    function scroll(fraction: real): void { root.scrollRequest = fraction; root.scrollRequestChanged() }
  }
  property real scrollRequest: 0

  // The fuller System figures refresh only while that tab is on show.
  Timer {
    interval: 3000
    repeat: true
    running: root.popupOpen && root.tab === "system"
    onTriggered: root.refresh()
  }

  Process {
    id: sampler
    command: ["python3", "-B", decodeURIComponent(Qt.resolvedUrl("../snapshot.py").toString().replace(/^file:\/\//, ""))]
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root.snapshot = null
        root.failed = true
      }
    }
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          root.snapshot = JSON.parse(text)
          root.failed = false
        } catch (error) {
          root.snapshot = null
          root.failed = true
        }
      }
    }
  }

  // ---- T3 Code alerts
  // No agent display any more: `afterlight agents` is polled only so that a
  // thread finishing or waiting raises a "T3 Code" notification.
  property bool agentsLive: false

  Process {
    id: agentsReader
    command: [root.afterlightPath, "agents"]
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          const c = JSON.parse(text).counts
          root.agentsLive = !!c && c.working + c.waiting > 0
        } catch (error) {}
      }
    }
  }

  // Every 10 s while an agent works or waits, every 60 s otherwise.
  Timer {
    interval: root.agentsLive ? 10000 : 60000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: if (!agentsReader.running) agentsReader.running = true
  }

  // ---- Charger in or out: let afterlight pick the mode (Saver on battery,
  // when that's switched on in the Theme tab; back to Day/Night on the charger).
  // Only a real plug or unplug counts: UPower settling while the shell starts
  // would otherwise undo a mode picked by hand.
  readonly property bool onBattery: UPower.onBattery
  property bool chargerSettled: false
  Timer { interval: 8000; running: true; onTriggered: root.chargerSettled = true }
  onOnBatteryChanged: {
    if (!chargerSettled) return
    afterlight(["mode", "auto"])
  }

  // ---- Sleep after 30 idle minutes on battery (video and other inhibitors
  // hold it off, as they hold off the lock). On the charger it stays awake.
  IdleMonitor {
    timeout: 1800
    respectInhibitors: true
    enabled: root.onBattery
    onIsIdleChanged: if (isIdle && root.onBattery) Quickshell.execDetached(["systemctl", "suspend"])
  }

  // ---- Video keeps the screen awake
  // While something plays and you're on the video workspace, hold off the
  // screensaver and lock. Music on its own still lets the screen lock.
  readonly property bool anyPlaying: {
    const list = Mpris.players ? Mpris.players.values : []
    for (const p of list) if (p && p.isPlaying) return true
    return false
  }
  IdleInhibitor {
    window: root.QsWindow.window
    enabled: root.anyPlaying && !!Hyprland.focusedWorkspace && Hyprland.focusedWorkspace.id === 5
  }

  // ---- Status: Omarchy updates, GitHub, Superwhisper dictation
  // These used to be their own bar icons.
  property bool updateAvailable: false
  property var github: null
  readonly property int githubWaiting: github && github.ok ? github.notifications + github.reviews.length : 0
  property var dictation: null          // the last `superwhisper status --bar` line
  readonly property string dictationPhase: dictation ? String(dictation.alt || dictation["class"] || "") : ""
  readonly property bool dictationBusy: dictationPhase === "recording" || dictationPhase === "processing"

  // Agent subscriptions (Claude, Codex, Grok) and how full each limit is,
  // from Omarchy's own account tracker.
  property var agentUsage: []
  readonly property real usageWarn: 0.8
  readonly property var usagePeak: {
    let best = null
    for (const p of agentUsage) for (const a of (p.accounts || [])) {
      if (!a.active) continue
      for (const l of (a.limits || []))
        if (!best || l.percent > best.percent) best = { provider: p.name, label: l.label, percent: l.percent, resetsAt: l.resetsAt }
    }
    return best
  }
  readonly property bool usageHigh: !!usagePeak && usagePeak.percent >= usageWarn
  Process {
    id: usageReader
    // Refresh the limits first: Omarchy's own Agents widget, which normally
    // does it, isn't on the bar, so the records would otherwise go stale.
    command: ["sh", "-c", "omarchy-agent-usage-update --limits-only claude codex grok >/dev/null 2>&1; omarchy agent account list --json"]
    stdout: StdioCollector {
      onStreamFinished: { try { const v = JSON.parse(text); if (Array.isArray(v)) root.agentUsage = v } catch (error) {} }
    }
  }
  Timer { interval: 600000; running: true; repeat: true; triggeredOnStart: true; onTriggered: if (!usageReader.running) usageReader.running = true }

  function refreshStatus() {
    if (!usageReader.running) usageReader.running = true
    if (!updateCheck.running) updateCheck.running = true
    if (!githubReader.running) githubReader.running = true
  }

  Process {
    id: updateCheck
    command: ["omarchy-update-available"]
    onExited: function(exitCode) { root.updateAvailable = exitCode === 0 }
  }
  Timer { interval: 21600000; running: true; repeat: true; triggeredOnStart: true; onTriggered: if (!updateCheck.running) updateCheck.running = true }

  Process {
    id: githubReader
    command: ["python3", "-I", "-B", decodeURIComponent(Qt.resolvedUrl("../github.py").toString().replace(/^file:\/\//, ""))]
    stdout: StdioCollector {
      onStreamFinished: { try { root.github = JSON.parse(text) } catch (error) { root.github = { ok: false, error: strings.t("status.githubBadOutput") } } }
    }
  }
  Timer { interval: 300000; running: true; repeat: true; triggeredOnStart: true; onTriggered: if (!githubReader.running) githubReader.running = true }

  // Superwhisper streams one JSON line per change; restart it if it stops.
  Process {
    id: dictationFollow
    command: ["superwhisper", "status", "--bar", "--follow"]
    running: true
    stdout: SplitParser {
      onRead: function(line) { try { root.dictation = JSON.parse(line) } catch (error) {} }
    }
    onExited: dictationRestart.start()
  }
  Timer { id: dictationRestart; interval: 10000; onTriggered: dictationFollow.running = true }

  // The mark beside the readout, only when something needs you.
  readonly property string statusMarkText: {
    const parts = []
    if (updateAvailable) parts.push("󰚰")
    if (githubWaiting > 0) parts.push("󰊤 " + Commons.I18n.formatNumber(githubWaiting))
    if (dictationPhase === "offline") parts.push("󰍭")
    if (usageHigh) parts.push("󰚩 " + Commons.I18n.formatNumber(Math.round(usagePeak.percent * 100)) + "%")
    return parts.join("  ")
  }

  WidgetButton {
    id: statusMark
    anchors.left: button.right
    anchors.top: parent.top
    anchors.bottom: parent.bottom
    width: implicitWidth
    visible: root.statusMarkText !== "" && !(root.bar && root.bar.vertical)
    bar: root.bar
    text: root.statusMarkText
    fontSize: Style.font.body * 0.9
    tooltipText: ""
    active: true
    activeColor: root.themeCyan
    dimmed: false
    onPressed: function(mouseButton) {
      if (mouseButton !== Qt.LeftButton) return
      if (root.popupOpen && root.tab === "status") { root.close(); return }
      root.openTab("status")
    }
  }

  // ---- Hover card

  // The theme's teal, which the shell's palette doesn't carry.
  property color themeCyan: Commons.Color.foreground
  FileView {
    path: Quickshell.env("HOME") + "/.local/state/omarchy/current/theme/colors.toml"
    watchChanges: true
    onFileChanged: reload()
    onLoaded: {
      const match = /^\s*cyan\s*=\s*"(#[0-9a-fA-F]{6})"/m.exec(text())
      if (match) root.themeCyan = match[1]
    }
  }

  // The Deck: is it playing, and what's next (for the hover card).
  property var deckState: null
  readonly property var deckNext: deckState && deckState.playing && deckState.set && deckState.set.length ? deckState.set[0] : null
  Commons.WatchedFile {
    path: Quickshell.env("HOME") + "/.local/state/afterlight/deck.json"
    onTextChanged: { try { root.deckState = JSON.parse(text) } catch (error) {} }
  }

  // Where the music is coming from (the browser add-on reports the tab that
  // starts making sound): "beatport", "ytmusic", "applemusic" or "youtube".
  property string musicSource: "beatport"
  Commons.WatchedFile {
    path: Quickshell.env("HOME") + "/.local/state/afterlight/source.json"
    onTextChanged: {
      try { const v = JSON.parse(text); if (["beatport", "ytmusic", "applemusic", "youtube"].indexOf(v.site) >= 0) root.musicSource = v.site }
      catch (error) {}
    }
  }
  readonly property var musicSources: ({
    beatport: { name: "Beatport", icon: "󰝚", cls: "chrome-jopilafkghibglefecikcmpaoolnpcjg-Default",
                launch: "gtk-launch chrome-jopilafkghibglefecikcmpaoolnpcjg-Default" },
    ytmusic: { name: "YouTube Music", icon: "󰗃", cls: "chrome-music.youtube.com__-Default",
               launch: "omarchy-launch-webapp https://music.youtube.com/" },
    applemusic: { name: "Apple Music", icon: "󰀵", cls: "chrome-music.apple.com__-Default",
                  launch: "omarchy-launch-webapp https://music.apple.com/" },
    youtube: { name: "YouTube", icon: "󰗃", cls: "chrome-youtube.com__-Default",
               launch: "omarchy-launch-webapp https://youtube.com/" }
  })
  readonly property var musicSourceInfo: musicSources[musicSource] || musicSources.beatport
  function openMusicSource() {
    const info = musicSourceInfo
    close()
    Quickshell.execDetached(["sh", "-c",
      "hyprctl dispatch 'hl.dsp.focus({ window = \"class:" + info.cls + "\" })' | grep -q ok || " + info.launch])
  }
  // Where the laptop's sound goes (for the hover card): the default output's
  // name, tidied like the Player tab's ("Speaker", "Headphones").
  PwObjectTracker { objects: Pipewire.defaultAudioSink ? [Pipewire.defaultAudioSink] : [] }
  readonly property string laptopOutput: {
    const sink = Pipewire.defaultAudioSink
    const name = sink ? (sink.description || sink.nickname || sink.name || "") : ""
    return name.replace(/^Built-in Audio\s+/, "").replace(/\s+playback$/i, "")
  }
  // The Sonos room the Player tab controls, and what it's playing, read when
  // the hover card opens (only while a room is picked).
  property var sonosNow: null
  Process {
    id: sonosNowReader
    command: [root.afterlightPath, "sonos", "state"]
    stdout: StdioCollector {
      onStreamFinished: {
        try { const v = JSON.parse(text); root.sonosNow = v && v.on && v.room ? v.room : null }
        catch (error) { root.sonosNow = null }
      }
    }
  }
  onHoverOpenChanged: if (hoverOpen && !sonosNowReader.running) sonosNowReader.running = true
  readonly property var playingPlayer: {
    const list = Mpris.players ? Mpris.players.values : []
    for (const p of list) if (p && p.isPlaying && p.trackTitle) return p
    return null
  }

  // ---- A new track: a popup with its cover, title and "artist · source".
  // Waits a moment for the cover to arrive; pausing and resuming the same
  // track, and the shell starting up, don't count.
  readonly property string trackKey: playingPlayer ? playingPlayer.trackTitle + "|" + (playingPlayer.trackArtist || "") : ""
  property string trackShown: ""
  property bool trackWatchReady: false
  Timer { interval: 6000; running: true; onTriggered: { root.trackWatchReady = true; root.trackShown = root.trackKey } }
  onTrackKeyChanged: if (trackWatchReady && trackKey !== "") trackSettle.restart()
  Timer {
    id: trackSettle
    interval: 800
    onTriggered: {
      const p = root.playingPlayer
      if (!p || root.trackKey === "" || root.trackKey === root.trackShown) return
      root.trackShown = root.trackKey
      const from = p.identity === "Chrome" || !p.identity ? root.musicSourceInfo.name : p.identity
      // Both popups sit at the top: take over from "Next track" rather than stack on it.
      Quickshell.execDetached(["omarchy-shell", "osd", "close"])
      trackToast.show(p.trackTitle, [p.trackArtist || "", from].filter(x => x !== "").join(" · "), p.trackArtUrl || "")
    }
  }
  TrackToast { id: trackToast }
  // Music messages from afterlight (Send to Sonos, the Grok agent's Sonos
  // replies) in the same popup: afterlight writes toast.json.
  property real toastSeen: Date.now() / 1000      // older ones (from before start-up) aren't shown
  Commons.WatchedFile {
    path: Quickshell.env("HOME") + "/.local/state/afterlight/toast.json"
    onTextChanged: {
      try {
        const v = JSON.parse(text)
        if (!v || typeof v.at !== "number") return
        if (v.at <= root.toastSeen || Date.now() / 1000 - v.at > 30) return
        root.toastSeen = v.at
        Quickshell.execDetached(["omarchy-shell", "osd", "close"])
        trackToast.show(String(v.title || ""), String(v.detail || ""),
                        /^file:\/\//.test(v.art || "") ? v.art : "", String(v.glyph || ""))
      } catch (error) {}
    }
  }

  // A short rest before it shows, so passing over the bar doesn't flash it.
  property bool hoverOpen: false
  HoverHandler { id: widgetHover }
  readonly property bool hovering: (widgetHover.hovered || button.tooltipHovered || statusMark.tooltipHovered) && !popupOpen
  onHoveringChanged: {
    if (hovering) { hoverDelay.restart(); refreshAfterlight() }
    else { hoverDelay.stop(); hoverOpen = false }
  }
  Timer { id: hoverDelay; interval: 380; onTriggered: root.hoverOpen = root.hovering }

  // Its own popout identity, so it never closes the click panel's.
  QtObject {
    id: hoverOwner
    function close() { root.hoverOpen = false }
  }

  Loader {
    active: root.bar !== null && (root.hoverOpen || hoverLoaded)
    property bool hoverLoaded: false
    onActiveChanged: if (active) hoverLoaded = true
    sourceComponent: PopupCard {
      id: hoverPopup
      anchorItem: root
      bar: root.bar
      owner: hoverOwner
      triggerMode: "hover"
      open: root.hoverOpen
      contentWidth: hoverPopup.fittedContentWidth(Style.space(300))
      contentHeight: hoverPopup.fittedContentHeight(hoverCard.implicitHeight)

      // Your shell.toml keeps flyouts at 82% for glass; Baseline is read
      // closely, so it lays a backing under its content to sit near-solid.
      CardBacking { pad: hoverPopup.padding }

      HoverCard {
        id: hoverCard
        width: parent.width
        host: root
      }
    }
  }

  Loader {
    active: root.popupLoaded && root.bar !== null
    sourceComponent: PopupCard {
      id: popup
      anchorItem: root
      bar: root.bar
      owner: root
      open: root.popupOpen
      contentWidth: popup.fittedContentWidth(Style.space(430))
      contentHeight: popup.fittedContentHeight(panel.implicitHeight)

      // Your shell.toml keeps flyouts at 82% for glass; Baseline is read
      // closely, so it lays a backing under its content to sit near-solid.
      CardBacking { pad: popup.padding }

      BaselinePanel {
        id: panel
        width: parent.width
        host: root
      }
    }
  }

  // Baseline Studio: made on first use, kept while open.
  property bool studioWanted: false
  property string studioPage: "library"
  function openStudio(page) {
    studioPage = page || "library"
    close()
    if (studioWanted && studioLoader.item) studioLoader.item.show(studioPage)
    else studioWanted = true
  }
  Loader {
    id: studioLoader
    active: root.studioWanted
    source: "Studio.qml"
    onLoaded: {
      item.host = root
      item.show(root.studioPage)
    }
  }

  // The Deck: made on first use, kept while open.
  // It lives on workspace 7 (made quietly at start, unless deck.home is off);
  // opening it from anywhere else pops it up there.
  property bool deckWanted: false
  property bool deckSilent: false
  function openDeck() {
    close()
    deckSilent = false
    if (deckWanted && deckLoader.item) deckLoader.item.show(false)
    else deckWanted = true
  }
  Loader {
    id: deckLoader
    active: root.deckWanted
    source: "Deck.qml"
    onLoaded: {
      item.host = root
      item.show(root.deckSilent)
    }
  }

  // The panel's tabs, in order (BaselinePanel draws them).
  readonly property var tabNames: ["system", "player", "status", "wallpapers", "theme", "setup"]

  // ---- OmaRelay voice state
  // The push-to-talk engine lives in the OmaRelay checkout; the readout turns
  // teal and says LISTENING / TRANSCRIBING while it works.
  readonly property string relayPath: Quickshell.env("HOME") + "/.local/bin/omarchy-voice-nav"
  property string voicePhase: "ready"
  property double voiceExpiry: 0

  function updateVoice() {
    try {
      const status = JSON.parse(voiceStatus.text)
      voiceExpiry = Number(status.until)
      voicePhase = voiceExpiry > Date.now() && ["listening", "processing"].includes(status.phase) ? status.phase : "ready"
    } catch (error) {
      voicePhase = "ready"
    }
  }

  Commons.WatchedFile {
    id: voiceStatus
    path: Quickshell.env("XDG_RUNTIME_DIR") + "/omarchy-voice-nav.status"
    onTextChanged: Qt.callLater(root.updateVoice)
  }

  Timer {
    interval: 500
    repeat: true
    running: root.voicePhase !== "ready"
    onTriggered: if (Date.now() >= root.voiceExpiry) root.voicePhase = "ready"
  }

  // Middle click: OmaRelay's typed-request box.
  function openRelayWindow(action) {
    close()
    Quickshell.execDetached([relayPath, action])
  }
}
