# AgentsDone

**English** · [中文](README.zh-CN.md)

A very small macOS menu bar app: **when you have several AI coding agents running at once, see at a glance which one finished and which one is waiting for you.**

No window switching, no per-tool setup.

<img src="docs/panel.png" width="340" alt="Menu bar panel">

## What it supports

| Agent | How the state is detected | Setup needed |
|---|---|---|
| **Claude Code** | 6 hooks (Stop / Notification / PermissionRequest / SessionStart / PostToolUse / SessionEnd) | merged by the installer |
| **Codex** (CLI / VS Code extension / desktop) | reads session logs under `~/.codex` | none |
| **DeepSeek Harness** | reads session cache and logs under `~/.dsh` | none |
| **ZCode** | reads the task index under `~/.zcode` | none |
| **Antigravity** | reads the session database under `~/.gemini/antigravity` | none |

Three states:

- **Finished** — it's done: one chime plus a pill at the top of the screen
- **Needs you** — it's waiting for approval, waiting for your reply, or the task errored
- **Running** — still working, listed quietly below

Click a row to jump back to that app (VS Code / iTerm / Terminal / Codex / Harness / ZCode / Antigravity) and clear it.
The pill is clickable too. When several sessions finish at once the pills queue up instead of overwriting each other.

<img src="docs/pill.png" width="320" alt="Completion pill">

With nothing running:

<img src="docs/empty.png" width="340" alt="Empty state">

## Install

| | Requirement |
|---|---|
| OS | macOS 12 Monterey or newer |
| CPU | Apple Silicon or Intel (universal binary) |
| Dependencies | **None.** No Xcode, python, Homebrew or Node |
| Permissions | No accessibility access, no notification permission |
| Disk / RAM | ~2.5 MB / ~37 MB resident |

**Option 1: download** (no terminal needed)

Grab `AgentsDone-<version>.zip` from [Releases](https://github.com/Watchman232/AgentsDone/releases/latest),
unzip it and drag `AgentsDone.app` into Applications. The first launch needs **right-click → Open**;
on macOS 15 and later that shortcut is gone, so use System Settings → Privacy & Security → "Open Anyway"
(the app is not notarized by Apple).
This is enough for Codex / DeepSeek Harness / ZCode / Antigravity.

**Option 2: script install** (recommended — also covers Claude Code)

Claude Code's completion and approval events are only reachable through hooks, so the script is needed for those:

```bash
git clone https://github.com/Watchman232/AgentsDone.git
cd AgentsDone
./install.sh
```

No git? Use **Code → Download ZIP** on the repository page, then run `./install.sh` inside the folder
(the script clears the quarantine flag itself).

After installing, click the 🔔 → Settings → **Try a reminder** (top right). Two sample reminders pop up so you can
confirm the sound and the pill work.

The installer creates: the 🔔 in the menu bar, `~/Applications/AgentsDone.app`, `~/.agentsdone/` (the collector),
and a login item (`~/Library/LaunchAgents/dev.agentsdone.app.plist`, relaunched automatically if it ever exits).

It only does four things: install the app → install the collector → merge hooks into `~/.claude/settings.json`
(backed up first, your other hooks are kept) → register the login item.
**Nothing is downloaded and nothing is installed over the network.**

Uninstall: `./uninstall.sh`

## Day to day

- Click the 🔔 to open the list, click a row to jump back — or press **Option+Command+A** from anywhere
- The menu has **Mute** (no sound), **Clear** and **Quit**
- Settings lets you pick the sound, snooze for 30 minutes, turn off "follow the current VS Code remote",
  add remote hosts and see the data paths
- While the screen is locked nothing pops up and nothing rings; sessions still land in the list

### Is it fully offline?

Yes. No telemetry, no model APIs, no HTTP requests anywhere in the code. Everything comes from local files,
and Claude's events travel over a unix socket (`/tmp/agentsdone-<uid>.sock`, mode 0600). No TCP port is opened.

The only network activity is the **optional** remote cluster feature: it only runs `ssh` to a host you tick in
Settings. Leave it alone and the app never touches the network.

## Remote clusters (optional)

When you run Codex/Claude over VS Code Remote-SSH or straight on a dev box, this Mac can still get those
completion reminders:

Menu bar → Settings → tick a host → **Install Claude hooks**.
It only tails new bytes of the remote session logs (a few hundred bytes per turn), downloads nothing, and the
script is fed through ssh stdin without ever being written to disk.

<img src="docs/settings.png" width="480" alt="Settings">

## Configuration (usually none)

All five agents are read from their default locations. If you moved a data directory (external disk, portable
install, custom `CODEX_HOME`), edit `~/.agentsdone/config.json` (Settings has an "open config file" button):

```json
{
  "paths": { "codex": "~/codex-home", "dsh": "/Volumes/Data/dsh" },
  "hosts": [{ "host": "gpu-box", "enabled": true,
              "paths": { "codex": "~/work/.codex" } }]
}
```

- `~` is expanded; anything you leave out keeps its default. Changes apply within 3 seconds, no restart
- A wrong path is not an error — that agent simply doesn't show up
- To see what is actually being read: `~/Applications/AgentsDone.app/Contents/MacOS/AgentsDone --paths`

DeepSeek Harness approval reminders need DSH's own bundled runtime to decompress its zstd logs. It is found
automatically when DSH lives in `/Applications` or `~/Applications`; set `dshNode` if it lives elsewhere
(only this one reminder is affected).

<details>
<summary>Environment variables (for testing / multiple instances)</summary>

`AGENTSDONE_CONFIG_DIR` · `AGENTSDONE_HOME` · `AGENTSDONE_SOCK` · `PREFIX` (install location)
· `AGENTSDONE_CLAUDE_ROOT` · `CODEX_HOME` / `AGENTSDONE_CODEX_ROOT` · `AGENTSDONE_DSH_HOME` /
`AGENTSDONE_DSH_ROOT` / `AGENTSDONE_DSH_LOGS` / `AGENTSDONE_DSH_NODE` · `AGENTSDONE_ZCODE_ROOT`
· `AGENTSDONE_ANTIGRAVITY_ROOT` · `AGENTSDONE_REMOTE=0` (disable remote) · `AGENTSDONE_NO_LAUNCH=1`
· `AGENTSDONE_SNOOZE_MINUTES=5` (start muted, for testing)

</details>

## When something doesn't show up

Click the 🔔 → Settings → **Diagnostics** next to "Data directories" to see whether each agent's data is readable:

<img src="docs/diag.png" width="420" alt="Diagnostics">

"Copy diagnostics" puts a summary on the clipboard you can paste into an issue. From a terminal:

```bash
~/Applications/AgentsDone.app/Contents/MacOS/AgentsDone --diagnose
```

## Notes

- Hooks always `exit 0` on error, so they can never block Claude Code or Codex
- Your `~/.codex/config.toml` is never modified; an existing `codex notify` setting is left untouched
- After installing, **start a new** Claude Code session so it picks up the hooks
- The whole app is two Swift files (`AgentsDone.swift`, `bin/agentsdone-hook.swift`) with no third-party
  dependencies; run `./build.sh` to regenerate `vendor/` after editing

## License

MIT, see [LICENSE](LICENSE).
