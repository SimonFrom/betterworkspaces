import QtQuick
import QtQuick.Effects
import QtQuick.Layouts
import QtQuick.Shapes
import Quickshell.Hyprland
import qs.Commons
import qs.Ui

// One workspace in the bar: app icons (or an empty marker), the active
// border, the running dash, the attention dot and the hover tooltip.
WidgetButton {
  id: button

  // The BetterWorkspaces widget: settings, workspace lookups, menu toggle.
  required property var widget
  required property int modelData

  readonly property var workspace: widget.workspaceById(modelData)
  readonly property bool occupied: workspace !== null && workspace.toplevels.values.length > 0
  readonly property bool focused: Hyprland.focusedWorkspace !== null && Hyprland.focusedWorkspace.id === modelData
  readonly property var apps: widget.showIcons ? widget.workspaceApps(workspace) : []
  readonly property int shownCount: Math.min(apps.length, widget.maxIcons)
  readonly property int overflow: apps.length - shownCount
  readonly property string numberText: modelData === 10 ? "0" : String(modelData)
  readonly property var activity: widget.tracker.activityFor(modelData, workspace)

  bar: widget.bar
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
  fixedWidth: widget.vertical ? widget.barSize : Math.max(Style.space(20), content.implicitWidth + Style.spaceReal(12) + widget.padding * 2)
  fixedHeight: widget.vertical ? Math.max(widget.barSize, content.implicitHeight + Style.spaceReal(12) + widget.padding * 2) : widget.barSize
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
    if (b === Qt.RightButton) widget.toggle()
    else widget.focusWorkspace(modelData)
  }

  // Soft accent glow when hovering an inactive workspace: a blurred
  // copy of the pill shape, painted behind everything else.
  Rectangle {
    id: glowShape
    anchors.fill: highlight
    radius: widget.activeRadius
    color: widget.activeBorder
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
    radius: widget.activeRadius
    color: widget.activeFill
    border.width: 1.5
    border.color: widget.activeBorder
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
    readonly property real r: Math.min(widget.activeRadius, w / 2, h / 2)
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
      strokeColor: button.focused ? "transparent" : Util.alpha(widget.activeBorder, 0.25)
      fillColor: "transparent"
      PathRectangle {
        x: runner.inset; y: runner.inset
        width: runner.w; height: runner.h
        radius: runner.r
      }
    }

    ShapePath {
      strokeWidth: runner.stroke
      strokeColor: button.focused ? button.foreground : widget.activeBorder
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
    columns: widget.vertical ? 1 : 2 + button.shownCount
    rowSpacing: Style.spaceReal(2)
    columnSpacing: Style.spaceReal(3)

    // Marker for workspaces with no app icons, so they stay visible
    // and clickable: a dot or the workspace number.
    Rectangle {
      visible: button.apps.length === 0 && widget.emptyStyle === "dots"
      Layout.alignment: Qt.AlignCenter
      implicitWidth: Math.round(widget.iconSize * 0.35)
      implicitHeight: implicitWidth
      radius: width / 2
      color: button.foreground
    }

    Text {
      visible: button.apps.length === 0 && widget.emptyStyle === "numbers"
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
        Layout.preferredWidth: widget.iconSize
        Layout.preferredHeight: widget.iconSize
        source: modelData.icon
        sourceSize.width: widget.iconSize * Screen.devicePixelRatio
        sourceSize.height: widget.iconSize * Screen.devicePixelRatio
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
    readonly property real size: Math.max(8, Math.round(widget.iconSize * 0.5))
    width: size
    height: size
    radius: size / 2
    x: highlight.x + highlight.width - size - 1
    y: highlight.y + 1
    color: widget.badgeColor
    border.width: 1
    border.color: Color.background
    scale: button.activity.badge ? 1 : 0
    visible: scale > 0

    Behavior on scale {
      NumberAnimation { duration: 180; easing.type: Easing.OutBack }
    }
  }
}
