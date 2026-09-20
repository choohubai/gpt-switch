#!/bin/zsh
# 在 macOS 上打 Windows 安装包：NSIS 的 makensis 是跨平台编译器（brew install makensis）。
# 产物：$OUTPUT_DIR/GPT-Switch-Setup-<version>.exe 和同名 .sha256
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SOURCE_DIR="$ROOT_DIR/Sources"
RESOURCE_DIR="$ROOT_DIR/Resources"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT_DIR/dist}"
NODE_VERSION="${GPT_SWITCH_NODE_VERSION:-v24.21.0}"
NODE_CACHE="${GPT_SWITCH_NODE_CACHE:-$HOME/.cache/gpt-switch/windows}"
VERSION="${1:-}"

if [[ -z "$VERSION" ]]; then
  print -u2 -- "用法：Scripts/package-windows.sh <version>"
  exit 2
fi

for command in makensis curl unzip sips shasum; do
  command -v "$command" >/dev/null 2>&1 || {
    print -u2 -- "未找到命令：$command"
    [[ "$command" == "makensis" ]] && print -u2 -- "安装：brew install makensis"
    exit 1
  }
done

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/gpt-switch-windows.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT
PAYLOAD="$WORK_DIR/payload"
mkdir -p "$PAYLOAD" "$NODE_CACHE" "$OUTPUT_DIR"

# 只取 node.exe 单文件运行时，不把整个 node 目录塞进安装包。
ARCHIVE="$NODE_CACHE/node-$NODE_VERSION-win-x64.zip"
if [[ ! -f "$ARCHIVE" ]]; then
  print -- "下载 Node.js $NODE_VERSION（win-x64）"
  curl -fsSL -o "$ARCHIVE.tmp" "https://nodejs.org/dist/$NODE_VERSION/node-$NODE_VERSION-win-x64.zip"
  mv "$ARCHIVE.tmp" "$ARCHIVE"
fi
unzip -o -j "$ARCHIVE" "node-$NODE_VERSION-win-x64/node.exe" -d "$PAYLOAD" >/dev/null

cp "$SOURCE_DIR/injector.mjs" "$SOURCE_DIR/injection.js" "$SOURCE_DIR/model-config.mjs" "$PAYLOAD/"
cp "$RESOURCE_DIR/models.json" "$PAYLOAD/"

cat > "$PAYLOAD/GPT Switch.cmd" <<'LAUNCHER'
@echo off
setlocal
cd /d "%~dp0"
"%~dp0node.exe" "%~dp0injector.mjs" %*
LAUNCHER

ICON="$WORK_DIR/AppIcon.ico"
# sips 写 ico 要求先降到 256，直接转 1024 的图会报 Error 13。
sips -z 256 256 "$RESOURCE_DIR/AppIcon.png" --out "$WORK_DIR/AppIcon-256.png" >/dev/null
sips -s format ico "$WORK_DIR/AppIcon-256.png" --out "$ICON" >/dev/null
cp "$ICON" "$PAYLOAD/AppIcon.ico"

OUTFILE="$OUTPUT_DIR/GPT-Switch-Setup-$VERSION.exe"
makensis -V2 \
  -DAPP_VERSION="$VERSION" \
  -DPAYLOAD="$PAYLOAD" \
  -DOUTFILE="$OUTFILE" \
  -DICON="$ICON" \
  "$SCRIPT_DIR/windows-installer.nsi"

EXE_SHA="$(shasum -a 256 "$OUTFILE" | awk '{print $1}')"
printf '%s  %s\n' "$EXE_SHA" "$(basename "$OUTFILE")" > "$OUTFILE.sha256"
print -r -- "$OUTFILE"
