import QtQuick
import QtQuick.Controls
import QtQuick.Effects
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Details popout for the Synara bar widget. The bar host is BarWidget.qml;
// this panel only paints once that widget injects bar, anchor, and source.
Panel {
  id: root
  moduleName: "io.github.xfurti.synara-status"
  ipcTarget: "io.github.xfurti.synara-status"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  property var source: null
  readonly property var barIdentity: hostWidget || root

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color surface: Color.popups.background
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property var snapshot: source && source.snapshot ? source.snapshot : Model.defaultSnapshot()
  readonly property var allTasks: source && source.tasks ? source.tasks : []
  readonly property var tasks: Model.liveTasks(allTasks)
  readonly property var counts: source && source.counts ? source.counts : { activeAgents: 0, worktrees: 0, handoffs: 0, recentTasks: 0 }
  readonly property string visualState: source ? String(source.visualState || "idle") : "idle"
  readonly property color stateColor: colorForState(visualState)
  readonly property string actionStatus: source ? String(source.actionStatus || "") : ""

  property bool cursorActive: false
  property string focusSection: "tasks"
  property int taskIndex: 0
  property int footerIndex: 0

  readonly property var footerActions: [
    { id: "open", label: "Open Synara", icon: "󰏌" },
    { id: "refresh", label: "Refresh", icon: "󰑐" }
  ]

  function colorChannelLuminance(value) {
    var channel = Number(value)
    if (!isFinite(channel)) return 0
    return channel <= 0.03928 ? channel / 12.92 : Math.pow((channel + 0.055) / 1.055, 2.4)
  }

  function colorLuminance(color) {
    return 0.2126 * colorChannelLuminance(color.r)
      + 0.7152 * colorChannelLuminance(color.g)
      + 0.0722 * colorChannelLuminance(color.b)
  }

  function colorForState(state) {
    var light = colorLuminance(Color.background) >= 0.5
    if (state === "error") return root.urgent
    if (state === "active") return light ? Qt.rgba(0.16, 0.52, 0.30, 1) : Qt.rgba(0.48, 0.84, 0.60, 1)
    if (state === "handoff") return light ? Qt.rgba(0.70, 0.46, 0.08, 1) : Qt.rgba(0.93, 0.74, 0.34, 1)
    return root.dim
  }

  function alpha(c, a) {
    return Qt.rgba(c.r, c.g, c.b, a)
  }

  function open() {
    if (root.source && root.source.refresh) root.source.refresh()
    root.controller.show()
    Qt.callLater(function() {
      if (root.opened) setCenterHoverRevealSuppressed(true)
      if (keyCatcher) keyCatcher.forceActiveFocus()
    })
  }

  function close() {
    setCenterHoverRevealSuppressed(false)
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open()
  }

  function refresh() {
    if (root.source && root.source.refresh) root.source.refresh()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function setCenterHoverRevealSuppressed(value) {
    if (root.bar && "centerHoverRevealSuppressed" in root.bar)
      root.bar.centerHoverRevealSuppressed = value
  }

  function clamp(v, lo, hi) {
    return Math.max(lo, Math.min(hi, v))
  }

  function selectedTask() {
    if (root.tasks.length === 0) return null
    return root.tasks[clamp(root.taskIndex, 0, root.tasks.length - 1)]
  }

  function ensureCursor() {
    if (root.tasks.length === 0) {
      focusSection = "footer"
      taskIndex = 0
      return
    }
    if (focusSection !== "tasks" && focusSection !== "footer") focusSection = "tasks"
    taskIndex = clamp(taskIndex, 0, root.tasks.length - 1)
  }

  function moveCursor(dx, dy) {
    cursorActive = true
    ensureCursor()
    if (dx !== 0 && focusSection === "footer") {
      footerIndex = clamp(footerIndex + dx, 0, root.footerActions.length - 1)
      return
    }
    if (dy === 0) return
    if (focusSection === "tasks") {
      if (dy > 0 && taskIndex >= root.tasks.length - 1) {
        focusSection = "footer"
        footerIndex = 0
        return
      }
      taskIndex = clamp(taskIndex + dy, 0, Math.max(0, root.tasks.length - 1))
      scrollCursorIntoView()
      return
    }
    if (focusSection === "footer" && dy < 0 && root.tasks.length > 0) {
      focusSection = "tasks"
      taskIndex = root.tasks.length - 1
      scrollCursorIntoView()
    }
  }

  function activateCursor() {
    ensureCursor()
    if (focusSection === "footer") runFooter(footerIndex)
    else if (focusSection === "tasks") focusTask(selectedTask())
  }

  function runFooter(index) {
    var action = root.footerActions[index]
    if (!action || !root.source) return
    if (action.id === "open") root.source.openSynara()
    else root.source.refresh()
  }

  function focusTask(task) {
    if (!root.source) return
    root.source.focusSynara()
    root.source.actionStatus = task
      ? "Focusing Synara · " + String(task.title || "task")
      : "Focusing Synara"
  }

  function openDiff(task) {
    if (root.source) root.source.openWorktree(task)
  }

  function stopTask(task) {
    if (root.source) root.source.stopTask(task)
  }

  function setTaskCursor(index) {
    cursorActive = true
    focusSection = "tasks"
    taskIndex = index
    scrollCursorIntoView()
  }

  function setFooterCursor(index) {
    cursorActive = true
    focusSection = "footer"
    footerIndex = index
  }

  function scrollCursorIntoView() {
    if (focusSection !== "tasks" || !taskColumn) return
    if (taskIndex < 0 || taskIndex >= taskColumn.children.length) return
    var item = taskColumn.children[taskIndex]
    if (!panelFlick || !item) return
    Qt.callLater(function() {
      if (!item) return
      var margin = Style.space(6)
      var point = item.mapToItem(panelFlick.contentItem, 0, 0)
      var top = point.y
      var bottom = top + item.height
      var viewTop = panelFlick.contentY
      var viewBottom = viewTop + panelFlick.height
      var maxY = Math.max(0, panelFlick.contentHeight - panelFlick.height)
      if (top < viewTop + margin) panelFlick.contentY = Math.max(0, top - margin)
      else if (bottom > viewBottom - margin) panelFlick.contentY = Math.min(maxY, bottom + margin - panelFlick.height)
    })
  }

  function taskKind(task) {
    return Model.taskKind(task)
  }

  function taskStatusLabel(task) {
    var kind = taskKind(task)
    if (kind === "error") return "Error"
    if (kind === "handoff") return "Handoff"
    if (kind === "active") return "Running"
    return "Idle"
  }

  function heroMeta() {
    if (!root.source) return "Waiting"
    if (root.source.refreshing) return "Refreshing"
    if (root.source.lastRefreshLabel) return "Updated " + root.source.lastRefreshLabel
    return "Local snapshot"
  }

  onOpenedChanged: if (opened) {
    cursorActive = false
    focusSection = root.tasks.length > 0 ? "tasks" : "footer"
    taskIndex = 0
    footerIndex = 0
    if (panelFlick) panelFlick.contentY = 0
    if (root.source && root.source.refresh) root.source.refresh()
    Qt.callLater(function() { if (keyCatcher) keyCatcher.forceActiveFocus() })
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(620))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        root.moveCursor(dx, dy)
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "r" || t === "R") root.refresh()
        else if (t === "o" || t === "O") { if (root.source) root.source.openSynara() }
        else if (t === "f" || t === "F") root.focusTask(root.selectedTask())
        else if (t === "d" || t === "D") root.openDiff(root.selectedTask())
        else if (t === "s" || t === "S") root.stopTask(root.selectedTask())
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          PanelHero {
            id: hero
            width: parent.width
            title: "Synara"
            meta: root.heroMeta()
            detail: root.snapshot.statusText || "Offline"
            foreground: root.foreground
            fontFamily: root.fontFamily

            iconComponent: Component {
              Item {
                width: Style.font.display
                height: Style.font.display

                Image {
                  id: heroIcon
                  anchors.fill: parent
                  source: Qt.resolvedUrl("assets/synara.svg")
                  sourceSize.width: Style.font.display * 2
                  sourceSize.height: Style.font.display * 2
                  fillMode: Image.PreserveAspectFit
                  visible: false
                  layer.enabled: true
                }

                MultiEffect {
                  anchors.fill: heroIcon
                  source: heroIcon
                  colorization: 1.0
                  colorizationColor: root.stateColor
                }
              }
            }
          }

          BorderSurface {
            visible: String(root.snapshot.statusDetail || "") !== ""
            width: parent.width
            implicitHeight: statusText.implicitHeight + Style.spacing.xl * 2
            color: root.visualState === "error"
              ? root.alpha(root.urgent, 0.10)
              : Style.normalFillFor(root.foreground, Color.accent)
            borderSpec: Border.flat(
              root.visualState === "error" ? root.alpha(root.urgent, 0.35) : Style.normalBorderFor(root.foreground, Color.accent),
              1
            )
            radius: Style.cornerRadius

            Text {
              id: statusText
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.space(12)
              anchors.rightMargin: Style.space(12)
              text: root.snapshot.statusDetail || ""
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }

          PanelSeparator { foreground: root.foreground }

          Grid {
            id: summaryGrid
            width: parent.width
            columns: 2
            columnSpacing: Style.space(8)
            rowSpacing: Style.space(8)

            SummaryCard {
              width: (summaryGrid.width - summaryGrid.columnSpacing) / 2
              label: "Active Agents"
              value: String(root.counts.activeAgents || 0)
            }
            SummaryCard {
              width: (summaryGrid.width - summaryGrid.columnSpacing) / 2
              label: "Worktrees"
              value: String(root.counts.worktrees || 0)
            }
            SummaryCard {
              width: (summaryGrid.width - summaryGrid.columnSpacing) / 2
              label: "Handoffs"
              value: String(root.counts.handoffs || 0)
            }
            SummaryCard {
              width: (summaryGrid.width - summaryGrid.columnSpacing) / 2
              label: "Recent Tasks"
              value: String(root.counts.recentTasks || 0)
            }
          }

          PanelSeparator { foreground: root.foreground }

          PanelSectionHeader {
            width: parent.width
            text: "TASKS"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Text {
            visible: root.tasks.length === 0
            width: parent.width
            text: !root.snapshot.installed
              ? "Install Synara to see agents, worktrees, and handoffs here."
              : (root.allTasks.length > 0
                ? "Nothing running right now."
                : "No recent tasks yet. Start one in Synara and refresh.")
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            wrapMode: Text.WordWrap
          }

          Column {
            id: taskColumn
            width: parent.width
            spacing: Style.space(4)

            Repeater {
              model: root.tasks

              TaskRow {
                required property var modelData
                required property int index
                width: taskColumn.width
                task: modelData
                rowIndex: index
              }
            }
          }

          Text {
            visible: root.actionStatus !== ""
            width: parent.width
            text: root.actionStatus
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          PanelSeparator { foreground: root.foreground }

          Row {
            id: footerRow
            width: parent.width
            spacing: Style.space(8)

            Repeater {
              model: root.footerActions

              Button {
                required property var modelData
                required property int index
                width: (footerRow.width - footerRow.spacing) / 2
                text: modelData.label
                iconText: modelData.icon
                bordered: true
                selected: root.cursorActive && root.focusSection === "footer" && root.footerIndex === index
                hasCursor: selected
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.bodySmall
                onClicked: {
                  root.setFooterCursor(index)
                  root.runFooter(index)
                }
                onHovered: function(isHovered) { if (isHovered) root.setFooterCursor(index) }
              }
            }
          }
        }
      }
    }
  }

  component SummaryCard: BorderSurface {
    id: card
    property string label: ""
    property string value: ""

    implicitHeight: cardColumn.implicitHeight + Style.space(16)
    color: Style.normalFillFor(root.foreground, Color.accent)
    borderSpec: Border.controlSpec("normal", root.foreground, Color.accent)
    radius: Style.cornerRadius

    Column {
      id: cardColumn
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(12)
      anchors.rightMargin: Style.space(12)
      spacing: Style.space(2)

      Text {
        text: card.label.toUpperCase()
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
        font.letterSpacing: 1
      }

      Text {
        text: card.value
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.heading
        font.bold: true
      }
    }
  }

  component TaskRow: CursorSurface {
    id: taskRow
    property var task: null
    property int rowIndex: 0
    readonly property string kind: root.taskKind(task)

    hasCursor: root.cursorActive && root.focusSection === "tasks" && root.taskIndex === rowIndex
    foreground: root.foreground
    implicitHeight: taskBody.implicitHeight + Style.spacing.rowPaddingX

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: root.setTaskCursor(taskRow.rowIndex)
      onClicked: root.focusTask(taskRow.task)
    }

    Column {
      id: taskBody
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(6)

      Row {
        width: parent.width
        spacing: Style.space(8)

        Rectangle {
          width: Style.space(8)
          height: Style.space(8)
          radius: width / 2
          anchors.verticalCenter: parent.verticalCenter
          color: root.colorForState(taskRow.kind)
        }

        Column {
          width: parent.width - Style.space(16) - parent.spacing
          spacing: Style.space(1)

          Row {
            width: parent.width
            spacing: Style.space(8)

            Text {
              width: Math.max(0, parent.width - statusLabel.implicitWidth - parent.spacing)
              text: taskRow.task ? String(taskRow.task.title || "Untitled task") : "Untitled task"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              elide: Text.ElideRight
            }

            Text {
              id: statusLabel
              text: root.taskStatusLabel(taskRow.task)
              color: root.colorForState(taskRow.kind)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
            }
          }

          Text {
            width: parent.width
            text: Model.taskMeta(taskRow.task)
            visible: text !== ""
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }
      }

      Row {
        visible: taskRow.hasCursor
        spacing: Style.space(6)

        PanelActionButton {
          iconText: "󰖯"
          tooltipText: "Focus"
          foreground: root.foreground
          fontFamily: root.fontFamily
          onClicked: root.focusTask(taskRow.task)
        }
        PanelActionButton {
          iconText: "󰡏"
          tooltipText: "Open Diff"
          foreground: root.foreground
          fontFamily: root.fontFamily
          enabled: !!(taskRow.task && (taskRow.task.worktreePath || taskRow.task.workingDirectory))
          onClicked: root.openDiff(taskRow.task)
        }
        PanelActionButton {
          iconText: "󰓛"
          tooltipText: "Stop"
          foreground: root.foreground
          hoverColor: root.urgent
          fontFamily: root.fontFamily
          onClicked: root.stopTask(taskRow.task)
        }
      }
    }
  }
}
