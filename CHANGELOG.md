# Changelog

## 1.1.1

- The background probes the bar runs every 1.5 seconds now have a deadline and an output cap. `disk-activity.sh` gives `ps` and `ss` one second each, stops reading `ss` after 4 MiB, and caps its own output at 64 KiB. The herdr snapshot is capped at 1 MiB. Both probes are killed if they run longer than 3 seconds. Before this, a stalled or very chatty `ss` could keep a probe running and its output growing without limit.

## 1.1.0

- The workspace border circles while something there is running: downloads, heavy disk activity, herdr agents, and apps showing a spinner in their title.
- A red dot marks workspaces where something finished or wants attention: notifications, urgent windows, finished downloads and spinners, and herdr agents that are done or need input. It clears when you visit.
- The hover tooltip shows the current activity, like "Downloading · 50 MB/s" or "1 agent running".
- New Activity section in the settings menu, and a `badgeColor` option in `shell.json`.
- Omarchy web apps (Discord, and others launched with `omarchy-launch-webapp`) show their own icon instead of the generic one.

## 1.0.0

- First release: app icons per workspace, accent border on the active workspace, hover titles, and a settings menu for icon size, padding, unused workspaces, workspace count and position.
