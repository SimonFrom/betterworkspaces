.pragma library

// Accessors for Quickshell HyprlandToplevel objects. Plain functions over
// duck-typed objects, so they can be tested with fakes.

function appId(toplevel) {
  if (!toplevel) return ""
  if (toplevel.wayland && toplevel.wayland.appId) return String(toplevel.wayland.appId)
  var ipc = toplevel.lastIpcObject
  if (ipc && ipc["class"]) return String(ipc["class"])
  return ""
}

function title(toplevel) {
  if (!toplevel) return ""
  if (toplevel.title) return String(toplevel.title)
  if (toplevel.wayland && toplevel.wayland.title) return String(toplevel.wayland.title)
  return ""
}

function pid(toplevel) {
  var ipc = toplevel ? toplevel.lastIpcObject : null
  return ipc && ipc.pid ? Number(ipc.pid) : -1
}

function workspaceId(toplevel) {
  return toplevel && toplevel.workspace ? toplevel.workspace.id : -1
}

// Window position from Hyprland's last IPC snapshot, or null if unknown.
function position(toplevel) {
  var ipc = toplevel ? toplevel.lastIpcObject : null
  var at = ipc ? ipc.at : null
  return at && at.length === 2 ? at : null
}

// Toplevels in on-screen order: left to right, then top to bottom
// (top to bottom first on a vertical bar). Unknown positions go last.
function sortByPosition(toplevels, vertical) {
  var list = toplevels.map(function(toplevel, index) {
    return { toplevel: toplevel, index: index, at: position(toplevel) }
  })
  var primary = vertical ? 1 : 0
  var secondary = 1 - primary

  list.sort(function(a, b) {
    if (!a.at || !b.at) return (a.at ? -1 : b.at ? 1 : 0) || a.index - b.index
    return (a.at[primary] - b.at[primary]) || (a.at[secondary] - b.at[secondary]) || (a.index - b.index)
  })
  return list.map(function(entry) { return entry.toplevel })
}

function sameAddress(left, right) {
  return String(left || "").replace(/^0x/, "") === String(right || "").replace(/^0x/, "")
}
