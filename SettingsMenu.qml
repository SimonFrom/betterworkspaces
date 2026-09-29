import QtQuick
import qs.Commons
import qs.Ui

// The right-click settings menu. Every change goes through
// widget.saveSetting(), which persists it to shell.json.
KeyboardPanel {
  id: panel

  // The BetterWorkspaces widget whose settings this edits.
  required property var widget

  owner: widget
  bar: widget.bar
  open: widget.opened
  focusTarget: keyCatcher
  contentWidth: panel.fittedContentWidth(Style.space(320))
  contentHeight: panel.fittedContentHeight(menuColumn.implicitHeight)

  PanelKeyCatcher {
    id: keyCatcher
    anchors.fill: parent
    onCloseRequested: widget.close()
    onTabRequested: function(direction) { widget.switchPanel(direction) }

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
          color: widget.barForeground
          font.family: widget.bar ? widget.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.title
          font.bold: true
        }

        Text {
          textFormat: Text.PlainText
          text: "WORKSPACE SETTINGS"
          color: Qt.darker(widget.barForeground, 1.4)
          font.family: widget.bar ? widget.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.caption
          font.bold: true
          font.letterSpacing: 1.2
        }
      }

      PanelSeparator { foreground: widget.barForeground }

      SettingRow {
        label: "Icon size"
        NumberField {
          value: widget.iconSize
          from: 8
          to: 32
          foreground: widget.barForeground
          onModified: function(v) { widget.saveSetting("iconSize", v) }
        }
      }

      SettingRow {
        label: "Padding"
        NumberField {
          value: widget.padding
          from: 0
          to: 16
          foreground: widget.barForeground
          onModified: function(v) { widget.saveSetting("padding", v) }
        }
      }

      PanelSeparator { foreground: widget.barForeground }

      Column {
        width: parent.width
        spacing: Style.space(10)

        PanelSectionHeader {
          text: "UNUSED WORKSPACES"
          foreground: widget.barForeground
        }

        ButtonGroup {
          focusable: false
          options: [
            { value: "dots", label: "Dots" },
            { value: "numbers", label: "Numbers" }
          ]
          value: widget.emptyStyle
          foreground: widget.barForeground
          onChanged: function(v) { widget.saveSetting("emptyStyle", v) }
        }
      }

      Column {
        width: parent.width
        spacing: Style.space(10)

        PanelSectionHeader {
          text: "WORKSPACES"
          foreground: widget.barForeground
        }

        ButtonGroup {
          focusable: false
          options: [
            { value: "fixed", label: "Fixed" },
            { value: "dynamic", label: "Dynamic" }
          ]
          value: widget.dynamicWorkspaces ? "dynamic" : "fixed"
          foreground: widget.barForeground
          onChanged: function(v) {
            widget.saveSetting("workspaces", v === "dynamic" ? "dynamic" : widget.lastFixedCount)
          }
        }

        SettingRow {
          visible: !widget.dynamicWorkspaces
          label: "Always show"
          NumberField {
            value: widget.workspaceCount
            from: 1
            to: 10
            foreground: widget.barForeground
            onModified: function(v) {
              widget.lastFixedCount = v
              widget.saveSetting("workspaces", v)
            }
          }
        }

        Text {
          width: parent.width
          wrapMode: Text.WordWrap
          textFormat: Text.PlainText
          text: widget.dynamicWorkspaces
            ? "Only workspaces with windows, plus the active one."
            : "Workspaces 1–" + widget.workspaceCount + ", plus any others with windows."
          color: widget.barForeground
          opacity: 0.6
          font.family: widget.bar ? widget.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.bodySmall
        }
      }

      PanelSeparator { foreground: widget.barForeground }

      Column {
        width: parent.width
        spacing: Style.space(10)

        PanelSectionHeader {
          text: "ACTIVITY"
          foreground: widget.barForeground
        }

        SettingRow {
          label: "Running animation"
          ToggleSwitch {
            checked: widget.showActivity
            foreground: widget.barForeground
            cursorRing: false
            onToggled: widget.saveSetting("showActivity", !widget.showActivity)
          }
        }

        SettingRow {
          label: "Attention dot"
          ToggleSwitch {
            checked: widget.showBadges
            foreground: widget.barForeground
            cursorRing: false
            onToggled: widget.saveSetting("showBadges", !widget.showBadges)
          }
        }

        SettingRow {
          visible: widget.showBadges
          label: "Dot for notifications"
          ToggleSwitch {
            checked: widget.badgeNotifications
            foreground: widget.barForeground
            cursorRing: false
            onToggled: widget.saveSetting("badgeNotifications", !widget.badgeNotifications)
          }
        }

        SettingRow {
          label: "Downloads"
          ToggleSwitch {
            checked: widget.useDisk
            foreground: widget.barForeground
            cursorRing: false
            onToggled: widget.saveSetting("diskActivity", !widget.useDisk)
          }
        }

        SettingRow {
          label: "herdr agents"
          ToggleSwitch {
            checked: widget.useHerdr
            foreground: widget.barForeground
            cursorRing: false
            onToggled: widget.saveSetting("herdr", !widget.useHerdr)
          }
        }

        Text {
          width: parent.width
          wrapMode: Text.WordWrap
          textFormat: Text.PlainText
          text: "The border circles while an agent is working or an app is downloading. The dot "
            + "means something finished or wants attention, and clears when you visit."
          color: widget.barForeground
          opacity: 0.6
          font.family: widget.bar ? widget.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.bodySmall
        }
      }

      PanelSeparator { foreground: widget.barForeground }

      Column {
        width: parent.width
        spacing: Style.space(10)

        PanelSectionHeader {
          text: "POSITION"
          foreground: widget.barForeground
        }

        ButtonGroup {
          focusable: false
          options: widget.vertical
            ? [{ value: "left", label: "Top" }, { value: "center", label: "Middle" }, { value: "right", label: "Bottom" }]
            : [{ value: "left", label: "Left" }, { value: "center", label: "Center" }, { value: "right", label: "Right" }]
          value: widget.barLocation.section
          foreground: widget.barForeground
          onChanged: function(v) {
            if (v !== widget.barLocation.section) widget.moveTo(v, v === "right")
          }
        }

        ButtonGroup {
          focusable: false
          options: [
            { value: "start", label: "First in section" },
            { value: "end", label: "Last in section" }
          ]
          value: widget.barLocation.index === 0 ? "start"
            : (widget.barLocation.index === widget.barLocation.count - 1 ? "end" : "")
          foreground: widget.barForeground
          onChanged: function(v) {
            if (widget.barLocation.section) widget.moveTo(widget.barLocation.section, v === "start")
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
      color: panel.widget.barForeground
      font.family: panel.widget.bar ? panel.widget.bar.fontFamily : Style.font.family
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
