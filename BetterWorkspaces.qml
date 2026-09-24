import QtQuick
import QtQuick.Effects
import QtQuick.Layouts
import Quickshell
import Quickshell.Hyprland
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
Panel {
  id: root
  moduleName: "omarchy.workspaces"
  // `omarchy-shell simon.betterworkspaces toggle` opens the settings menu.
  ipcTarget: "simon.betterworkspaces"

  // Layout entry id in shell.json; settings are persisted against it.
  readonly property string entryId: "simon.betterworkspaces"

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

  property var iconCache: ({})

  // Last fixed count, so toggling back from dynamic restores it.
  property int lastFixedCount: 5

  function saveSetting(name, value) {
    var next = Object.assign({}, root.settings)
    next[name] = value
    root.settings = next
    if (root.bar && root.bar.shell) root.bar.shell.updateEntryInline(root.entryId, next)
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

  function resolveIcon(appId) {
    if (appId in root.iconCache) return root.iconCache[appId]

    var source = ""
    var entry = DesktopEntries.heuristicLookup(appId)
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
          return lines.join("\n")
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
