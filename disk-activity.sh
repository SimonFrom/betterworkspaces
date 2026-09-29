#!/bin/bash
# Usage: disk-activity.sh <window pid>...
#
# Prints "<window pid> <disk bytes> <net bytes>" for each pid, totalled over
# the window's whole app:
#   disk - bytes written to disk (/proc/<pid>/io write_bytes)
#   net  - bytes received on the app's open non-loopback TCP sockets (ss).
#          Sockets come and go, so this can drop between samples.
# The app is the topmost ancestor below the session (systemd, Hyprland), so
# helper processes count too: Steam's window belongs to steamwebhelper, but
# its parent `steam` does the downloading. BetterWorkspaces diffs successive
# samples into rates; disk + network together means a download.
#
# The bar runs this every 1.5 seconds, so every producer is bounded:
#   - ps and ss each get PRODUCER_TIMEOUT seconds; a stalled one is killed and
#     its partial output used.
#   - ss output is cut at MAX_SS_BYTES. A cut only undercounts network bytes,
#     which at worst labels a download "Running".
#   - This script's own output is cut at MAX_OUTPUT_BYTES. It is one short
#     line per window pid, far below the cap.
# BetterWorkspaces also runs the whole script under its own `timeout`.

PRODUCER_TIMEOUT=1
MAX_SS_BYTES=$((4 * 1024 * 1024))
MAX_OUTPUT_BYTES=$((64 * 1024))

timeout -k 0.5 "$PRODUCER_TIMEOUT" ps -e -o pid=,ppid=,comm= 2>/dev/null |
awk -v roots="$*" -v producerTimeout="$PRODUCER_TIMEOUT" -v maxSsBytes="$MAX_SS_BYTES" '
  { parent[$1] = $2; comm[$1] = $3 }

  function session(p) {
    return p <= 1 || comm[p] == "systemd" || comm[p] == "Hyprland" || comm[p] == "start-hyprland" || comm[p] ~ /^uwsm/
  }

  function appRoot(p) {
    while ((p in parent) && !session(parent[p])) p = parent[p]
    return p
  }

  function owner(p,  q) {
    q = p
    while ((q in parent) && !(q in isApp) && q > 1) q = parent[q]
    return (q in isApp) ? q : ""
  }

  END {
    n = split(roots, r, " ")
    for (i = 1; i <= n; i++) {
      rootOf[r[i]] = appRoot(r[i])
      isApp[rootOf[r[i]]] = 1
    }

    for (p in parent) {
      q = owner(p)
      if (q == "") continue
      f = "/proc/" p "/io"
      while ((getline line < f) > 0) {
        if (line ~ /^write_bytes:/) { split(line, a, " "); disk[q] += a[2] }
      }
      close(f)
    }

    # ss prints each socket line, then an indented line of tcp_info.
    cmd = "timeout -k 0.5 " producerTimeout " ss -tinpH 2>/dev/null | head -c " maxSsBytes
    sockPid = ""
    while ((cmd | getline line) > 0) {
      if (line !~ /^[ \t]/) {
        sockPid = ""
        if (line ~ /127\.0\.0\.1|\[::1\]/) continue
        if (match(line, /pid=[0-9]+/)) sockPid = substr(line, RSTART + 4, RLENGTH - 4)
      } else if (sockPid != "" && match(line, /bytes_received:[0-9]+/)) {
        q = owner(sockPid)
        if (q != "") net[q] += substr(line, RSTART + 15, RLENGTH - 15)
        sockPid = ""
      }
    }
    close(cmd)

    for (i = 1; i <= n; i++) print r[i], disk[rootOf[r[i]]] + 0, net[rootOf[r[i]]] + 0
  }' | head -c "$MAX_OUTPUT_BYTES"
