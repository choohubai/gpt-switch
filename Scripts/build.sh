#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SOURCE_DIR="$ROOT_DIR/Sources"
RESOURCE_DIR="$ROOT_DIR/Resources"
# 本地打包不留中间产物：默认建个临时目录放 .app，脚本退出就删，只在下载目录留一个 dmg。
TEMP_OUTPUT_DIR=""
if [[ -z "${OUTPUT_DIR:-}" ]]; then
  TEMP_OUTPUT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/gpt-switch-build.XXXXXX")"
  OUTPUT_DIR="$TEMP_OUTPUT_DIR"
fi
APP="$OUTPUT_DIR/GPT Switch.app"
CONTENTS="$APP/Contents"
# dmg 放仓库的 dist/；中间产物（.app）留在临时目录，不进 dist。
# 本地测试用的 dmg 不带版本号：新包直接覆盖旧包，dist 里始终只有当前这一份（发布包的名字由 local-release.sh 定）。
DMG_DIR="${DMG_OUTPUT_DIR:-$ROOT_DIR/dist}"
DMG="$DMG_DIR/${DMG_NAME:-GPT-Switch-macOS.dmg}"
DMG_SOURCE="$(mktemp -d "${TMPDIR:-/tmp}/gpt-switch-dmg.XXXXXX")"
ICON_WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/gpt-switch.XXXXXX")"
ICONSET="$ICON_WORK_DIR/AppIcon.iconset"
MASTER_ICON="$ICON_WORK_DIR/AppIcon-1024.png"

cleanup() {
  rm -rf "$ICON_WORK_DIR" "$DMG_SOURCE"
  [[ -z "$TEMP_OUTPUT_DIR" ]] || rm -rf "$TEMP_OUTPUT_DIR"
  return 0
}
trap cleanup EXIT

is_app_running() {
  /bin/ps -axo pid=,args= | /usr/bin/awk -v app="$APP" -v self="$$" '
    $1 != self && index($0, app "/Contents/Resources/injector.mjs") { found = 1 }
    END { exit(found ? 0 : 1) }
  '
}

if [[ -d "$APP" ]] && is_app_running; then
  print -u2 -- "检测到正在运行的模型解锁器，请先退出插件后再构建。"
  exit 1
fi

# 临时目录每次都是新建的；显式给了 OUTPUT_DIR（发布流程）时只删自己产出的文件。
if [[ -z "$TEMP_OUTPUT_DIR" ]]; then
  rm -rf "$APP" "$DMG"
fi
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources" "$ICONSET" "$DMG_DIR"

cp "$RESOURCE_DIR/Info.plist" "$CONTENTS/Info.plist"
cp "$SCRIPT_DIR/GPTSwitch" "$CONTENTS/MacOS/GPTSwitch"
cp "$SOURCE_DIR/injector.mjs" "$CONTENTS/Resources/injector.mjs"
cp "$SOURCE_DIR/model-config.mjs" "$CONTENTS/Resources/model-config.mjs"
cp "$SOURCE_DIR/channel-config.mjs" "$CONTENTS/Resources/channel-config.mjs"
cp "$SOURCE_DIR/injection.js" "$CONTENTS/Resources/injection.js"
cp "$RESOURCE_DIR/MenuBarIcon.png" "$CONTENTS/Resources/MenuBarIcon.png"
/bin/zsh "$SCRIPT_DIR/swiftc.sh" -parse-as-library -O -target "$(uname -m)-apple-macosx13.0" -framework SwiftUI \
  "$SOURCE_DIR/StatusMenu.swift" \
  -o "$CONTENTS/Resources/GPTSwitchStatusMenu"
chmod 755 "$CONTENTS/MacOS/GPTSwitch"
chmod 755 "$CONTENTS/Resources/GPTSwitchStatusMenu"

cp "$RESOURCE_DIR/AppIcon.png" "$MASTER_ICON"

for spec in \
  "16 icon_16x16.png" \
  "32 icon_16x16@2x.png" \
  "32 icon_32x32.png" \
  "64 icon_32x32@2x.png" \
  "128 icon_128x128.png" \
  "256 icon_128x128@2x.png" \
  "256 icon_256x256.png" \
  "512 icon_256x256@2x.png" \
  "512 icon_512x512.png" \
  "1024 icon_512x512@2x.png"; do
  size="${spec%% *}"
  name="${spec#* }"
  /usr/bin/sips -z "$size" "$size" "$MASTER_ICON" --out "$ICONSET/$name" >/dev/null
done

if ! /usr/bin/iconutil -c icns "$ICONSET" -o "$CONTENTS/Resources/AppIcon.icns"; then
  sleep 1
  /usr/bin/iconutil -c icns "$ICONSET" -o "$CONTENTS/Resources/AppIcon.icns"
fi

/usr/bin/codesign --force --deep --sign - "$APP"
# 校验失败会走 stderr 报错；成功就别把临时 app 的路径打到屏幕上。
/usr/bin/plutil -lint "$CONTENTS/Info.plist" >/dev/null

# 固定名字的 dmg：带 /Applications 快捷方式，方便拖拽安装。
/usr/bin/ditto "$APP" "$DMG_SOURCE/GPT Switch.app"
/bin/ln -s /Applications "$DMG_SOURCE/Applications"
/usr/bin/hdiutil create -quiet -ov -format UDZO \
  -volname "GPT Switch" -srcfolder "$DMG_SOURCE" "$DMG"

print -r -- "$DMG"
