# Changelog

## 0.3.20

- Configurable completion sound (Glass / Ping / Tink / Submarine / none)
- "Snooze 30 minutes" for meetings
- Option+Command+A opens the panel from anywhere (Carbon hotkey, no accessibility permission)
- Nothing pops up or rings while the screen is locked; sessions still land in the list
- Added CHANGELOG and an issue template

## 0.3.19

- Completion pills queue instead of overwriting each other when several sessions finish together
- Pills are clickable and jump back to that session (the panel now accepts the first mouse click)
- Settings gained "try a reminder", which pops two samples so you can check the sound and the pill
- Settings gained Diagnostics: per agent, whether its data is readable, copyable in one click
- `--diagnose` prints the same summary from the command line
- Install output now leads with the self-check and warns that Claude Code needs a new session
- English README

## 0.3.18

- Antigravity support
- "Time to rest" empty state
- Configurable data directories; hardcoded paths removed

## 0.3.17

- Session titles in the list (Codex from its state database, DSH from its cache)
- Remote SSH support: tails remote logs incrementally, the script arrives over stdin and never touches disk
