#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SOURCE_DIR="$ROOT_DIR/Sources"
RESOURCE_DIR="$ROOT_DIR/Resources"

if command -v node >/dev/null 2>&1; then
  NODE="$(command -v node)"
elif [[ -x "/Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node" ]]; then
  NODE="/Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node"
elif [[ -x "/Applications/Codex.app/Contents/Resources/cua_node/bin/node" ]]; then
  NODE="/Applications/Codex.app/Contents/Resources/cua_node/bin/node"
else
  print -u2 -- "未找到 Node.js，无法检查 JavaScript。"
  exit 1
fi

"$NODE" --check "$SOURCE_DIR/injector.mjs"
"$NODE" --check "$SOURCE_DIR/injection.js"
"$NODE" --test "$ROOT_DIR"/tests/*.test.mjs
/bin/zsh "$SCRIPT_DIR/swiftc.sh" -parse-as-library -target "$(uname -m)-apple-macosx13.0" -typecheck "$SOURCE_DIR/StatusMenu.swift"
/bin/zsh -n "$SCRIPT_DIR/GPTSwitch"
/bin/zsh -n "$SCRIPT_DIR/build.sh"
/bin/zsh -n "$SCRIPT_DIR/swiftc.sh"
/bin/bash -n "$SCRIPT_DIR/local-release.sh"
/bin/zsh -n "$SCRIPT_DIR/package-windows.sh"
/usr/bin/plutil -lint "$RESOURCE_DIR/Info.plist"

# Windows 安装包的载荷：面板、启动器和打包脚本都要在。
WINDOWS_PAYLOADS=("$SOURCE_DIR/StatusMenu.ps1" "$SCRIPT_DIR/GPTSwitch.ps1" "$SCRIPT_DIR/package-windows.sh" "$SCRIPT_DIR/windows-installer.nsi")
for payload in "${WINDOWS_PAYLOADS[@]}"; do
  if [[ ! -f "$payload" ]]; then
    print -u2 -- "缺少 Windows 打包文件：$payload"
    exit 1
  fi
done

# 面板显示的版本来自 injector.mjs，必须和 Info.plist 一致。
INJECTOR_VERSION="$(tr -d '\r' < "$SOURCE_DIR/injector.mjs" | sed -n 's/^const VERSION = "\(.*\)";$/\1/p')"
PLIST_VERSION="$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$RESOURCE_DIR/Info.plist")"
if [[ "$INJECTOR_VERSION" != "$PLIST_VERSION" ]]; then
  print -u2 -- "injector.mjs 版本 ${INJECTOR_VERSION} 与 Info.plist 版本 ${PLIST_VERSION} 不一致"
  exit 1
fi

print -- "源码检查通过。"
