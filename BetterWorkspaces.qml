import QtQuick
import QtQuick.Effects
import QtQuick.Layouts
import QtQuick.Shapes
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import qs.Commons
import qs.Ui

// BetterWorkspaces: workspace indicators with icons for the apps open on each
// workspace. Based on the built-in omarchy.workspaces widget.
//
// Left-click a workspace to focus it, right-click to open the settings menu.
//
// shell.json settings on the layout entry (all optional, all set by the menu):
//   iconSize    (int,  default ~half bar size + 1) - icon size in px
//   padding     (int,  default 3)      - extra space either side inside the pill
//   emptyStyle  ("dots" | "numbers", default "dots") - unused workspace marker
//   workspaces  ("dynamic" | 1-10, default 5) - how many workspaces to show;
//               dynamic shows only occupied + focused ones
//   showIcons   (bool, default true)   - show app icons
//   maxIcons    (int,  default 4)      - icons per workspace before "+N"
//   dedupe      (bool, default true)   - one icon per app, not per window
//   activeColor (string, default theme accent) - active workspace border colour
//   showActivity (bool, default true)  - circulating border while something runs
//   showBadges  (bool, default true)   - dot when something finished or wants attention
//   badgeNotifications (bool, default true) - notifications raise the dot
//   herdr       (bool, default true)   - read agent status from herdr
//   diskActivity (bool, default true)  - downloads and other heavy disk writes
//   badgeColor  (string, default "#ff4d4f") - dot colour
//
// Activity sources:
//   - herdr agents (`herdr api snapshot`): working -> running; done/blocked -> dot.
//     Mapped to the terminal window hosting the herdr client.
//   - Apps writing over 1 MB/s to disk -> running, labelled "Downloading" when
//     they are also receiving over the network (see disk-activity.sh);
//     finishing on an unfocused workspace -> dot.
//   - Window titles starting with a spinner glyph (Claude Code and similar
//     TUIs) -> running; the spinner stopping on an unfocused workspace -> dot.
//   - Hyprland urgent events and shell notifications from an app on an
//     unfocused workspace -> dot, cleared when that workspace is visited.
Panel {
  id: root
  moduleName: "io.github.simonfrom.betterworkspaces"
  // `omarchy-shell io.github.simonfrom.betterworkspaces toggle` opens the settings menu.
  ipcTarget: "io.github.simonfrom.betterworkspaces"

  // Layout entry id in shell.json; settings are persisted against it.
  readonly property string entryId: "io.github.simonfrom.betterworkspaces"

  readonly property bool vertical: bar ? bar.vertical : false
  readonly property int barSize: bar ? bar.barSize : Style.bar.sizeHorizontal

  readonly property int defaultIconSize: Math.round(root.barSize * 0.5) + 1
  readonly property bool showIcons: setting("showIcons", true)
  readonly property int maxIcons: setting("maxIcons", 4)
  readonly property bool dedupe: setting("dedupe", true)
  readonly property real iconSize: setting("iconSize", defaultIconSize)
  readonly property real padding: setting("padding", 3)
  readonly property string emptyStyle: setting("emptyStyle", "dots") === "numbers" ? "numbers" : "dots"
  readonly property bool dynamicWorkspaces: setting("workspaces", 5) === "dynamic"
  readonly property int workspaceCount: {
    var n = Number(setting("workspaces", 5))
    return isFinite(n) ? Math.max(1, Math.min(10, Math.round(n))) : 5
  }

  readonly property color activeBorder: setting("activeColor", Color.accent)
  readonly property color activeFill: Util.alpha(Color.background, 0.6)
  readonly property real activeRadius: Math.max(Style.cornerRadius, 6)

  readonly property bool showActivity: setting("showActivity", true)
  readonly property bool showBadges: setting("showBadges", true)
  readonly property bool badgeNotifications: setting("badgeNotifications", true)
  readonly property bool useHerdr: setting("herdr", true)
  readonly property bool useDisk: setting("diskActivity", true)
  // Sustained write rate that counts as a download (bytes/s).
  readonly property real diskThreshold: 1024 * 1024
  readonly property color badgeColor: setting("badgeColor", "#ff4d4f")

  // herdr: pids of terminal windows hosting a herdr client, and the status of
  // every agent in the session ("idle" | "working" | "blocked" | "done").
  property var herdrHostPids: []
  property var herdrStatuses: []
  // Workspace id -> true while it has unseen activity (notification, urgent
  // window, finished spinner). Cleared when the workspace is focused.
  property var attention: ({})
  // Window address -> last seen spinner state, to catch it stopping.
  property var spinnerState: ({})
  // Disk writes per window pid: last sample { bytes, time }, a streak counter
  // (+ above threshold, - below) for hysteresis, and the busy set with rates.
  property var diskSamples: ({})
  property var diskStreaks: ({})
  property var diskBusy: ({})
  property var diskSince: ({})
  // Pids whose current busy spell received over the network: a download.
  property var diskDownloads: ({})
  // Network receive that marks a busy spell as a download (bytes/s).
  readonly property real netThreshold: 256 * 1024
  property var notificationService: null
  readonly property real startedAt: Date.now()

  property var iconCache: ({})

  // Last fixed count, so toggling back from dynamic restores it.
  property int lastFixedCount: 5

  function saveSetting(name, value) {
    var next = Object.assign({}, root.settings)
    next[name] = value
    root.settings = next
    if (root.bar && root.bar.shell) root.bar.shell.updateEntryInline(root.entryId, next)
  }

  // Where this widget sits in the bar layout: { section, index, count }.
  readonly property var barLocation: {
    var config = root.bar && root.bar.shell ? root.bar.shell.shellConfig : null
    var layout = config && config.bar ? config.bar.layout : null
    var sections = ["left", "center", "right"]
    for (var s = 0; layout && s < sections.length; s++) {
      var entries = layout[sections[s]] || []
      for (var i = 0; i < entries.length; i++) {
        if (entries[i] && entries[i].id === root.entryId)
          return { section: sections[s], index: i, count: entries.length }
      }
    }
    return { section: "", index: -1, count: 0 }
  }

  // Move within the bar via `omarchy bar move`, which keeps our settings.
  // An index past the end of a section clamps to the end.
  function moveTo(section, atStart) {
    if (!root.bar) return
    root.bar.run("omarchy-bar move " + Util.shellQuote(root.entryId)
      + " --section " + section + " --index " + (atStart ? 0 : 999))
  }

  function workspaceById(id) {
    var values = Hyprland.workspaces.values
    for (var i = 0; i < values.length; i++) {
      if (values[i].id === id) return values[i]
    }

    return null
  }

  function workspaceIds() {
    var ids = []
    if (!root.dynamicWorkspaces) {
      for (var n = 1; n <= root.workspaceCount; n++) ids.push(n)
    }

    var values = Hyprland.workspaces.values
    var focusedId = Hyprland.focusedWorkspace ? Hyprland.focusedWorkspace.id : -1

    for (var i = 0; i < values.length; i++) {
      var id = values[i].id
      if (id <= 0 || id > 10 || ids.indexOf(id) !== -1) continue
      if (values[i].toplevels.values.length > 0 || id === focusedId) ids.push(id)
    }

    if (ids.length === 0 && focusedId > 0) ids.push(focusedId)
    ids.sort(function(left, right) { return left - right })
    return ids
  }

  function focusWorkspace(id) {
    if (!root.bar) return
    root.bar.run("hyprctl dispatch " + Util.shellQuote("hl.dsp.focus({ workspace = \"" + id + "\" })"))
  }

  function toplevelAppId(toplevel) {
    if (!toplevel) return ""
    if (toplevel.wayland && toplevel.wayland.appId) return String(toplevel.wayland.appId)
    var ipc = toplevel.lastIpcObject
    if (ipc && ipc["class"]) return String(ipc["class"])
    return ""
  }

  function toplevelTitle(toplevel) {
    if (!toplevel) return ""
    if (toplevel.title) return String(toplevel.title)
    if (toplevel.wayland && toplevel.wayland.title) return String(toplevel.wayland.title)
    return ""
  }

  // Chromium web apps (omarchy-launch-webapp) get a class like
  // "chrome-discord.com__channels_@me-Default": host + path with "/" -> "_".
  // Match it to the desktop entry that launches the same URL.
  function webAppEntry(appId) {
    var match = /^(?:chrome|chromium|brave|msedge|vivaldi)-(.+)-[^-]+$/.exec(appId)
    if (!match) return null
    var key = match[1]
    var host = key.split("__")[0]
    var hostMatch = null

    var entries = DesktopEntries.applications.values || []
    for (var i = 0; i < entries.length; i++) {
      var entry = entries[i]
      var exec = entry.execString || (entry.command || []).join(" ")
      var url = /https?:\/\/([^\/\s"']+)([^\s"']*)/.exec(String(exec || ""))
      if (!url) continue
      var entryKey = url[1] + "_" + (url[2] || "/").replace(/\//g, "_")
      if (entryKey === key) return entry
      if (!hostMatch && url[1] === host) hostMatch = entry
    }

    return hostMatch
  }

  function resolveIcon(appId) {
    if (appId in root.iconCache) return root.iconCache[appId]

    var source = ""
    var entry = root.webAppEntry(appId) || DesktopEntries.heuristicLookup(appId)
    var candidates = []
    if (entry && entry.icon) candidates.push(String(entry.icon))
    candidates.push(appId, appId.toLowerCase())
    var lastDot = appId.lastIndexOf(".")
    if (lastDot >= 0) candidates.push(appId.substring(lastDot + 1).toLowerCase())

    for (var i = 0; i < candidates.length && source === ""; i++) {
      var name = candidates[i]
      if (!name) continue
      if (name.charAt(0) === "/") source = Util.fileUrl(name)
      else source = Quickshell.iconPath(name, true)
    }
    if (source === "") source = Quickshell.iconPath("application-x-executable", true)

    root.iconCache[appId] = source
    return source
  }

  // Window position from Hyprland's last IPC snapshot, or null if unknown.
  function toplevelPosition(toplevel) {
    var ipc = toplevel ? toplevel.lastIpcObject : null
    var at = ipc ? ipc.at : null
    return at && at.length === 2 ? at : null
  }

  // Toplevels in on-screen order: left to right, then top to bottom
  // (top to bottom first on a vertical bar). Unknown positions go last.
  function sortedToplevels(workspace) {
    var list = workspace.toplevels.values.map(function(toplevel, index) {
      return { toplevel: toplevel, index: index, at: root.toplevelPosition(toplevel) }
    })
    var primary = root.vertical ? 1 : 0
    var secondary = 1 - primary

    list.sort(function(a, b) {
      if (!a.at || !b.at) return (a.at ? -1 : b.at ? 1 : 0) || a.index - b.index
      return (a.at[primary] - b.at[primary]) || (a.at[secondary] - b.at[secondary]) || (a.index - b.index)
    })
    return list.map(function(entry) { return entry.toplevel })
  }

  // Apps on a workspace, in on-screen order: [{ appId, icon, titles: [] }]
  // With dedupe, an app sits where its first (leftmost) window is.
  function workspaceApps(workspace) {
    if (!workspace) return []
    var toplevels = root.sortedToplevels(workspace)
    var apps = []
    var byId = {}

    for (var i = 0; i < toplevels.length; i++) {
      var appId = root.toplevelAppId(toplevels[i])
      if (appId === "") continue
      var title = root.toplevelTitle(toplevels[i])

      if (root.dedupe && byId[appId]) {
        byId[appId].titles.push(title)
        continue
      }

      var app = { appId: appId, icon: root.resolveIcon(appId), titles: [title] }
      byId[appId] = app
      apps.push(app)
    }

    return apps
  }

  // ---------- Activity ----------

  function focusedWorkspaceId() {
    return Hyprland.focusedWorkspace ? Hyprland.focusedWorkspace.id : -1
  }

  function toplevelPid(toplevel) {
    var ipc = toplevel ? toplevel.lastIpcObject : null
    return ipc && ipc.pid ? Number(ipc.pid) : -1
  }

  // Claude Code and many TUIs put a spinner at the front of the title while
  // working: braille dots (U+2801-U+28FF) or quarter circles.
  function spinnerTitle(title) {
    if (!title) return false
    var c = title.charCodeAt(0)
    if (c > 0x2800 && c <= 0x28FF) return true
    return "◐◓◑◒◴◵◶◷".indexOf(title.charAt(0)) !== -1
  }

  function isHerdrHost(toplevel) {
    return root.useHerdr && root.herdrHostPids.indexOf(root.toplevelPid(toplevel)) !== -1
  }

  function flagAttention(id) {
    if (id <= 0 || id === root.focusedWorkspaceId() || root.attention[id]) return
    var next = Object.assign({}, root.attention)
    next[id] = true
    root.attention = next
  }

  function clearAttention(id) {
    if (!root.attention[id]) return
    var next = Object.assign({}, root.attention)
    delete next[id]
    root.attention = next
  }

  // { busy, badge, notes: [] } for a workspace. Reads titles and statuses
  // directly, so bindings update as they change.
  function activityFor(id, workspace) {
    var working = 0, blocked = 0, done = 0, spinning = 0, downloadRate = 0, writing = 0
    var seenPids = {}
    var toplevels = workspace ? workspace.toplevels.values : []
    for (var i = 0; i < toplevels.length; i++) {
      if (root.spinnerTitle(root.toplevelTitle(toplevels[i]))) spinning++
      var pid = root.toplevelPid(toplevels[i])
      if (root.diskBusy[pid] !== undefined && !seenPids[pid]) {
        seenPids[pid] = true
        if (root.diskDownloads[pid]) downloadRate += root.diskBusy[pid]
        else writing++
      }
      if (!root.isHerdrHost(toplevels[i])) continue
      for (var s = 0; s < root.herdrStatuses.length; s++) {
        var status = root.herdrStatuses[s]
        if (status === "working") working++
        else if (status === "blocked") blocked++
        else if (status === "done") done++
      }
    }

    var notes = []
    if (working) notes.push(working + (working === 1 ? " agent running" : " agents running"))
    else if (spinning || writing) notes.push("Running")
    if (downloadRate > 0) notes.push("Downloading · " + root.formatRate(downloadRate))
    if (blocked) notes.push(blocked + (blocked === 1 ? " agent needs input" : " agents need input"))
    if (done) notes.push(done + (done === 1 ? " agent finished" : " agents finished"))
    // A dot on a workspace whose windows have all closed points at nothing.
    var unseen = root.attention[id] === true && toplevels.length > 0
    if (unseen) notes.push("New activity")

    return {
      busy: root.showActivity && (working > 0 || spinning > 0 || downloadRate > 0 || writing > 0),
      badge: root.showBadges && (blocked > 0 || done > 0 || unseen),
      notes: notes
    }
  }

  function formatRate(bytesPerSecond) {
    var mb = bytesPerSecond / (1024 * 1024)
    return (mb >= 10 ? Math.round(mb) : mb.toFixed(1)) + " MB/s"
  }

  // Window pids for the disk sampler, deduplicated.
  function windowPids() {
    var pids = []
    var values = Hyprland.toplevels.values
    for (var i = 0; i < values.length; i++) {
      var pid = root.toplevelPid(values[i])
      if (pid > 0 && pids.indexOf(pid) === -1) pids.push(pid)
    }
    return pids
  }

  function workspaceIdForPid(pid) {
    var values = Hyprland.toplevels.values
    for (var i = 0; i < values.length; i++) {
      if (root.toplevelPid(values[i]) === pid) return root.toplevelWorkspaceId(values[i])
    }
    return -1
  }

  // Turn byte totals into rates. Busy after three samples over the threshold
  // (~4.5s), idle after four under (~6s): cache flushes don't count, and a
  // download pausing between chunks doesn't end it. Only downloads that ran
  // for a while raise the dot when they finish.
  function parseDisk(text) {
    var now = Date.now()
    var samples = {}
    var streaks = {}
    var busy = {}
    var since = {}
    var downloads = {}
    var lines = String(text || "").split("\n")

    for (var i = 0; i < lines.length; i++) {
      var parts = lines[i].trim().split(/\s+/)
      if (parts.length !== 3) continue
      var pid = Number(parts[0])
      var bytes = Number(parts[1])
      var netBytes = Number(parts[2])
      if (!(pid > 0) || !isFinite(bytes) || !isFinite(netBytes)) continue
      samples[pid] = { bytes: bytes, net: netBytes, time: now }

      var prev = root.diskSamples[pid]
      var streak = root.diskStreaks[pid] || 0
      var rate = 0
      var netRate = 0
      if (prev && now > prev.time && bytes >= prev.bytes) {
        rate = (bytes - prev.bytes) * 1000 / (now - prev.time)
        // Closed sockets drop out of the total; a negative delta says nothing.
        netRate = netBytes > prev.net ? (netBytes - prev.net) * 1000 / (now - prev.time) : 0
        if (rate >= root.diskThreshold) streak = Math.max(1, streak + 1)
        else streak = Math.min(-1, streak - 1)
      }
      streaks[pid] = streak

      var wasBusy = root.diskBusy[pid] !== undefined
      if (streak >= 3 || (wasBusy && streak > -4)) {
        busy[pid] = rate >= root.diskThreshold || !wasBusy ? rate : root.diskBusy[pid]
        since[pid] = wasBusy ? root.diskSince[pid] : now
        if ((wasBusy && root.diskDownloads[pid]) || netRate >= root.netThreshold) downloads[pid] = true
      } else if (wasBusy && root.showBadges && now - root.diskSince[pid] >= 15000) {
        root.flagAttention(root.workspaceIdForPid(pid))
      }
    }

    root.diskSamples = samples
    root.diskStreaks = streaks
    root.diskSince = since
    if (JSON.stringify(downloads) !== JSON.stringify(root.diskDownloads)) root.diskDownloads = downloads
    if (JSON.stringify(busy) !== JSON.stringify(root.diskBusy)) root.diskBusy = busy
  }

  function toplevelByAddress(address) {
    var wanted = String(address || "").replace(/^0x/, "")
    var values = Hyprland.toplevels.values
    for (var i = 0; i < values.length; i++) {
      if (String(values[i].address).replace(/^0x/, "") === wanted) return values[i]
    }
    return null
  }

  function toplevelWorkspaceId(toplevel) {
    return toplevel && toplevel.workspace ? toplevel.workspace.id : -1
  }

  // A spinner that stops on an unfocused workspace means something finished.
  function checkSpinner(toplevel) {
    if (!toplevel) return
    var key = String(toplevel.address)
    var spinning = root.spinnerTitle(root.toplevelTitle(toplevel))
    var was = root.spinnerState[key] === true
    root.spinnerState[key] = spinning
    if (was && !spinning && root.showBadges) root.flagAttention(root.toplevelWorkspaceId(toplevel))
  }

  // Match a notification's app name to a window: "Discord" matches
  // chrome-discord.com__..., "Google Chrome" matches google-chrome.
  function flagNotification(app) {
    var name = String(app || "").toLowerCase().replace(/[^a-z0-9]/g, "")
    if (name.length < 3 || name === "notifysend" || name === "omarchyaction") return

    var matchIds = []
    var values = Hyprland.toplevels.values
    for (var i = 0; i < values.length; i++) {
      var cls = root.toplevelAppId(values[i]).toLowerCase().replace(/[^a-z0-9]/g, "")
      if (!cls || (cls.indexOf(name) === -1 && !(cls.length >= 4 && name.indexOf(cls) !== -1))) continue
      var id = root.toplevelWorkspaceId(values[i])
      // The sender is on screen already; nothing to point at.
      if (id === root.focusedWorkspaceId()) return
      if (matchIds.indexOf(id) === -1) matchIds.push(id)
    }
    if (matchIds.length > 0) root.flagAttention(matchIds[0])
  }

  function parseHerdr(text) {
    var lines = String(text || "").split("\n")
    var pids = []
    var statuses = []
    if (lines.length >= 2) {
      pids = lines[0].split(",").map(Number).filter(function(p) { return p > 0 })
      try {
        var agents = JSON.parse(lines.slice(1).join("\n")).result.snapshot.agents || []
        statuses = agents.map(function(agent) { return String(agent.agent_status || "") })
      } catch (e) {
        statuses = []
      }
    }
    if (JSON.stringify(pids) !== JSON.stringify(root.herdrHostPids)) root.herdrHostPids = pids
    if (JSON.stringify(statuses) !== JSON.stringify(root.herdrStatuses)) root.herdrStatuses = statuses
  }

  function findNotificationService() {
    if (root.notificationService || !root.bar || !root.bar.shell || !root.bar.shell.serviceFor) return
    root.notificationService = root.bar.shell.serviceFor("omarchy.notifications")
  }

  // Line 1: pids of the terminals hosting a herdr client. Rest: the snapshot.
  Process {
    id: herdrProc
    command: ["bash", "-c",
      "pgrep -x herdr >/dev/null || exit 0; "
      + "for p in $(pgrep -x herdr); do ps -o ppid= -p \"$p\"; done | tr -d ' ' | paste -sd, -; "
      + "timeout 2 herdr api snapshot 2>/dev/null"]
    stdout: StdioCollector {
      onStreamFinished: root.parseHerdr(this.text)
    }
  }

  Process {
    id: diskProc
    stdout: StdioCollector {
      onStreamFinished: root.parseDisk(this.text)
    }
  }

  Timer {
    interval: 1500
    repeat: true
    triggeredOnStart: true
    running: root.useDisk && root.showActivity
    onTriggered: {
      var pids = root.windowPids()
      if (diskProc.running || pids.length === 0) return
      diskProc.command = ["bash", decodeURIComponent(Qt.resolvedUrl("disk-activity.sh").toString().replace(/^file:\/\//, ""))].concat(pids.map(String))
      diskProc.running = true
    }
    onRunningChanged: if (!running) {
      root.diskSamples = ({})
      root.diskStreaks = ({})
      root.diskBusy = ({})
      root.diskSince = ({})
      root.diskDownloads = ({})
    }
  }

  Timer {
    interval: 1500
    repeat: true
    triggeredOnStart: true
    running: root.useHerdr && (root.showActivity || root.showBadges)
    onTriggered: {
      root.findNotificationService()
      if (!herdrProc.running) herdrProc.running = true
    }
    onRunningChanged: if (!running) root.parseHerdr("")
  }

  Connections {
    target: root.notificationService ? root.notificationService.popupModel : null
    ignoreUnknownSignals: true
    function onRowsInserted(parent, first, last) {
      if (!root.showBadges || !root.badgeNotifications) return
      var model = root.notificationService.popupModel
      for (var i = first; i <= last; i++) {
        var row = model.get(i)
        // Skip toasts restored from before a shell restart.
        if (row && Number(row.timestamp || 0) >= root.startedAt) root.flagNotification(row.app)
      }
    }
  }

  // Clear cached lookups when apps are installed/removed.
  Connections {
    target: DesktopEntries.applications
    function onValuesChanged() { root.iconCache = ({}) }
  }

  // Window positions only arrive via IPC snapshots, so re-fetch them when
  // the layout may have changed. Debounced: events come in bursts.
  Timer {
    id: positionRefresh
    interval: 60
    onTriggered: Hyprland.refreshToplevels()
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      var name = event.name
      if (name.indexOf("window") !== -1 || name === "changefloatingmode" || name === "fullscreen"
          || name.indexOf("workspace") === 0 || name.indexOf("group") !== -1 || name === "configreloaded")
        positionRefresh.restart()

      if (name === "windowtitlev2") {
        root.checkSpinner(root.toplevelByAddress(String(event.data).split(",")[0]))
      } else if (name === "urgent" && root.showBadges) {
        root.flagAttention(root.toplevelWorkspaceId(root.toplevelByAddress(event.data)))
      }
    }

    function onFocusedWorkspaceChanged() {
      root.clearAttention(root.focusedWorkspaceId())
    }
  }

  Component.onCompleted: {
    Hyprland.refreshToplevels()
    root.findNotificationService()
    if (!root.dynamicWorkspaces) root.lastFixedCount = root.workspaceCount
  }

  readonly property real trailingGap: root.vertical ? 0 : Style.spaceReal(1.5)

  implicitWidth: grid.implicitWidth + trailingGap
  implicitHeight: grid.implicitHeight

  GridLayout {
    id: grid
    anchors.fill: parent
    anchors.rightMargin: root.trailingGap
    columns: root.vertical ? 1 : root.workspaceIds().length
    columnSpacing: root.vertical ? 0 : Style.space(1)
    rowSpacing: root.vertical ? Style.space(2) : 0

    Repeater {
      model: root.workspaceIds()

      WidgetButton {
        id: button
        required property int modelData

        readonly property var workspace: root.workspaceById(modelData)
        readonly property bool occupied: workspace !== null && workspace.toplevels.values.length > 0
        readonly property bool focused: Hyprland.focusedWorkspace !== null && Hyprland.focusedWorkspace.id === modelData
        readonly property var apps: root.showIcons ? root.workspaceApps(workspace) : []
        readonly property int shownCount: Math.min(apps.length, root.maxIcons)
        readonly property int overflow: apps.length - shownCount
        readonly property string numberText: modelData === 10 ? "0" : String(modelData)
        readonly property var activity: root.activityFor(modelData, workspace)

        bar: root.bar
        text: numberText
        labelVisible: false
        opacity: occupied || focused ? 1 : 0.45
        // Hover lift. Scale is a transform, so neighbours don't reflow.
        scale: tooltipHovered ? 1.1 : 1

        Behavior on scale {
          NumberAnimation { duration: 120; easing.type: Easing.OutCubic }
        }
        horizontalMargin: 6
        verticalPadding: 6
        fixedWidth: root.vertical ? root.barSize : Math.max(Style.space(20), content.implicitWidth + Style.spaceReal(12) + root.padding * 2)
        fixedHeight: root.vertical ? Math.max(root.barSize, content.implicitHeight + Style.spaceReal(12) + root.padding * 2) : root.barSize
        tooltipText: {
          var lines = []
          for (var i = 0; i < apps.length; i++) {
            var app = apps[i]
            var label = app.titles.length > 1 ? app.appId + " (" + app.titles.length + ")" : (app.titles[0] || app.appId)
            lines.push(label)
          }
          return lines.concat(activity.notes).join("\n")
        }
        onPressed: function(b) {
          if (b === Qt.RightButton) root.toggle()
          else root.focusWorkspace(modelData)
        }

        // Soft accent glow when hovering an inactive workspace: a blurred
        // copy of the pill shape, painted behind everything else.
        Rectangle {
          id: glowShape
          anchors.fill: highlight
          radius: root.activeRadius
          color: root.activeBorder
          visible: false
        }

        MultiEffect {
          anchors.fill: glowShape
          source: glowShape
          autoPaddingEnabled: true
          blurEnabled: true
          blur: 1.0
          blurMax: 16
          opacity: button.tooltipHovered && !button.focused ? 0.45 : 0

          Behavior on opacity {
            NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
          }
        }

        Rectangle {
          id: highlight
          anchors.fill: parent
          anchors.topMargin: Style.spaceReal(1.5)
          anchors.bottomMargin: Style.spaceReal(1.5)
          anchors.leftMargin: Style.spaceReal(2)
          anchors.rightMargin: Style.spaceReal(2)
          radius: root.activeRadius
          color: root.activeFill
          border.width: 1.5
          border.color: root.activeBorder
          opacity: button.focused ? 1 : 0

          Behavior on opacity {
            NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
          }
        }

        // Running: a dash that circles the pill. Accent on inactive
        // workspaces (over a faint track), foreground on the active one so
        // it stands out against the accent border.
        Shape {
          id: runner
          anchors.fill: highlight
          visible: opacity > 0
          opacity: button.activity.busy ? 1 : 0
          layer.enabled: visible
          layer.samples: 4

          readonly property real stroke: 2
          readonly property real inset: stroke / 2
          readonly property real w: Math.max(0, width - stroke)
          readonly property real h: Math.max(0, height - stroke)
          readonly property real r: Math.min(root.activeRadius, w / 2, h / 2)
          // Perimeter in stroke widths, the unit dash patterns use.
          readonly property real loop: Math.max(1, (2 * (w + h) - (8 - 2 * Math.PI) * r) / stroke)
          property real offset: 0

          Behavior on opacity {
            NumberAnimation { duration: 200; easing.type: Easing.OutCubic }
          }

          NumberAnimation on offset {
            running: runner.visible
            from: runner.loop
            to: 0
            duration: 1400
            loops: Animation.Infinite
          }

          ShapePath {
            strokeWidth: runner.stroke
            strokeColor: button.focused ? "transparent" : Util.alpha(root.activeBorder, 0.25)
            fillColor: "transparent"
            PathRectangle {
              x: runner.inset; y: runner.inset
              width: runner.w; height: runner.h
              radius: runner.r
            }
          }

          ShapePath {
            strokeWidth: runner.stroke
            strokeColor: button.focused ? button.foreground : root.activeBorder
            fillColor: "transparent"
            capStyle: ShapePath.RoundCap
            strokeStyle: ShapePath.DashLine
            dashPattern: [runner.loop * 0.3, runner.loop * 0.7]
            dashOffset: runner.offset
            PathRectangle {
              x: runner.inset; y: runner.inset
              width: runner.w; height: runner.h
              radius: runner.r
            }
          }
        }

        GridLayout {
          id: content
          anchors.centerIn: parent
          columns: root.vertical ? 1 : 2 + button.shownCount
          rowSpacing: Style.spaceReal(2)
          columnSpacing: Style.spaceReal(3)

          // Marker for workspaces with no app icons, so they stay visible
          // and clickable: a dot or the workspace number.
          Rectangle {
            visible: button.apps.length === 0 && root.emptyStyle === "dots"
            Layout.alignment: Qt.AlignCenter
            implicitWidth: Math.round(root.iconSize * 0.35)
            implicitHeight: implicitWidth
            radius: width / 2
            color: button.foreground
          }

          Text {
            visible: button.apps.length === 0 && root.emptyStyle === "numbers"
            Layout.alignment: Qt.AlignCenter
            textFormat: Text.PlainText
            text: button.numberText
            color: button.foreground
            font.family: button.fontFamily
            font.pixelSize: button.fontSize
            renderType: Text.NativeRendering
          }

          Repeater {
            model: button.apps.slice(0, button.shownCount)

            Image {
              required property var modelData
              Layout.alignment: Qt.AlignCenter
              Layout.preferredWidth: root.iconSize
              Layout.preferredHeight: root.iconSize
              source: modelData.icon
              sourceSize.width: root.iconSize * Screen.devicePixelRatio
              sourceSize.height: root.iconSize * Screen.devicePixelRatio
              fillMode: Image.PreserveAspectFit
              asynchronous: true
              smooth: true
              opacity: button.focused ? 1 : 0.8
            }
          }

          Text {
            visible: button.overflow > 0
            Layout.alignment: Qt.AlignCenter
            textFormat: Text.PlainText
            text: "+" + button.overflow
            color: button.foreground
            font.family: button.fontFamily
            font.pixelSize: Math.round(button.fontSize * 0.75)
            renderType: Text.NativeRendering
          }
        }

        // Attention: a small dot on the pill's top-right corner, ringed in
        // the bar background so it reads on any icon or wallpaper.
        Rectangle {
          readonly property real size: Math.max(8, Math.round(root.iconSize * 0.5))
          width: size
          height: size
          radius: size / 2
          x: highlight.x + highlight.width - size - 1
          y: highlight.y + 1
          color: root.badgeColor
          border.width: 1
          border.color: Color.background
          scale: button.activity.badge ? 1 : 0
          visible: scale > 0

          Behavior on scale {
            NumberAnimation { duration: 180; easing.type: Easing.OutBack }
          }
        }
      }
    }
  }

  // ---------- Settings menu (right-click) ----------
  KeyboardPanel {
    id: panel
    anchorItem: grid
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(320))
    contentHeight: panel.fittedContentHeight(menuColumn.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: menuColumn
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(14)

        Column {
          width: parent.width
          spacing: Style.space(2)

          Text {
            text: "BetterWorkspaces"
            color: root.barForeground
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.title
            font.bold: true
          }

          Text {
            textFormat: Text.PlainText
            text: "WORKSPACE SETTINGS"
            color: Qt.darker(root.barForeground, 1.4)
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
            font.bold: true
            font.letterSpacing: 1.2
          }
        }

        PanelSeparator { foreground: root.barForeground }

        SettingRow {
          label: "Icon size"
          NumberField {
            value: root.iconSize
            from: 8
            to: 32
            foreground: root.barForeground
            onModified: function(v) { root.saveSetting("iconSize", v) }
          }
        }

        SettingRow {
          label: "Padding"
          NumberField {
            value: root.padding
            from: 0
            to: 16
            foreground: root.barForeground
            onModified: function(v) { root.saveSetting("padding", v) }
          }
        }

        PanelSeparator { foreground: root.barForeground }

        Column {
          width: parent.width
          spacing: Style.space(10)

          PanelSectionHeader {
            text: "UNUSED WORKSPACES"
            foreground: root.barForeground
          }

          ButtonGroup {
            focusable: false
            options: [
              { value: "dots", label: "Dots" },
              { value: "numbers", label: "Numbers" }
            ]
            value: root.emptyStyle
            foreground: root.barForeground
            onChanged: function(v) { root.saveSetting("emptyStyle", v) }
          }
        }

        Column {
          width: parent.width
          spacing: Style.space(10)

          PanelSectionHeader {
            text: "WORKSPACES"
            foreground: root.barForeground
          }

          ButtonGroup {
            focusable: false
            options: [
              { value: "fixed", label: "Fixed" },
              { value: "dynamic", label: "Dynamic" }
            ]
            value: root.dynamicWorkspaces ? "dynamic" : "fixed"
            foreground: root.barForeground
            onChanged: function(v) {
              root.saveSetting("workspaces", v === "dynamic" ? "dynamic" : root.lastFixedCount)
            }
          }

          SettingRow {
            visible: !root.dynamicWorkspaces
            label: "Always show"
            NumberField {
              value: root.workspaceCount
              from: 1
              to: 10
              foreground: root.barForeground
              onModified: function(v) {
                root.lastFixedCount = v
                root.saveSetting("workspaces", v)
              }
            }
          }

          Text {
            width: parent.width
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            text: root.dynamicWorkspaces
              ? "Only workspaces with windows, plus the active one."
              : "Workspaces 1–" + root.workspaceCount + ", plus any others with windows."
            color: root.barForeground
            opacity: 0.6
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.bodySmall
          }
        }

        PanelSeparator { foreground: root.barForeground }

        Column {
          width: parent.width
          spacing: Style.space(10)

          PanelSectionHeader {
            text: "ACTIVITY"
            foreground: root.barForeground
          }

          SettingRow {
            label: "Running animation"
            ToggleSwitch {
              checked: root.showActivity
              foreground: root.barForeground
              cursorRing: false
              onToggled: root.saveSetting("showActivity", !root.showActivity)
            }
          }

          SettingRow {
            label: "Attention dot"
            ToggleSwitch {
              checked: root.showBadges
              foreground: root.barForeground
              cursorRing: false
              onToggled: root.saveSetting("showBadges", !root.showBadges)
            }
          }

          SettingRow {
            visible: root.showBadges
            label: "Dot for notifications"
            ToggleSwitch {
              checked: root.badgeNotifications
              foreground: root.barForeground
              cursorRing: false
              onToggled: root.saveSetting("badgeNotifications", !root.badgeNotifications)
            }
          }

          SettingRow {
            label: "Downloads"
            ToggleSwitch {
              checked: root.useDisk
              foreground: root.barForeground
              cursorRing: false
              onToggled: root.saveSetting("diskActivity", !root.useDisk)
            }
          }

          SettingRow {
            label: "herdr agents"
            ToggleSwitch {
              checked: root.useHerdr
              foreground: root.barForeground
              cursorRing: false
              onToggled: root.saveSetting("herdr", !root.useHerdr)
            }
          }

          Text {
            width: parent.width
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            text: "The border circles while an agent is working or an app is downloading. The dot "
              + "means something finished or wants attention, and clears when you visit."
            color: root.barForeground
            opacity: 0.6
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.bodySmall
          }
        }

        PanelSeparator { foreground: root.barForeground }

        Column {
          width: parent.width
          spacing: Style.space(10)

          PanelSectionHeader {
            text: "POSITION"
            foreground: root.barForeground
          }

          ButtonGroup {
            focusable: false
            options: root.vertical
              ? [{ value: "left", label: "Top" }, { value: "center", label: "Middle" }, { value: "right", label: "Bottom" }]
              : [{ value: "left", label: "Left" }, { value: "center", label: "Center" }, { value: "right", label: "Right" }]
            value: root.barLocation.section
            foreground: root.barForeground
            onChanged: function(v) {
              if (v !== root.barLocation.section) root.moveTo(v, v === "right")
            }
          }

          ButtonGroup {
            focusable: false
            options: [
              { value: "start", label: "First in section" },
              { value: "end", label: "Last in section" }
            ]
            value: root.barLocation.index === 0 ? "start"
              : (root.barLocation.index === root.barLocation.count - 1 ? "end" : "")
            foreground: root.barForeground
            onChanged: function(v) {
              if (root.barLocation.section) root.moveTo(root.barLocation.section, v === "start")
            }
          }
        }
      }
    }
  }

  // Label on the left, control on the right.
  component SettingRow: Item {
    property string label: ""
    default property alias control: controlHolder.data

    width: parent ? parent.width : 0
    implicitHeight: Math.max(labelText.implicitHeight, controlHolder.childrenRect.height)

    Text {
      id: labelText
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: parent.label
      color: root.barForeground
      font.family: root.bar ? root.bar.fontFamily : Style.font.family
      font.pixelSize: Style.font.body
    }

    Item {
      id: controlHolder
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      width: childrenRect.width
      height: childrenRect.height
    }
  }
}
