import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "Model.js" as Model

// Live Synara snapshot. The bar and panel bind to this item; swapping the
// scanner command later (MCP, a dedicated status HTTP route) does not
// change the QML properties they already read.
Item {
  id: root
  visible: false

  property var settings: ({})
  property var snapshot: Model.defaultSnapshot()
  property bool refreshing: false
  property string lastError: ""
  property double nowMs: Date.now()
  property string actionStatus: ""

  readonly property string home: Quickshell.env("HOME") || ""
  readonly property string configuredDataDir: String(setting("dataDir", ""))
  readonly property string statusEndpoint: String(setting("statusEndpoint", ""))
  readonly property string launchCommand: String(setting("launchCommand", "gtk-launch synara"))
  readonly property int refreshIntervalSec: Math.max(5, Math.min(300, parseInt(String(setting("refreshIntervalSec", 15)), 10) || 15))
  readonly property bool showLabel: setting("showLabel", false) === true || setting("showLabel", false) === "true"

  readonly property bool installed: snapshot.installed === true
  readonly property bool running: snapshot.running === true
  readonly property string visualState: String(snapshot.visualState || "idle")
  readonly property string summary: String(snapshot.summary || "")
  readonly property string statusText: String(snapshot.statusText || "Offline")
  readonly property string statusDetail: String(snapshot.statusDetail || "")
  readonly property var counts: snapshot.counts || { activeAgents: 0, worktrees: 0, handoffs: 0, recentTasks: 0 }
  readonly property var tasks: snapshot.tasks || []
  readonly property var providers: snapshot.providers || []
  readonly property string lastRefreshLabel: snapshot.lastRefreshMs
    ? Model.relativeTime(snapshot.lastRefreshMs, root.nowMs)
    : "never"

  readonly property string scannerPath: {
    var url = Qt.resolvedUrl("scripts/scan.py").toString()
    if (url.indexOf("file://") === 0) {
      var path = url.substring(7)
      if (path.charAt(0) !== "/") path = "/" + path
      try { return decodeURIComponent(path) } catch (e) { return path }
    }
    return url
  }

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function refresh() {
    if (scanProcess.running) return
    refreshing = true
    lastError = ""
    scanProcess.command = [
      "python3", scannerPath,
      "--data-dir", configuredDataDir,
      "--endpoint", statusEndpoint
    ]
    scanProcess.running = true
  }

  function applyOutput(raw) {
    var parsed = Model.parseSnapshot(raw)
    parsed.lastRefreshMs = Date.now()
    parsed.lastRefreshAt = new Date(parsed.lastRefreshMs).toISOString()
    snapshot = parsed
    lastError = parsed.error || ""
    nowMs = parsed.lastRefreshMs
  }

  function openSynara() {
    var command = launchCommand.replace(/^\s+|\s+$/g, "")
    if (command === "") command = "gtk-launch synara"
    Util.execDetached(command)
  }

  function focusSynara() {
    Util.execArgv(["hyprctl", "dispatch", "focuswindow", "class:Synara"])
  }

  function openWorktree(task) {
    var path = task && (task.worktreePath || task.workingDirectory)
    if (!path) {
      actionStatus = "No worktree path on this task yet."
      return
    }
    Util.execArgv(["xdg-open", path])
  }

  function stopTask(task) {
    var title = task && task.title ? task.title : "this task"
    actionStatus = "Stop is a stub until Synara exposes a local control API (" + title + ")."
  }

  Process {
    id: scanProcess
    running: false
    onExited: function(exitCode) {
      root.refreshing = false
      if (exitCode !== 0 && root.lastError === "")
        root.lastError = "Synara scanner exited with " + exitCode
    }

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyOutput(text)
    }

    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (String(text || "").trim() !== "")
        console.warn("synara-status", String(text).trim())
    }
  }

  Timer {
    interval: root.refreshIntervalSec * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Timer {
    interval: 30000
    running: true
    repeat: true
    onTriggered: root.nowMs = Date.now()
  }

  FileView {
    path: root.snapshot.stateDir
      ? root.snapshot.stateDir + "/server-runtime.json"
      : root.home + "/.cache/omarchy/synara-status-disabled.json"
    watchChanges: true
    printErrors: false
    onFileChanged: root.refresh()
  }
}
