#!/bin/bash
# 构建 Universal（arm64 + x86_64）二进制，产物放 vendor/，供无 Xcode 的机器直接使用
set -euo pipefail
cd "$(dirname "$0")"

BUILD=build
VENDOR=vendor
mkdir -p "$BUILD/mcache" "$VENDOR"

swiftc_bin="$(command -v swiftc || true)"
if [ -z "$swiftc_bin" ]; then
    echo "需要 Xcode Command Line Tools 才能构建（普通用户安装不需要）"; exit 1
fi

pick_sdk() {
    local sdk
    candidates=()
    candidates+=("$(xcrun --show-sdk-path 2>/dev/null || true)")
    while IFS= read -r sdk; do candidates+=("$sdk"); done < <(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX*.sdk 2>/dev/null | sort -Vr)
    for sdk in "${candidates[@]}"; do
        [ -d "$sdk" ] || continue
        echo 'import Foundation' > "$BUILD/.sdkcheck.swift"
        if swiftc -module-cache-path "$BUILD/mcache" -sdk "$sdk" -typecheck "$BUILD/.sdkcheck.swift" >/dev/null 2>&1; then
            echo "$sdk"; return 0
        fi
    done
    return 1
}

SDK="$(pick_sdk)" || { echo "找不到可用 SDK"; exit 1; }
echo "SDK: $SDK"

build_one() {
    local src="$1" out="$2" extra="${3:-}"
    for arch in arm64 x86_64; do
        # shellcheck disable=SC2086
        swiftc -O $extra -target "${arch}-apple-macos12.0" \
            -module-cache-path "$BUILD/mcache" -sdk "$SDK" \
            "$src" -o "$BUILD/${out}-${arch}"
    done
    lipo -create "$BUILD/${out}-arm64" "$BUILD/${out}-x86_64" -output "$VENDOR/${out}"
    lipo -info "$VENDOR/${out}"
}

echo "构建 AgentDone"
build_one AgentDone.swift AgentDone "-parse-as-library"
echo "构建 agentdone-hook"
build_one bin/agentdone-hook.swift agentdone-hook

rm -rf "$BUILD/mcache"
echo "完成 -> vendor/"
