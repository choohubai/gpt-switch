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
"$NODE" --check "$SOURCE_DIR/channel-config.mjs"
"$NODE" --test "$ROOT_DIR"/tests/*.test.mjs
/bin/zsh "$SCRIPT_DIR/swiftc.sh" -parse-as-library -target "$(uname -m)-apple-macosx13.0" -framework SwiftUI -typecheck "$SOURCE_DIR/StatusMenu.swift"
# 面板状态机（开关、删除、保存跟随 current）只写在这份用例里：必须真的编译并跑起来，
# 只 typecheck 拦不住「存盘失败没回滚」这类回归。
PANEL_TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/gpt-switch-panel.XXXXXX")"
PANEL_RENDER_DIR="$PANEL_TEST_DIR/render"
mkdir -p "$PANEL_RENDER_DIR"
/bin/zsh "$SCRIPT_DIR/swiftc.sh" -D STATUS_MENU_TEST -parse-as-library -target "$(uname -m)-apple-macosx13.0" -framework SwiftUI \
  "$SOURCE_DIR/StatusMenu.swift" "$ROOT_DIR/tests/StatusMenuTests.swift" -o "$PANEL_TEST_DIR/panel-tests"
"$PANEL_TEST_DIR/panel-tests" "$RESOURCE_DIR/MenuBarIcon.png" "$PANEL_RENDER_DIR"
rm -rf "$PANEL_TEST_DIR"
/bin/zsh -n "$SCRIPT_DIR/GPTSwitch"
/bin/zsh -n "$SCRIPT_DIR/build.sh"
/bin/zsh -n "$SCRIPT_DIR/swiftc.sh"
/bin/bash -n "$SCRIPT_DIR/local-release.sh"
/bin/zsh -n "$SCRIPT_DIR/package-windows.sh"
/usr/bin/plutil -lint "$RESOURCE_DIR/Info.plist"

# Windows probe 会真的加载 XAML；本地发布门禁也先按 XML 解析一遍，
# 否则开闭标签错位会直到 Windows CI 才暴露。
PANEL_XAML="$(mktemp "${TMPDIR:-/tmp}/gpt-switch-panel-xaml.XXXXXX")"
"$NODE" -e 'const fs = require("fs"); const source = fs.readFileSync(process.argv[1], "utf8"); const match = /\[xml\]\$xaml = @"([\s\S]*?)"@/.exec(source); if (!match) throw new Error("StatusMenu.ps1 里找不到 XAML"); fs.writeFileSync(process.argv[2], match[1]);' \
  "$SOURCE_DIR/StatusMenu.ps1" "$PANEL_XAML"
xmllint --noout "$PANEL_XAML"
rm -f "$PANEL_XAML"

# Windows 面板没有 WPF 运行环境；至少守住保存回包不能把空 ID 渠道回填到界面。
for marker in "function Test-ResponseChannels" "if (Test-ResponseChannels \$Response.channels)" \
  "插件返回的渠道列表不完整，已保留当前配置"; do
  if ! grep -Fq "$marker" "$SOURCE_DIR/StatusMenu.ps1"; then
    print -u2 -- "Windows 面板缺少渠道回包保护：$marker"
    exit 1
  fi
done

if ! grep -Fq "StatusMenu.ps1.test.ps1" "$ROOT_DIR/.github/workflows/windows-probe.yml"; then
  print -u2 -- "Windows probe 没有执行 tests/StatusMenu.ps1.test.ps1"
  exit 1
fi

# PowerShell 的注释只有 # 和 <# #>：C / Swift 风格的整行注释会被当成命令，脚本在第 8 行的
# $ErrorActionPreference = "Stop" 下直接中止，而 CI 的 ParseFile 检查报 0 错误、拦不住。
if grep -rnE '^[[:space:]]*(///|//|/\*)' "$SOURCE_DIR" "$SCRIPT_DIR" "$ROOT_DIR/tests" \
  --include='*.ps1' 2>/dev/null; then
  print -u2 -- "PowerShell 脚本里出现了 C / Swift 风格的整行注释，运行时会当成命令执行"
  exit 1
fi

# Windows 安装包的载荷：面板、原生启动器源码和打包脚本都要在。
WINDOWS_PAYLOADS=("$SOURCE_DIR/StatusMenu.ps1" "$SOURCE_DIR/WindowsLauncher.cs" "$SOURCE_DIR/channel-config.mjs" \
  "$SCRIPT_DIR/build-windows-host.ps1" "$SCRIPT_DIR/package-windows.sh" "$SCRIPT_DIR/windows-installer.nsi")
for payload in "${WINDOWS_PAYLOADS[@]}"; do
  if [[ ! -f "$payload" ]]; then
    print -u2 -- "缺少 Windows 打包文件：$payload"
    exit 1
  fi
done

# Windows 启动路径必须使用原生 EXE；旧 PowerShell 脚本只允许在升级旧安装时被安装器调用。
if [[ -e "$SCRIPT_DIR/GPTSwitch.ps1" ]]; then
  print -u2 -- "旧 PowerShell 启动器仍在仓库里：Scripts/GPTSwitch.ps1"
  exit 1
fi
if ! grep -Fq 'CreateShortCut "$SMPROGRAMS\GPT Switch\GPT Switch.lnk" "$INSTDIR\GPT Switch.exe"' \
  "$SCRIPT_DIR/windows-installer.nsi"; then
  print -u2 -- "Windows 快捷方式没有直接指向 GPT Switch.exe"
  exit 1
fi
if ! grep -Fq '"$INSTDIR\GPT Switch.exe" --stop' "$SCRIPT_DIR/windows-installer.nsi"; then
  print -u2 -- "Windows 卸载程序没有调用原生 --stop"
  exit 1
fi
for marker in installStopOk uninstallStopOk; do
  if ! grep -Fq "$marker" "$SCRIPT_DIR/windows-installer.nsi"; then
    print -u2 -- "Windows 安装器没有在停止失败时中止：$marker"
    exit 1
  fi
done
if ! grep -Fq 'WINDOWS_LAUNCHER_PATH' "$SOURCE_DIR/injector.mjs"; then
  print -u2 -- "Windows 面板没有通过原生启动器承载"
  exit 1
fi
if ! grep -Fq 'GPT_SWITCH_WINDOWS_HOST' "$SCRIPT_DIR/package-windows.sh"; then
  print -u2 -- "Windows 打包没有要求原生启动器输入"
  exit 1
fi
if ! grep -Fq 'WindowsLauncher.ps1.test.ps1' "$ROOT_DIR/.github/workflows/windows-probe.yml"; then
  print -u2 -- "Windows probe 没有执行原生启动器测试"
  exit 1
fi

# 打包脚本要带上注入器 import 的每个本地模块：漏一个，装出来的客户端一启动就报找不到模块。
for module in $(sed -n 's/.*from "\.\/\([^"]*\.mjs\)".*/\1/p' "$SOURCE_DIR"/*.mjs | sort -u); do
  for packager in "$SCRIPT_DIR/build.sh" "$SCRIPT_DIR/package-windows.sh"; do
    if ! grep -qF "\$SOURCE_DIR/$module" "$packager"; then
      print -u2 -- "$(basename "$packager") 没有把 $module 打进包里"
      exit 1
    fi
  done
done

# 面板显示的版本来自 injector.mjs，必须和 Info.plist 一致。
INJECTOR_VERSION="$(tr -d '\r' < "$SOURCE_DIR/injector.mjs" | sed -n 's/^const VERSION = "\(.*\)";$/\1/p')"
PLIST_VERSION="$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$RESOURCE_DIR/Info.plist")"
if [[ "$INJECTOR_VERSION" != "$PLIST_VERSION" ]]; then
  print -u2 -- "injector.mjs 版本 ${INJECTOR_VERSION} 与 Info.plist 版本 ${PLIST_VERSION} 不一致"
  exit 1
fi

print -- "源码检查通过。"
