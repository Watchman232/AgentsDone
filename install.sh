#!/bin/bash
# AgentsDone 安装脚本
# 有 vendor/ 预编译二进制时：零依赖，任何 macOS 12+ 机器可直接安装
# 没有时：用本机 Xcode Command Line Tools 现场编译
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="AgentsDone"
PREFIX="${PREFIX:-$HOME/Applications}"
HOOK_DIR="${AGENTSDONE_HOME:-$HOME/.agentsdone}"
BUILD="$ROOT/build"
BUNDLE="$PREFIX/$APP_NAME.app"

say() { printf "\033[1m▸ %s\033[0m\n" "$*"; }
die() { printf "\033[1;31m✗ %s\033[0m\n" "$*"; exit 1; }

# ---------- 0. 系统版本 ----------
OS_MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
[ "${OS_MAJOR:-0}" -ge 12 ] || die "需要 macOS 12 或更高（当前 $(sw_vers -productVersion)）"

mkdir -p "$BUILD" "$PREFIX" "$HOOK_DIR"

# ---------- 1. 取得二进制：优先预编译 ----------
BIN_APP=""
BIN_HOOK=""
if [ -x "$ROOT/vendor/$APP_NAME" ] && [ -x "$ROOT/vendor/agentsdone-hook" ]; then
    say "使用预编译二进制（无需 Xcode）"
    BIN_APP="$ROOT/vendor/$APP_NAME"
    BIN_HOOK="$ROOT/vendor/agentsdone-hook"
    lipo -info "$BIN_APP" 2>/dev/null | sed 's/^/    /' || true
else
    say "未找到预编译二进制，开始本地编译"
    command -v swiftc >/dev/null 2>&1 || die "需要 Xcode Command Line Tools（xcode-select --install），或把 vendor/ 目录一起拷贝过来"
    SDK=""
    while IFS= read -r sdk; do
        [ -d "$sdk" ] || continue
        echo 'import Foundation' > "$BUILD/.sdkcheck.swift"
        if swiftc -module-cache-path "$BUILD/mcache" -sdk "$sdk" -typecheck "$BUILD/.sdkcheck.swift" >/dev/null 2>&1; then
            SDK="$sdk"; break
        fi
    done < <(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX*.sdk 2>/dev/null | sort -Vr)
    [ -n "$SDK" ] || die "找不到可用的 macOS SDK"
    echo "    SDK: $SDK"
    swiftc -O -parse-as-library -target "$(uname -m)-apple-macos12.0" \
        -module-cache-path "$BUILD/mcache" -sdk "$SDK" \
        "$ROOT/AgentsDone.swift" -o "$BUILD/$APP_NAME"
    swiftc -O -target "$(uname -m)-apple-macos12.0" \
        -module-cache-path "$BUILD/mcache" -sdk "$SDK" \
        "$ROOT/bin/agentsdone-hook.swift" -o "$BUILD/agentsdone-hook"
    rm -rf "$BUILD/mcache"
    BIN_APP="$BUILD/$APP_NAME"
    BIN_HOOK="$BUILD/agentsdone-hook"
fi

# ---------- 2. 打包 App ----------
say "安装 App 到 $BUNDLE"
rm -rf "$BUILD/$APP_NAME.app"
mkdir -p "$BUILD/$APP_NAME.app/Contents/MacOS" "$BUILD/$APP_NAME.app/Contents/Resources"
cp "$BIN_APP" "$BUILD/$APP_NAME.app/Contents/MacOS/$APP_NAME"
chmod +x "$BUILD/$APP_NAME.app/Contents/MacOS/$APP_NAME"
cat > "$BUILD/$APP_NAME.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>AgentsDone</string>
    <key>CFBundleDisplayName</key><string>AgentsDone</string>
    <key>CFBundleIdentifier</key><string>dev.agentsdone.app</string>
    <key>CFBundleExecutable</key><string>AgentsDone</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.3.18</string>
    <key>CFBundleVersion</key><string>2</string>
    <key>LSMinimumSystemVersion</key><string>12.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - "$BUILD/$APP_NAME.app" >/dev/null 2>&1 || true
# 去掉「从网上下载」标记，避免“已损坏/无法验证开发者”
xattr -cr "$BUILD/$APP_NAME.app" 2>/dev/null || true

# 停掉任何在跑的旧实例（可能是你手动 ./build/AgentsDone 起的）
pkill -x "$APP_NAME" 2>/dev/null || true
pkill -f "$APP_NAME.app/Contents/MacOS/$APP_NAME" 2>/dev/null || true
sleep 0.3
rm -rf "$BUNDLE"
cp -R "$BUILD/$APP_NAME.app" "$BUNDLE"
xattr -cr "$BUNDLE" 2>/dev/null || true
codesign --force --sign - "$BUNDLE" >/dev/null 2>&1 || true

# ---------- 3. 安装采集端 ----------
say "安装采集端到 $HOOK_DIR/agentsdone-hook"
cp "$BIN_HOOK" "$HOOK_DIR/agentsdone-hook"
chmod +x "$HOOK_DIR/agentsdone-hook"
xattr -cr "$HOOK_DIR/agentsdone-hook" 2>/dev/null || true

# 远端（VS Code Remote / devspace）用的脚本：只放在本机，装不装由设置页决定
mkdir -p "$HOOK_DIR/remote"
cp "$ROOT/remote/"*.py "$HOOK_DIR/remote/" 2>/dev/null || true
say "远端支持脚本就位（$HOOK_DIR/remote）"

# ---------- 4. 合并 Claude Code hooks ----------
say "配置 Claude Code hooks"
"$HOOK_DIR/agentsdone-hook" --install-hooks || die "写入 Claude Code hooks 失败（见上面的提示）"

# ---------- 5. 登录自启 ----------
say "注册登录自启"
PLIST="$HOME/Library/LaunchAgents/dev.agentsdone.app.plist"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>dev.agentsdone.app</string>
    <key>ProgramArguments</key>
    <array><string>$BUNDLE/Contents/MacOS/AgentsDone</string></array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key>
    <dict><key>SuccessfulExit</key><false/></dict>
    <key>ThrottleInterval</key><integer>10</integer>
    <key>ProcessType</key><string>Interactive</string>
    <key>LimitLoadToSessionType</key><string>Aqua</string>
</dict>
</plist>
PLIST
plutil -lint "$PLIST" >/dev/null || die "LaunchAgent plist 不合法"

if [ "${AGENTSDONE_NO_LAUNCH:-0}" != "1" ]; then
    launchctl bootout "gui/$UID/dev.agentsdone.app" 2>/dev/null || true
    launchctl bootstrap "gui/$UID" "$PLIST" 2>/dev/null || launchctl load -w "$PLIST" 2>/dev/null || true
    sleep 0.5
    open "$BUNDLE" 2>/dev/null || true
fi

say "完成"
cat <<TIP

  菜单栏右上角现在应该有一个 🔔。

  · 点 🔔：查看哪些会话完成了 / 在等你
  · 点某一行：跳回那个 App，并从列表移除
  · 远程集群：菜单栏 → 设置 → 勾选主机 → 安装 Claude hooks
  · 先试试：$HOOK_DIR/agentsdone-hook demo
  · 查看状态：$HOOK_DIR/agentsdone-hook --status
  · 卸载：./uninstall.sh

  Claude Code：新开一个会话才会读到新 hooks
  Codex（CLI / VS Code 扩展 / 桌面 App）：无需任何配置
TIP
