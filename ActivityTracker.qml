import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io

import "Activity.js" as Activity
import "Windows.js" as Windows

// Non-visual: collects activity per workspace and answers activityFor().
//
// Sources:
//   - herdr agents (`herdr api snapshot`): working -> running; done/blocked -> dot.
//     Mapped to the terminal window hosting the herdr client.
//   - Apps writing over 1 MB/s to disk -> running, labelled "Downloading" when
//     they are also receiving over the network (see disk-activity.sh);
//     finishing on an unfocused workspace -> dot.
//   - Window titles starting with a spinner glyph (Claude Code and similar
//     TUIs) -> running; the spinner stopping on an unfocused workspace -> dot.
//   - Hyprland urgent events and shell notifications from an app on an
//     unfocused workspace -> dot, cleared when that workspace is visited.
Item {
  id: tracker

  // The host bar, for reaching the shell's notification service.
  property var bar: null
  property bool showActivity: true
  property bool showBadges: true
  property bool badgeNotifications: true
  property bool useHerdr: true
  property bool useDisk: true

  // herdr: pids of terminal windows hosting a herdr client, and the status of
  // every agent in the session ("idle" | "working" | "blocked" | "done").
  property var herdrHostPids: []
  property var herdrStatuses: []
  // Workspace id -> true while it has unseen activity (notification, urgent
  // window, finished spinner or download). Cleared when the workspace is focused.
  property var attention: ({})
  // Window pid -> { rate, download } while its app is busy on disk. Bindings
  // read this; the full per-sample state lives in diskState.
  property var diskBusy: ({})
  property var diskState: ({})
  // Window address -> last seen spinner state, to catch it stopping.
  property var spinnerState: ({})
  property var notificationService: null
  readonly property real startedAt: Date.now()

  function focusedWorkspaceId() {
    return Hyprland.focusedWorkspace ? Hyprland.focusedWorkspace.id : -1
  }

  function isHerdrHost(toplevel) {
    return tracker.useHerdr && tracker.herdrHostPids.indexOf(Windows.pid(toplevel)) !== -1
  }

  function flagAttention(id) {
    if (!tracker.showBadges) return
    if (id <= 0 || id === tracker.focusedWorkspaceId() || tracker.attention[id]) return
    var next = Object.assign({}, tracker.attention)
    next[id] = true
    tracker.attention = next
  }

  function clearAttention(id) {
    if (!tracker.attention[id]) return
    var next = Object.assign({}, tracker.attention)
    delete next[id]
    tracker.attention = next
  }

  // { busy, badge, notes: [] } for a workspace. Reads titles and statuses
  // directly, so bindings update as they change.
  function activityFor(id, workspace) {
    var counts = { working: 0, blocked: 0, done: 0, spinning: 0, writing: 0, downloadRate: 0, unseen: false }
    var seenPids = {}
    var toplevels = workspace ? workspace.toplevels.values : []

    for (var i = 0; i < toplevels.length; i++) {
      if (Activity.isSpinnerTitle(Windows.title(toplevels[i]))) counts.spinning++

      var pid = Windows.pid(toplevels[i])
      var disk = tracker.diskBusy[pid]
      if (disk && !seenPids[pid]) {
        seenPids[pid] = true
        if (disk.download) counts.downloadRate += disk.rate
        else counts.writing++
      }

      if (!tracker.isHerdrHost(toplevels[i])) continue
      for (var s = 0; s < tracker.herdrStatuses.length; s++) {
        var status = tracker.herdrStatuses[s]
        if (status === "working") counts.working++
        else if (status === "blocked") counts.blocked++
        else if (status === "done") counts.done++
      }
    }

    // A dot on a workspace whose windows have all closed points at nothing.
    counts.unseen = tracker.attention[id] === true && toplevels.length > 0

    return {
      busy: tracker.showActivity
        && (counts.working > 0 || counts.spinning > 0 || counts.downloadRate > 0 || counts.writing > 0),
      badge: tracker.showBadges && (counts.blocked > 0 || counts.done > 0 || counts.unseen),
      notes: Activity.notes(counts)
    }
  }

  // Window pids for the disk sampler, deduplicated.
  function windowPids() {
    var pids = []
    var values = Hyprland.toplevels.values
    for (var i = 0; i < values.length; i++) {
      var pid = Windows.pid(values[i])
      if (pid > 0 && pids.indexOf(pid) === -1) pids.push(pid)
    }
    return pids
  }

  function workspaceIdForPid(pid) {
    var values = Hyprland.toplevels.values
    for (var i = 0; i < values.length; i++) {
      if (Windows.pid(values[i]) === pid) return Windows.workspaceId(values[i])
    }
    return -1
  }

  function toplevelByAddress(address) {
    var values = Hyprland.toplevels.values
    for (var i = 0; i < values.length; i++) {
      if (Windows.sameAddress(values[i].address, address)) return values[i]
    }
    return null
  }

  function applyDisk(text) {
    var now = Date.now()
    var state = {}
    var busy = {}
    var samples = Activity.parseDiskLines(text)

    for (var i = 0; i < samples.length; i++) {
      var pid = samples[i].pid
      var step = Activity.stepDisk(tracker.diskState[pid], samples[i], now)
      state[pid] = step.state
      if (step.state.busy) busy[pid] = { rate: step.state.rate, download: step.state.download }
      if (step.finished) tracker.flagAttention(tracker.workspaceIdForPid(pid))
    }

    tracker.diskState = state
    if (JSON.stringify(busy) !== JSON.stringify(tracker.diskBusy)) tracker.diskBusy = busy
  }

  function applyHerdr(text) {
    var parsed = Activity.parseHerdr(text)
    if (JSON.stringify(parsed.pids) !== JSON.stringify(tracker.herdrHostPids)) tracker.herdrHostPids = parsed.pids
    if (JSON.stringify(parsed.statuses) !== JSON.stringify(tracker.herdrStatuses)) tracker.herdrStatuses = parsed.statuses
  }

  // A spinner that stops on an unfocused workspace means something finished.
  function checkSpinner(toplevel) {
    if (!toplevel) return
    var key = String(toplevel.address)
    var spinning = Activity.isSpinnerTitle(Windows.title(toplevel))
    var was = tracker.spinnerState[key] === true
    tracker.spinnerState[key] = spinning
    if (was && !spinning) tracker.flagAttention(Windows.workspaceId(toplevel))
  }

  // Point a notification at the workspace of the window that sent it, unless
  // that window is already on screen.
  function flagNotification(app) {
    var key = Activity.notificationKey(app)
    if (!key) return

    var values = Hyprland.toplevels.values
    var target = -1
    for (var i = 0; i < values.length; i++) {
      if (!Activity.notificationMatches(key, Windows.appId(values[i]))) continue
      var id = Windows.workspaceId(values[i])
      if (id === tracker.focusedWorkspaceId()) return
      if (target === -1) target = id
    }
    if (target !== -1) tracker.flagAttention(target)
  }

  function findNotificationService() {
    if (tracker.notificationService || !tracker.bar || !tracker.bar.shell || !tracker.bar.shell.serviceFor) return
    tracker.notificationService = tracker.bar.shell.serviceFor("omarchy.notifications")
  }

  // Line 1: pids of the terminals hosting a herdr client. Rest: the snapshot.
  Process {
    id: herdrProc
    command: ["bash", "-c",
      "pgrep -x herdr >/dev/null || exit 0; "
      + "for p in $(pgrep -x herdr); do ps -o ppid= -p \"$p\"; done | tr -d ' ' | paste -sd, -; "
      + "timeout 2 herdr api snapshot 2>/dev/null"]
    stdout: StdioCollector {
      onStreamFinished: tracker.applyHerdr(this.text)
    }
  }

  Process {
    id: diskProc
    stdout: StdioCollector {
      onStreamFinished: tracker.applyDisk(this.text)
    }
  }

  Timer {
    interval: 1500
    repeat: true
    triggeredOnStart: true
    running: tracker.useDisk && tracker.showActivity
    onTriggered: {
      var pids = tracker.windowPids()
      if (diskProc.running || pids.length === 0) return
      var script = decodeURIComponent(Qt.resolvedUrl("disk-activity.sh").toString().replace(/^file:\/\//, ""))
      diskProc.command = ["bash", script].concat(pids.map(String))
      diskProc.running = true
    }
    onRunningChanged: if (!running) {
      tracker.diskState = ({})
      tracker.diskBusy = ({})
    }
  }

  Timer {
    interval: 1500
    repeat: true
    triggeredOnStart: true
    running: tracker.useHerdr && (tracker.showActivity || tracker.showBadges)
    onTriggered: {
      tracker.findNotificationService()
      if (!herdrProc.running) herdrProc.running = true
    }
    onRunningChanged: if (!running) tracker.applyHerdr("")
  }

  Connections {
    target: tracker.notificationService ? tracker.notificationService.popupModel : null
    ignoreUnknownSignals: true
    function onRowsInserted(parent, first, last) {
      if (!tracker.badgeNotifications) return
      var model = tracker.notificationService.popupModel
      for (var i = first; i <= last; i++) {
        var row = model.get(i)
        // Skip toasts restored from before a shell restart.
        if (row && Number(row.timestamp || 0) >= tracker.startedAt) tracker.flagNotification(row.app)
      }
    }
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (event.name === "windowtitlev2") {
        tracker.checkSpinner(tracker.toplevelByAddress(String(event.data).split(",")[0]))
      } else if (event.name === "urgent") {
        tracker.flagAttention(Windows.workspaceId(tracker.toplevelByAddress(event.data)))
      }
    }

    function onFocusedWorkspaceChanged() {
      tracker.clearAttention(tracker.focusedWorkspaceId())
    }
  }

  Component.onCompleted: tracker.findNotificationService()
}
