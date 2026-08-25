# Synara Status

A native Omarchy Quattro bar widget that shows the current status of [Synara](https://www.trysynara.com/), the local-first desktop control plane for coding agents.

The widget stays on your machine. It reads Synara’s local data directory (runtime file, provider-status JSON, and SQLite projections) and never sends that state anywhere else.

**Screenshots** (capture after install with `omarchy capture screenshot`):

- Bar: idle gray mark, green pulse while agents run, amber during handoffs, red on errors
- Panel: hero, summary cards, task list, Open Synara / Refresh footer

## Install

```sh
omarchy plugin add https://github.com/xFurti/omarchy-synara-status.git --enable
```

That clones the plugin, validates the manifest, and places it on the right side of the bar. Plugins run unsandboxed inside `omarchy-shell`; only add repositories you are willing to run.

To add it first and enable later:

```sh
omarchy plugin add https://github.com/xFurti/omarchy-synara-status.git
omarchy plugin enable io.github.xfurti.synara-status --section right
```

Requires **Python 3** on `PATH` (stdlib only) so the local scanner can read Synara’s SQLite projection. The widget still loads without Synara installed; it just reports that nothing was found.

## Features

- Compact bar mark with idle / active / handoff / error colors
- Animated pulse while agents are running
- Tooltip summary such as `3 active agents · 2 worktrees`
- Left click opens the panel, right click refreshes, middle click launches Synara
- Panel header with last refresh time
- Summary cards for active agents, worktrees, handoffs, and recent tasks
- Scrollable task list with provider, status, and worktree / branch
- Quick actions: Focus (raises the Synara window), Open Diff (opens the worktree), Stop (stub until Synara exposes a control API)
- Keyboard: Escape closes, Tab cycles neighboring bar panels, `R` refreshes, `O` opens Synara, `J`/`K` move the task cursor

## Configuration

```sh
omarchy bar set io.github.xfurti.synara-status showLabel true --json
omarchy bar set io.github.xfurti.synara-status refreshIntervalSec 10 --json
omarchy bar move io.github.xfurti.synara-status --section right
```

| Key | Default | What it does |
|---|---|---|
| `showLabel` | `false` | Show `Idle` / `Active` / `Handoff` / `Error` next to the icon |
| `refreshIntervalSec` | `15` | How often the local scanner re-runs |
| `dataDir` | `""` | Synara home override. Empty uses `$SYNARA_HOME`, then `~/.synara`, then `~/.synara-canary` |
| `statusEndpoint` | `""` | Optional HTTP status URL tried after filesystem detection |
| `launchCommand` | `gtk-launch synara` | Command used by Open Synara |

Environment variables, if you prefer not to write paths into `shell.json`:

| Variable | Purpose |
|---|---|
| `SYNARA_HOME` | Synara data directory (same variable Synara itself uses) |
| `SYNARA_STATUS_HOME` | Plugin-specific override, wins over `SYNARA_HOME` |
| `SYNARA_STATUS_ENDPOINT` | Optional HTTP status URL |

No absolute paths are hardcoded. `~`, `$HOME`, and `$SYNARA_HOME` expansions are supported.

## How it reads status

1. Resolve the Synara home directory from settings / environment / well-known locations
2. Treat Synara as installed when `userdata/` (or `dev/`) exists
3. Read `userdata/server-runtime.json` and check whether its PID is alive
4. Read `userdata/provider-status/*.json` for Claude, Codex, Cursor, Grok, and the other runtimes
5. Query `userdata/state.sqlite` in immutable read-only mode for threads, worktrees, and handoffs
6. Optionally `GET` a configured status endpoint (or `<origin>/health` while Synara is running)

MCP tokens and other secrets in the runtime file are discarded before anything reaches QML.

## Develop

Clone a working copy into the user plugin directory, or edit this repository and add it with `omarchy plugin add`.

```sh
omarchy plugin validate .
qmllint -I "$OMARCHY_PATH/shell" BarWidget.qml Panel.qml Model.qml
python3 scripts/scan.py
```

Saving files under `~/.config/omarchy/plugins/` hot-reloads the shell. Force a rescan with:

```sh
omarchy-shell shell rescanPlugins
```

Open and close the panel:

```sh
omarchy-shell shell summon io.github.xfurti.synara-status '{}'
omarchy-shell shell hide io.github.xfurti.synara-status
```

## Next steps for the data source

The QML binds to a single snapshot object from `Model.qml`. Replacing the scanner is enough to add a richer source:

1. **Local HTTP API** — when Synara publishes a stable `/api/status` (or similar), set `statusEndpoint` and extend `scripts/scan.py` to merge that payload
2. **External MCP** — Synara already exposes an Agent Gateway / external MCP surface; a future collector can call those tools instead of SQLite
3. **File watchers** — `FileView` already reloads when `server-runtime.json` changes; provider-status and SQLite can follow the same pattern
4. **Real Stop / Diff / Focus** — wire the stubs to Synara control routes once they exist; Focus already raises the Synara window through Hyprland

## Links

- [Omarchy shell plugins](https://omarchy.org/manual/shell-plugins/)
- [Plugin develop tutorial](https://omarchyplugins.com/develop.html)
- [Synara](https://www.trysynara.com/)
- [Synara docs](https://www.trysynara.com/docs)
- [Synara features](https://www.trysynara.com/docs/features/overview)
- [Synara on GitHub](https://github.com/Emanuele-web04/synara)

## Remove

```sh
omarchy plugin remove io.github.xfurti.synara-status
```

## License

MIT. See [LICENSE](LICENSE). The Synara mark is from the [official Synara repository](https://github.com/Emanuele-web04/synara/blob/main/assets/prod/logo.svg).
