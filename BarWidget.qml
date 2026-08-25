import QtQuick
import QtQuick.Effects
import Quickshell.Io
import qs.Commons
import qs.Ui

// Compact Synara mark for the bar. Left click opens the details panel;
// right click rescans local Synara state. The color and pulse follow the
// snapshot: idle, active agents, in-progress handoffs, or errors.
BarWidget {
  id: root
  moduleName: "io.github.xfurti.synara-status"

  readonly property color foreground: bar ? bar.barForeground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Color.muted
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property bool showLabel: synara.showLabel
  readonly property string visualState: synara.visualState
  readonly property color stateColor: colorForState(visualState)
  readonly property string badgeText: synara.statusText
  readonly property string tooltipText: synara.summary

  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false
  readonly property real openPanelIndicatorWidth: button.labelWidth > 0 ? button.labelWidth : Style.bar.iconCanvas
  readonly property real openPanelIndicatorHeight: Math.max(Style.space(10), Math.round(Style.bar.iconSlot * 0.55))

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

  function open() {
    if (panelLoader.item) panelLoader.item.open()
  }

  function close() {
    if (panelLoader.item) panelLoader.item.close()
  }

  function toggle() {
    if (panelLoader.item) panelLoader.item.toggle()
  }

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  function refresh() {
    synara.refresh()
    if (panelLoader.item && panelLoader.item.refresh) panelLoader.item.refresh()
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
    if ("source" in target) target.source = synara
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Model {
    id: synara
    settings: root.settings
  }

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  IpcHandler {
    target: "io.github.xfurti.synara-status"

    function refresh(): void { root.broadcast("refresh") }
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.showLabel && !root.vertical ? root.badgeText : ""
    labelVisible: false
    hasVisualContent: true
    tooltipText: root.tooltipText
    useActiveColor: false
    foreground: root.stateColor
    active: root.visualState === "error"
    horizontalMargin: 8.5
    verticalPadding: 6
    fixedWidth: root.vertical ? -1 : contentRow.implicitWidth + Style.space(12)
    fixedHeight: root.vertical ? contentRow.implicitHeight + Style.space(8) : -1

    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) root.refresh()
      else if (buttonCode === Qt.MiddleButton) synara.openSynara()
      else root.toggle()
    }

    Row {
      id: contentRow
      anchors.centerIn: parent
      spacing: Style.space(6)

      Item {
        id: mark
        width: Style.bar.iconCanvas
        height: Style.bar.iconCanvas
        anchors.verticalCenter: parent.verticalCenter

        Image {
          id: icon
          anchors.centerIn: parent
          width: Style.bar.iconFont
          height: Style.bar.iconFont
          source: Qt.resolvedUrl("assets/synara.svg")
          sourceSize.width: Style.bar.iconFont * 2
          sourceSize.height: Style.bar.iconFont * 2
          fillMode: Image.PreserveAspectFit
          visible: false
          layer.enabled: true
        }

        MultiEffect {
          anchors.fill: icon
          source: icon
          colorization: 1.0
          colorizationColor: root.stateColor
          opacity: root.visualState === "active" ? pulse.amount : 1
        }

        Rectangle {
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          width: Math.max(5, Style.space(5))
          height: width
          radius: width / 2
          color: root.stateColor
          visible: root.visualState !== "idle"
          opacity: root.visualState === "active" ? pulse.amount : 1
        }

        Item {
          id: pulse
          property real amount: 1

          SequentialAnimation on amount {
            running: root.visualState === "active"
            loops: Animation.Infinite
            NumberAnimation { from: 1; to: 0.42; duration: 900; easing.type: Easing.InOutSine }
            NumberAnimation { from: 0.42; to: 1; duration: 900; easing.type: Easing.InOutSine }
          }
        }
      }

      Text {
        visible: root.showLabel && !root.vertical
        anchors.verticalCenter: parent.verticalCenter
        text: root.badgeText
        color: root.stateColor
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
      }
    }
  }
}
