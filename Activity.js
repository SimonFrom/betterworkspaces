.pragma library

// Activity rules: what counts as running, finished, or a download, and how
// it reads in the tooltip. No QML dependencies; ActivityTracker.qml feeds it.

// Claude Code and many TUIs put a spinner at the front of the title while
// working: braille dots (U+2801-U+28FF) or quarter circles.
function isSpinnerTitle(title) {
  if (!title) return false
  var c = title.charCodeAt(0)
  if (c > 0x2800 && c <= 0x28FF) return true
  return "◐◓◑◒◴◵◶◷".indexOf(title.charAt(0)) !== -1
}

function formatRate(bytesPerSecond) {
  var mb = bytesPerSecond / (1024 * 1024)
  return (mb >= 10 ? Math.round(mb) : mb.toFixed(1)) + " MB/s"
}

// ---------- herdr ----------

// Output of the herdr probe: line 1 is the comma-separated pids of terminals
// hosting a herdr client, the rest is `herdr api snapshot` JSON.
// Returns { pids: [], statuses: [] }.
function parseHerdr(text) {
  var lines = String(text || "").split("\n")
  var result = { pids: [], statuses: [] }
  if (lines.length < 2) return result

  result.pids = lines[0].split(",").map(Number).filter(function(p) { return p > 0 })
  try {
    var agents = JSON.parse(lines.slice(1).join("\n")).result.snapshot.agents || []
    result.statuses = agents.map(function(agent) { return String(agent.agent_status || "") })
  } catch (e) {
    result.statuses = []
  }
  return result
}

// ---------- Disk and network ----------

var DISK_THRESHOLD = 1024 * 1024       // bytes/s written that counts as busy
var NET_THRESHOLD = 256 * 1024         // bytes/s received that makes it a download
var BUSY_AFTER = 3                     // samples over the threshold (~4.5s)
var IDLE_AFTER = 4                     // samples under the threshold (~6s)
var FINISHED_MIN_MS = 15000            // shorter busy spells don't raise the dot

// disk-activity.sh output: "<pid> <disk bytes> <net bytes>" per line.
function parseDiskLines(text) {
  var samples = []
  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var parts = lines[i].trim().split(/\s+/)
    if (parts.length !== 3) continue
    var pid = Number(parts[0])
    var bytes = Number(parts[1])
    var net = Number(parts[2])
    if (!(pid > 0) || !isFinite(bytes) || !isFinite(net)) continue
    samples.push({ pid: pid, bytes: bytes, net: net })
  }
  return samples
}

// Advance one app's disk state by a sample taken at `now` (ms).
// State: { bytes, net, time, streak, busy, rate, since, download }
//   streak   + samples over the threshold in a row, - samples under
//   busy     the app is running; rate is the last rate over the threshold
//   since    when the busy spell began
//   download the spell received over the network at some point
// Returns { state, finished }: finished is true when a spell of at least
// FINISHED_MIN_MS just ended.
function stepDisk(prev, sample, now) {
  var streak = prev ? prev.streak : 0
  var rate = 0
  var netRate = 0

  if (prev && now > prev.time && sample.bytes >= prev.bytes) {
    rate = (sample.bytes - prev.bytes) * 1000 / (now - prev.time)
    // Closed sockets drop out of the total; a negative delta says nothing.
    netRate = sample.net > prev.net ? (sample.net - prev.net) * 1000 / (now - prev.time) : 0
    if (rate >= DISK_THRESHOLD) streak = Math.max(1, streak + 1)
    else streak = Math.min(-1, streak - 1)
  }

  var wasBusy = !!(prev && prev.busy)
  var state = { bytes: sample.bytes, net: sample.net, time: now, streak: streak,
                busy: false, rate: 0, since: 0, download: false }

  if (streak >= BUSY_AFTER || (wasBusy && streak > -IDLE_AFTER)) {
    state.busy = true
    // While dipping below the threshold, keep showing the last real rate.
    state.rate = rate >= DISK_THRESHOLD || !wasBusy ? rate : prev.rate
    state.since = wasBusy ? prev.since : now
    state.download = (wasBusy && prev.download) || netRate >= NET_THRESHOLD
    return { state: state, finished: false }
  }

  return { state: state, finished: wasBusy && now - prev.since >= FINISHED_MIN_MS }
}

// ---------- Notifications ----------

// A notification's app name reduced for matching, or "" to ignore it.
function notificationKey(app) {
  var name = String(app || "").toLowerCase().replace(/[^a-z0-9]/g, "")
  if (name.length < 3 || name === "notifysend" || name === "omarchyaction") return ""
  return name
}

// "discord" matches chrome-discord.com__..., "googlechrome" matches
// google-chrome. Short class names only match whole-name containment one way.
function notificationMatches(key, appId) {
  var cls = String(appId || "").toLowerCase().replace(/[^a-z0-9]/g, "")
  if (!key || !cls) return false
  return cls.indexOf(key) !== -1 || (cls.length >= 4 && key.indexOf(cls) !== -1)
}

// ---------- Tooltip ----------

// Tooltip lines for a workspace's activity counts:
// { working, blocked, done, spinning, writing, downloadRate, unseen }
function notes(counts) {
  var lines = []
  if (counts.working) lines.push(counts.working + (counts.working === 1 ? " agent running" : " agents running"))
  else if (counts.spinning || counts.writing) lines.push("Running")
  if (counts.downloadRate > 0) lines.push("Downloading · " + formatRate(counts.downloadRate))
  if (counts.blocked) lines.push(counts.blocked + (counts.blocked === 1 ? " agent needs input" : " agents need input"))
  if (counts.done) lines.push(counts.done + (counts.done === 1 ? " agent finished" : " agents finished"))
  if (counts.unseen) lines.push("New activity")
  return lines
}
