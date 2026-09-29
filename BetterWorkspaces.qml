import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Hyprland
import qs.Commons
import qs.Ui

import "AppIcons.js" as AppIcons
import "Windows.js" as Windows

// BetterWorkspaces: workspace indicators with icons for the apps open on each
// workspace. Based on the built-in omarchy.workspaces widget.
//
// Left-click a workspace to focus it, right-click to open the settings menu.
//
// Files:
//   BetterWorkspaces.qml  this entry: settings, workspace and icon lookups, layout
//   WorkspaceButton.qml   one workspace pill
//   SettingsMenu.qml      the right-click menu
//   ActivityTracker.qml   running/attention state (herdr, disk, notifications)
//   Windows.js, AppIcons.js, Activity.js  pure logic, tested in tests/
//   disk-activity.sh      per-app disk and network byte counts
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
  readonly property color badgeColor: setting("badgeColor", "#ff4d4f")

  // Read by WorkspaceButton for each workspace's running/attention state.
  readonly property alias tracker: tracker

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

  function resolveIcon(appId) {
    if (appId in root.iconCache) return root.iconCache[appId]

    var entry = AppIcons.findWebAppEntry(appId, DesktopEntries.applications.values || [])
      || DesktopEntries.heuristicLookup(appId)
    var candidates = AppIcons.iconCandidates(appId, entry ? entry.icon : "")
    var source = ""

    for (var i = 0; i < candidates.length && source === ""; i++) {
      var name = candidates[i]
      if (name.charAt(0) === "/") source = Util.fileUrl(name)
      else source = Quickshell.iconPath(name, true)
    }
    if (source === "") source = Quickshell.iconPath("application-x-executable", true)

    root.iconCache[appId] = source
    return source
  }

  // Apps on a workspace, in on-screen order: [{ appId, icon, titles: [] }]
  // With dedupe, an app sits where its first (leftmost) window is.
  function workspaceApps(workspace) {
    if (!workspace) return []
    var toplevels = Windows.sortByPosition(workspace.toplevels.values, root.vertical)
    var apps = []
    var byId = {}

    for (var i = 0; i < toplevels.length; i++) {
      var appId = Windows.appId(toplevels[i])
      if (appId === "") continue
      var title = Windows.title(toplevels[i])

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

  ActivityTracker {
    id: tracker
    bar: root.bar
    showActivity: root.showActivity
    showBadges: root.showBadges
    badgeNotifications: root.badgeNotifications
    useHerdr: root.useHerdr
    useDisk: root.useDisk
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
    }
  }

  Component.onCompleted: {
    Hyprland.refreshToplevels()
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

      WorkspaceButton {
        widget: root
      }
    }
  }

  SettingsMenu {
    widget: root
    anchorItem: grid
  }
}
