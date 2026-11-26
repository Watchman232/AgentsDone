#!/bin/bash
# AgentsDone 卸载脚本：移除 App、采集端、登录项，并从 Claude Code 设置里摘掉 hook
set -euo pipefail

APP_NAME="AgentsDone"
PREFIX="${PREFIX:-$HOME/Applications}"
BUNDLE="$PREFIX/$APP_NAME.app"
HOOK_DIR="${AGENTSDONE_HOME:-$HOME/.agentsdone}"
PLIST="$HOME/Library/LaunchAgents/dev.agentsdone.app.plist"

say() { printf "\033[1m▸ %s\033[0m\n" "$*"; }

say "退出 App"
launchctl bootout "gui/$UID/dev.agentsdone.app" 2>/dev/null || true
pkill -f "$BUNDLE/Contents/MacOS/$APP_NAME" 2>/dev/null || true
rm -f "$PLIST"

say "清理远端 hooks（若在设置页装过）"
if [ -x "$HOOK_DIR/agentsdone-hook" ]; then
  "$HOOK_DIR/agentsdone-hook" --remove-remote >/dev/null 2>&1 || true
fi

say "清理 Claude Code hooks"
if [ -x "$HOOK_DIR/agentsdone-hook" ]; then
    "$HOOK_DIR/agentsdone-hook" --remove-hooks || true
else
    echo "    采集端已不在，跳过（如仍有残留，可在 ~/.claude/settings.json 里搜 agentsdone-hook 手动删）"
fi

say "移除 App 与采集端"
rm -rf "$BUNDLE"
rm -rf "$HOOK_DIR"

say "卸载完成"
