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
/usr/bin/plutil -lint "$RESOURCE_DIR/Info.plist"

print -- "源码检查通过。"
