.pragma library

// Which icon names to try for a window's app id. No QML dependencies; the
// widget resolves the names with Quickshell.iconPath.

// Chromium web apps (omarchy-launch-webapp) get a class like
// "chrome-discord.com__channels_@me-Default": host + path with "/" -> "_".
// Returns { key, host } for such a class, or null.
function webAppKey(appId) {
  var match = /^(?:chrome|chromium|brave|msedge|vivaldi)-(.+)-[^-]+$/.exec(String(appId || ""))
  if (!match) return null
  return { key: match[1], host: match[1].split("__")[0] }
}

// The same { key, host } for the first URL in a desktop entry's Exec line.
function execUrlKey(exec) {
  var url = /https?:\/\/([^\/\s"']+)([^\s"']*)/.exec(String(exec || ""))
  if (!url) return null
  return { key: url[1] + "_" + (url[2] || "/").replace(/\//g, "_"), host: url[1] }
}

// The desktop entry that launches a web app window's URL: an exact URL match,
// else the first entry on the same host. Entries need `execString` or
// `command` (Quickshell DesktopEntry).
function findWebAppEntry(appId, entries) {
  var app = webAppKey(appId)
  if (!app) return null
  var hostMatch = null

  for (var i = 0; i < entries.length; i++) {
    var entry = entries[i]
    var exec = entry.execString || (entry.command || []).join(" ")
    var url = execUrlKey(exec)
    if (!url) continue
    if (url.key === app.key) return entry
    if (!hostMatch && url.host === app.host) hostMatch = entry
  }

  return hostMatch
}

// Icon names to try in order: the desktop entry's icon, then the app id as
// given, lowercased, and its last dotted part (org.gnome.Nautilus -> nautilus).
function iconCandidates(appId, entryIcon) {
  var candidates = []
  if (entryIcon) candidates.push(String(entryIcon))
  candidates.push(appId, appId.toLowerCase())
  var lastDot = appId.lastIndexOf(".")
  if (lastDot >= 0) candidates.push(appId.substring(lastDot + 1).toLowerCase())
  return candidates.filter(function(name) { return !!name })
}
