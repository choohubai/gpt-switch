#!/bin/zsh
set -euo pipefail

SOURCE_DIR="$(cd "$(dirname "$0")" && pwd)"

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
"$NODE" --test "$SOURCE_DIR"/tests/*.test.mjs
/bin/zsh "$SOURCE_DIR/swiftc.sh" -parse-as-library -target "$(uname -m)-apple-macosx13.0" -typecheck "$SOURCE_DIR/StatusMenu.swift"
/bin/zsh -n "$SOURCE_DIR/GPTSwitch"
/bin/zsh -n "$SOURCE_DIR/build.sh"
/bin/zsh -n "$SOURCE_DIR/swiftc.sh"
/bin/bash -n "$SOURCE_DIR/local-release.sh"
/usr/bin/plutil -lint "$SOURCE_DIR/Info.plist"

print -- "源码检查通过。"
