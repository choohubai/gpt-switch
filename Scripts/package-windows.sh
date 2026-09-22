#!/bin/zsh
# 在 macOS 上打 Windows 安装包：NSIS 的 makensis 是跨平台编译器（brew install makensis）。
# 安装包只放脚本、面板和图标，运行时用客户端自带的 node，不打包 node.exe。
# 产物：$OUTPUT_DIR/GPT-Switch-Setup-<version>.exe 和同名 .sha256
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SOURCE_DIR="$ROOT_DIR/Sources"
RESOURCE_DIR="$ROOT_DIR/Resources"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT_DIR/dist}"
VERSION="${1:-}"

if [[ -z "$VERSION" ]]; then
  print -u2 -- "用法：Scripts/package-windows.sh <version>"
  exit 2
fi

for command in makensis sips shasum; do
  command -v "$command" >/dev/null 2>&1 || {
    print -u2 -- "未找到命令：$command"
    [[ "$command" == "makensis" ]] && print -u2 -- "安装：brew install makensis"
    exit 1
  }
done

# 面板显示的版本来自 injector.mjs，必须和发布版本一致。
INJECTOR_VERSION="$(tr -d '\r' < "$SOURCE_DIR/injector.mjs" | sed -n 's/^const VERSION = "\(.*\)";$/\1/p')"
[[ "$INJECTOR_VERSION" == "$VERSION" ]] || {
  print -u2 -- "injector.mjs 版本为 ${INJECTOR_VERSION}，传入版本为 $VERSION"
  exit 1
}

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/gpt-switch-windows.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT
PAYLOAD="$WORK_DIR/payload"
mkdir -p "$PAYLOAD" "$OUTPUT_DIR"

cp "$SOURCE_DIR/injector.mjs" "$SOURCE_DIR/injection.js" "$SOURCE_DIR/model-config.mjs" \
   "$SOURCE_DIR/StatusMenu.ps1" "$PAYLOAD/"
cp "$SCRIPT_DIR/GPTSwitch.ps1" "$PAYLOAD/GPT Switch.ps1"
cp "$RESOURCE_DIR/models.json" "$PAYLOAD/"

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