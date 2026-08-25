// Pure snapshot math for Synara Status. QML owns FileView/Process I/O;
// this file turns raw JSON into the record the bar and panel bind against.
// Keep it Qt-free so the same helpers can be exercised under node later.

var PROVIDER_NAMES = {
  claudeAgent: "Claude",
  claude: "Claude",
  codex: "Codex",
  cursor: "Cursor",
  grok: "Grok",
  opencode: "OpenCode",
  antigravity: "Antigravity",
  kilo: "Kilo",
  pi: "Pi",
  droid: "Droid"
}

var ACTIVE_STATUSES = {
  running: true,
  active: true,
  streaming: true,
  busy: true,
  working: true,
  generating: true,
  in_progress: true,
  "in-progress": true,
  thinking: true
}

var ERROR_STATUSES = {
  error: true,
  failed: true,
  crashed: true,
  interrupted: true,
  unavailable: true
}

var HANDOFF_PHASES = {
  pending: true,
  git_applied: true,
  uncertain: true,
  handing_off: true,
  handoff: true
}

var SECRET_KEY_PARTS = ["secret", "token", "password", "credential", "authkey"]

function defaultSnapshot() {
  return {
    ok: true,
    installed: false,
    running: false,
    source: "filesystem",
    homeDir: "",
    stateDir: "",
    runtime: null,
    lastRefreshAt: "",
    lastRefreshMs: 0,
    counts: { activeAgents: 0, worktrees: 0, handoffs: 0, recentTasks: 0 },
    providers: [],
    tasks: [],
    worktrees: [],
    handoffs: [],
    visualState: "idle",
    summary: "Synara not installed",
    statusText: "Offline",
    statusDetail: "Synara was not found on this machine.",
    error: ""
  }
}

function expandPath(path, home) {
  var value = String(path === undefined || path === null ? "" : path).replace(/^\s+|\s+$/g, "")
  var homeDir = String(home || "")
  if (value === "") return ""
  if (value === "~") return homeDir
  if (value.indexOf("~/") === 0) return homeDir + value.substring(1)
  if (value.indexOf("$HOME/") === 0) return homeDir + value.substring(5)
  return value
}

function providerDisplayName(id) {
  var key = String(id || "")
  if (PROVIDER_NAMES[key]) return PROVIDER_NAMES[key]
  if (key === "") return "Unknown"
  return key.charAt(0).toUpperCase() + key.slice(1)
}

function isSecretKey(name) {
  var key = String(name || "").toLowerCase()
  for (var i = 0; i < SECRET_KEY_PARTS.length; i++) {
    if (key.indexOf(SECRET_KEY_PARTS[i]) >= 0) return true
  }
  return false
}

function sanitizeRuntime(raw) {
  if (!raw || typeof raw !== "object") return null
  var pid = Number(raw.pid)
  var port = Number(raw.port)
  return {
    pid: isFinite(pid) && pid > 0 ? pid : 0,
    host: String(raw.host || "127.0.0.1"),
    port: isFinite(port) && port > 0 ? port : 0,
    origin: String(raw.origin || ""),
    startedAt: String(raw.startedAt || "")
  }
}

function normalizeStatus(value) {
  return String(value || "").replace(/^\s+|\s+$/g, "").toLowerCase().replace(/\s+/g, "_")
}

function taskKind(task) {
  var status = normalizeStatus(task && (task.runtimeStatus || task.sessionStatus || task.status))
  if (ERROR_STATUSES[status] || String(task && task.lastError || "") !== "") return "error"
  if (task && task.handoffActive) return "handoff"
  if (ACTIVE_STATUSES[status] || (task && task.openTurn)) return "active"
  return "idle"
}

function deriveVisualState(snapshot) {
  var counts = snapshot && snapshot.counts ? snapshot.counts : { activeAgents: 0, worktrees: 0, handoffs: 0, recentTasks: 0 }
  var tasks = snapshot && Array.isArray(snapshot.tasks) ? snapshot.tasks : []
  var hasError = false
  for (var i = 0; i < tasks.length; i++) {
    if (taskKind(tasks[i]) === "error") hasError = true
  }
  if (hasError) return "error"
  if (Number(counts.handoffs || 0) > 0) return "handoff"
  if (Number(counts.activeAgents || 0) > 0) return "active"
  return "idle"
}

function joinSummary(parts) {
  var out = []
  for (var i = 0; i < parts.length; i++) {
    if (parts[i]) out.push(parts[i])
  }
  return out.join(" · ")
}

function plural(count, noun) {
  var n = Number(count || 0)
  return n + " " + noun + (n === 1 ? "" : "s")
}

function buildSummary(snapshot) {
  if (!snapshot || !snapshot.installed) return "Synara not installed"
  if (!snapshot.running && Number(snapshot.counts && snapshot.counts.recentTasks || 0) === 0)
    return "Synara idle"

  var counts = snapshot.counts || {}
  return joinSummary([
    plural(counts.activeAgents, "active agent"),
    plural(counts.worktrees, "worktree"),
    Number(counts.handoffs || 0) > 0 ? plural(counts.handoffs, "handoff") : ""
  ])
}

function statusTextFor(snapshot) {
  var state = snapshot && snapshot.visualState ? snapshot.visualState : "idle"
  if (!snapshot || !snapshot.installed) return "Offline"
  if (state === "error") return "Error"
  if (state === "handoff") return "Handoff"
  if (state === "active") return "Active"
  if (snapshot.running) return "Idle"
  return "Offline"
}

function statusDetailFor(snapshot) {
  if (!snapshot) return ""
  if (snapshot.error) return snapshot.error
  if (!snapshot.installed) return "Install Synara, then this widget will read $SYNARA_HOME or ~/.synara."
  if (!snapshot.running) return "Synara is not running. Open it to start agents, or refresh after it launches."
  if (snapshot.visualState === "error") return "One or more tasks reported an error."
  if (snapshot.visualState === "handoff") return "A provider handoff or worktree is in progress."
  if (snapshot.visualState === "active") return "Agents are running in isolated worktrees."
  return "No active agents. Synara is ready."
}

function parseSnapshot(raw) {
  var fallback = defaultSnapshot()
  var data = raw
  if (typeof raw === "string") {
    var text = String(raw || "").replace(/^\s+|\s+$/g, "")
    if (text === "") return fallback
    try {
      data = JSON.parse(text)
    } catch (e) {
      fallback.ok = false
      fallback.error = "Failed to parse Synara status"
      return fallback
    }
  }
  if (!data || typeof data !== "object") return fallback

  var snapshot = defaultSnapshot()
  snapshot.ok = data.ok !== false
  snapshot.installed = data.installed === true
  snapshot.running = data.running === true
  snapshot.source = String(data.source || "filesystem")
  snapshot.homeDir = String(data.homeDir || "")
  snapshot.stateDir = String(data.stateDir || "")
  snapshot.runtime = sanitizeRuntime(data.runtime)
  snapshot.lastRefreshAt = String(data.lastRefreshAt || "")
  snapshot.lastRefreshMs = Number(data.lastRefreshMs || 0)
  snapshot.providers = Array.isArray(data.providers) ? data.providers : []
  snapshot.tasks = Array.isArray(data.tasks) ? data.tasks : []
  snapshot.worktrees = Array.isArray(data.worktrees) ? data.worktrees : []
  snapshot.handoffs = Array.isArray(data.handoffs) ? data.handoffs : []
  snapshot.error = String(data.error || "")

  var counts = data.counts && typeof data.counts === "object" ? data.counts : {}
  snapshot.counts = {
    activeAgents: Number(counts.activeAgents || 0),
    worktrees: Number(counts.worktrees || 0),
    handoffs: Number(counts.handoffs || 0),
    recentTasks: Number(counts.recentTasks || snapshot.tasks.length || 0)
  }

  snapshot.visualState = deriveVisualState(snapshot)
  snapshot.summary = buildSummary(snapshot)
  snapshot.statusText = statusTextFor(snapshot)
  snapshot.statusDetail = statusDetailFor(snapshot)
  if (!snapshot.ok && snapshot.error === "") snapshot.error = "Failed to read Synara status"
  return snapshot
}

function relativeTime(isoOrMs, nowMs) {
  var ms = 0
  if (typeof isoOrMs === "number") ms = isoOrMs
  else {
    var parsed = Date.parse(String(isoOrMs || ""))
    if (!isFinite(parsed)) return ""
    ms = parsed
  }
  var now = nowMs === undefined ? Date.now() : Number(nowMs)
  var diff = Math.max(0, Math.floor((now - ms) / 1000))
  if (diff < 10) return "just now"
  if (diff < 60) return diff + "s ago"
  var minutes = Math.floor(diff / 60)
  if (minutes < 60) return minutes + "m ago"
  var hours = Math.floor(minutes / 60)
  if (hours < 24) return hours + "h ago"
  return Math.floor(hours / 24) + "d ago"
}

function taskMeta(task) {
  if (!task) return ""
  var parts = []
  var provider = providerDisplayName(task.provider)
  if (provider && provider !== "Unknown") parts.push(provider)
  var branch = String(task.branch || task.worktreeBranch || "")
  if (branch !== "") parts.push(branch)
  var worktree = String(task.worktreeName || "")
  if (worktree !== "" && worktree !== branch) parts.push(worktree)
  return parts.join(" · ")
}

function worktreeName(path) {
  var value = String(path || "").replace(/\/+$/, "")
  if (value === "") return ""
  var parts = value.split("/")
  return parts[parts.length - 1] || value
}

if (typeof module !== "undefined") {
  module.exports = {
    defaultSnapshot: defaultSnapshot,
    expandPath: expandPath,
    providerDisplayName: providerDisplayName,
    isSecretKey: isSecretKey,
    sanitizeRuntime: sanitizeRuntime,
    normalizeStatus: normalizeStatus,
    taskKind: taskKind,
    deriveVisualState: deriveVisualState,
    parseSnapshot: parseSnapshot,
    relativeTime: relativeTime,
    taskMeta: taskMeta,
    worktreeName: worktreeName,
    statusTextFor: statusTextFor,
    buildSummary: buildSummary
  }
}
