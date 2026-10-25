#!/bin/bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
INFO_PLIST="${ROOT_DIR}/Resources/Info.plist"
BUILD_DIR="${OUTPUT_DIR:-${ROOT_DIR}/dist}"
ARTIFACT_DIR="${GPT_SWITCH_RELEASE_ARTIFACT_DIR:-${HOME}/.cache/gpt-switch/releases}"
KEEP_RELEASES="${GPT_SWITCH_KEEP_RELEASES:-4}"
GITHUB_REPOSITORY="${GPT_SWITCH_GITHUB_REPOSITORY:-}"
APP_NAME="GPT Switch.app"

if [[ "${BUILD_DIR}" != /* ]]; then BUILD_DIR="${ROOT_DIR}/${BUILD_DIR}"; fi
if [[ "${ARTIFACT_DIR}" != /* ]]; then ARTIFACT_DIR="${ROOT_DIR}/${ARTIFACT_DIR}"; fi
APP_PATH="${BUILD_DIR}/${APP_NAME}"

usage() {
  cat <<'EOF'
Usage:
  ./local-release.sh prepare <version>
  ./local-release.sh publish <version>

Examples:
  ./local-release.sh prepare 0.1.18
  ./local-release.sh publish 0.1.18

prepare checks the source, builds the macOS app, and creates a DMG, metadata,
SHA256 file, and release notes under ~/.cache/gpt-switch/releases.
Set GPT_SWITCH_WINDOWS_HOST to the native Windows launcher built by
Scripts/build-windows-host.ps1; the Windows installer packages that EXE.
publish verifies that prepared artifact belongs to the current commit, creates
and pushes v<version>, then creates and publishes a GitHub Release.
EOF
}

die() {
  echo "Error: $*" >&2
  exit 1
}

info() {
  echo "==> $*"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "未找到命令：$1"
}

version_from_plist() {
  /usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$INFO_PLIST"
}

validate_version() {
  [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.][0-9]+)?$ ]] || \
    die "版本号必须是 X.Y.Z 或 X.Y.Z.N：$1"
}

ensure_macos() {
  [[ "$(uname -s)" == "Darwin" ]] || die "当前发布脚本只支持 macOS"
}

ensure_release_source() {
  local version="$1"
  local current_version current_branch

  current_version="$(version_from_plist)"
  [[ "$current_version" == "$version" ]] || \
    die "Info.plist 版本为 ${current_version}，传入版本为 ${version}"

  current_branch="$(git -C "$ROOT_DIR" branch --show-current)"
  # CI 上按 tag 检出时是 detached HEAD，本地发布仍然强制 main。
  if [[ "$current_branch" != "main" && -z "${GPT_SWITCH_RELEASE_ALLOW_DETACHED:-}" ]]; then
    die "发布必须从 main 分支执行，当前分支：${current_branch:-detached HEAD}"
  fi
  [[ -z "$(git -C "$ROOT_DIR" status --porcelain)" ]] || \
    die "工作树不干净，请先提交当前改动"

  if [[ -z "${GPT_SWITCH_RELEASE_SKIP_SYNC:-}" ]]; then
    git -C "$ROOT_DIR" fetch origin main --quiet
    [[ "$(git -C "$ROOT_DIR" rev-parse HEAD)" == "$(git -C "$ROOT_DIR" rev-parse origin/main)" ]] || \
      die "本地 main 必须与 origin/main 完全一致"
  fi
}

run_release_gate() {
  require_command git
  require_command node
  require_command shasum
  require_command hdiutil
  require_command makensis
  [[ -n "${GPT_SWITCH_WINDOWS_HOST:-}" && -s "${GPT_SWITCH_WINDOWS_HOST}" ]] || \
    die "缺少原生 Windows 启动器，请设置 GPT_SWITCH_WINDOWS_HOST"

  /usr/bin/plutil -lint "$INFO_PLIST"
  "$SCRIPT_DIR/test.sh"
  git -C "$ROOT_DIR" diff --check
}

artifact_name() {
  printf 'GPT-Switch-v%s-macOS.dmg\n' "$1"
}

artifact_path() {
  printf '%s/%s\n' "$ARTIFACT_DIR" "$(artifact_name "$1")"
}

metadata_path() {
  printf '%s/%s.meta\n' "$ARTIFACT_DIR" "$(artifact_name "$1")"
}

checksum_path() {
  printf '%s/%s.sha256\n' "$ARTIFACT_DIR" "$(artifact_name "$1")"
}

exe_name() {
  printf 'GPT-Switch-Setup-%s.exe\n' "$1"
}

exe_path() {
  printf '%s/%s\n' "$ARTIFACT_DIR" "$(exe_name "$1")"
}

exe_checksum_path() {
  printf '%s/%s.sha256\n' "$ARTIFACT_DIR" "$(exe_name "$1")"
}

release_notes_path() {
  printf '%s/GPT-Switch-v%s-macOS-release-notes.md\n' "$ARTIFACT_DIR" "$1"
}

record_local_artifact() {
  local filename="$1"
  local history="${ARTIFACT_DIR}/history"
  local temporary candidate item version

  mkdir -p "$ARTIFACT_DIR"
  temporary="$(mktemp "${history}.tmp.XXXXXX")"
  if ! {
    printf '%s\n' "$filename"
    if [[ -f "$history" ]]; then cat "$history"; fi
  } | awk -v keep="$KEEP_RELEASES" 'NF && !seen[$0]++ && count++ < keep' > "$temporary"; then
    rm -f "$temporary"
    return 1
  fi
  mv "$temporary" "$history"

  for candidate in "$ARTIFACT_DIR"/GPT-Switch-v*-macOS.dmg; do
    [[ -f "$candidate" ]] || continue
    item="$(basename "$candidate")"
    if ! grep -Fqx "$item" "$history"; then
      rm -f "$candidate" "${candidate}.meta" "${candidate}.sha256"
      rm -f "${ARTIFACT_DIR}/${item%.dmg}-release-notes.md"
    fi
  done

  for candidate in "$ARTIFACT_DIR"/GPT-Switch-Setup-*.exe; do
    [[ -f "$candidate" ]] || continue
    version="$(basename "$candidate")"
    version="${version#GPT-Switch-Setup-}"
    version="${version%.exe}"
    grep -Fqx "$(artifact_name "$version")" "$history" || \
      rm -f "$candidate" "${candidate}.sha256"
  done
}

generate_release_notes() {
  local version="$1"
  local output="$2"
  local commit

  commit="$(git -C "$ROOT_DIR" rev-parse --short=12 HEAD)"

  {
    printf '# GPT Switch %s\n\n' "$version"
    printf '> 构建提交：`%s`。\n\n' "$commit"
    printf '## 更新内容\n\n'
    printf '%s\n' '- 面板里维护多个渠道（地址、密钥、自定义请求头、各自的模型列表），每条渠道单独启用或禁用，多个渠道可以同时启用。'
    printf '%s\n' '- 请求走本机 127.0.0.1 上的转发服务，按模型 ID 送回所属渠道，换渠道不用改客户端指向。'
    printf '%s\n' '- 模型选择器按渠道分组折叠，只列插件里配置的渠道模型；同一个模型 ID 出现在多个渠道时各算一组。'
    printf '%s\n' '- 新增代理设置，可配置监听 IP 和端口；端口被占用时自动顺延，重启 ChatGPT 时原子切换代理并同步更新客户端地址。'
    printf '%s\n' '- 面板改为左侧设置菜单与右侧内容区，新增「关于」版本、更新、还原入口。'
    printf '%s\n' '- Windows 面板按 macOS 重构左侧导航、绿色主题、渠道卡、开关、详情页和关于页。'
    printf '%s\n' '- Windows 开始菜单和面板宿主改为原生 GPT Switch.exe，不再由 powershell.exe 启动应用。'
    printf '%s\n' '- 修复 Windows 只有一个渠道时生成多张“未填渠道 ID”空卡的问题。'
    printf '%s\n' '- 渠道 ID 在输入时就校验格式并显示提示，不合法时不会保存。'
    printf '%s\n' '- 修复渠道名含连字符时模型选择器少显示分组的问题。'
    printf '%s\n' '- Agents 页提供插件内置公共指令模板，默认关闭；仅在用户主动启用并保存时合并，原有内容保留并备份，停用时只移除插件段。'
    printf '%s\n' '- 修复 macOS 侧栏菜单点击后页面不刷新的问题，并在 Agents 与代理页统一提供“重启 ChatGPT”入口。'
    printf '%s\n' '- Agents 页改为可编辑公共指令，首次使用内置模板；保存时合并用户正文并备份，停用时只移除插件段。'
    printf '%s\n' '- 修复 Agents 页切换卡顿，并补充重复标记、状态损坏和未保存退出的保护。'
    printf '%s\n' '- 新增多套 ChatGPT 外观主题，支持热应用背景、侧栏、输入框和弹窗。'
    printf '%s\n' '- GPT Switch 常驻监听 ChatGPT，手动重启或稍后启动时自动应用配置并恢复注入。'
    printf '%s\n' '- 右上角「重启 ChatGPT」把配置写进客户端；「关于」页的「还原配置」清理插件写过的配置和模型目录，渠道列表保留。'
    printf '%s\n' '- macOS 菜单栏面板与 Windows 桌面面板共用同一套渠道配置与转发协议，DMG 与 Windows 安装包一起发布。'
    printf '\n## 模型配置\n\n'
    printf '%s\n' '`id` 是客户端使用的模型标识，`context` 是上下文窗口（单位 k，1000k = 1M）。'
  } > "$output"
}

prepare_release() {
  local version="$1"
  local artifact metadata checksum notes
  local artifact_tmp metadata_tmp checksum_tmp notes_tmp
  local dmg_source commit build_date artifact_sha256
  local exe exe_checksum exe_sha256

  ensure_macos
  ensure_release_source "$version"
  run_release_gate

  info "构建 ${APP_NAME}"
  OUTPUT_DIR="$BUILD_DIR" DMG_OUTPUT_DIR="$BUILD_DIR" "$SCRIPT_DIR/build.sh" >/dev/null
  [[ -d "$APP_PATH" ]] || die "构建后没有找到应用：$APP_PATH"

  mkdir -p "$ARTIFACT_DIR"
  artifact="$(artifact_path "$version")"
  metadata="$(metadata_path "$version")"
  checksum="$(checksum_path "$version")"
  notes="$(release_notes_path "$version")"
  artifact_tmp="${artifact}.tmp.$$.dmg"
  metadata_tmp="${metadata}.tmp.$$"
  checksum_tmp="${checksum}.tmp.$$"
  notes_tmp="${notes}.tmp.$$"
  commit="$(git -C "$ROOT_DIR" rev-parse HEAD)"
  build_date="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  dmg_source="$(mktemp -d "${TMPDIR:-/tmp}/gpt-switch-dmg.XXXXXX")"
  trap 'rm -rf "$dmg_source"; rm -f "$artifact_tmp" "$metadata_tmp" "$checksum_tmp" "$notes_tmp"' EXIT
  info "打包 macOS 应用"
  /usr/bin/ditto "$APP_PATH" "$dmg_source/$APP_NAME"
  /bin/ln -s /Applications "$dmg_source/Applications"
  /usr/bin/hdiutil create -quiet -ov -format UDZO \
    -volname "GPT Switch" -srcfolder "$dmg_source" "$artifact_tmp"
  # .app 只是打 dmg 用的中间产物，用完就删：发布流程显式给了 OUTPUT_DIR，build.sh 不会自己清。
  rm -rf "$APP_PATH"
  artifact_sha256="$(shasum -a 256 "$artifact_tmp" | awk '{print $1}')"
  info "打包 Windows 安装包"
  # 发布包必须带版本号（GitHub Release 的资产名），所以这里显式覆盖本地默认的固定名。
  OUTPUT_DIR="$ARTIFACT_DIR" EXE_NAME="$(exe_name "$version")" "$SCRIPT_DIR/package-windows.sh" "$version" >/dev/null
  exe="$(exe_path "$version")"
  exe_checksum="$(exe_checksum_path "$version")"
  [[ -s "$exe" ]] || die "构建后没有找到 Windows 安装包：$exe"
  exe_sha256="$(shasum -a 256 "$exe" | awk '{print $1}')"
  {
    printf 'version=%s\n' "$version"
    printf 'commit=%s\n' "$commit"
    printf 'app=%s\n' "$APP_NAME"
    printf 'created_at=%s\n' "$build_date"
    printf 'sha256=%s\n' "$artifact_sha256"
    printf 'exe=%s\n' "$(basename "$exe")"
    printf 'exe_sha256=%s\n' "$exe_sha256"
  } > "$metadata_tmp"
  printf '%s  %s\n' "$artifact_sha256" "$(basename "$artifact")" > "$checksum_tmp"
  generate_release_notes "$version" "$notes_tmp"
  chmod 600 "$artifact_tmp" "$metadata_tmp" "$checksum_tmp" "$notes_tmp"
  mv "$artifact_tmp" "$artifact"
  mv "$metadata_tmp" "$metadata"
  mv "$checksum_tmp" "$checksum"
  mv "$notes_tmp" "$notes"
  record_local_artifact "$(artifact_name "$version")"
  rm -rf "$dmg_source"
  trap - EXIT

  info "已准备发布产物：$artifact"
  info "校验文件：$checksum"
  info "Windows 安装包：$exe"
}

resolve_github_repository() {
  local remote_url repository

  if [[ -n "$GITHUB_REPOSITORY" ]]; then
    repository="$GITHUB_REPOSITORY"
  else
    remote_url="$(git -C "$ROOT_DIR" remote get-url origin)"
    repository="$(printf '%s\n' "$remote_url" | sed -E \
      's#^git@github\.com:##; s#^https://github\.com/##; s#^ssh://git@github\.com/##; s#\.git$##')"
  fi
  [[ "$repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || \
    die "无法从 origin 解析 GitHub 仓库，请设置 GPT_SWITCH_GITHUB_REPOSITORY"
  printf '%s\n' "$repository"
}

verify_prepared_artifact() {
  local version="$1"
  local artifact metadata checksum notes expected_commit artifact_commit expected_sha256 actual_sha256
  local exe exe_checksum expected_exe_sha256 actual_exe_sha256
  local checksum_name checksum_sha256 exe_checksum_name exe_checksum_sha256

  artifact="$(artifact_path "$version")"
  metadata="$(metadata_path "$version")"
  checksum="$(checksum_path "$version")"
  notes="$(release_notes_path "$version")"
  exe="$(exe_path "$version")"
  exe_checksum="$(exe_checksum_path "$version")"
  expected_commit="$(git -C "$ROOT_DIR" rev-parse HEAD)"
  [[ -s "$artifact" && -s "$metadata" && -s "$checksum" && -s "$notes" && -s "$exe" && -s "$exe_checksum" ]] || \
    die "找不到完整的 prepare 产物，请先执行 prepare $version"
  artifact_commit="$(awk -F= '$1 == "commit" { print $2; exit }' "$metadata")"
  [[ "$artifact_commit" == "$expected_commit" ]] || \
    die "产物属于提交 ${artifact_commit}，当前提交为 ${expected_commit}"
  expected_sha256="$(awk -F= '$1 == "sha256" { print $2; exit }' "$metadata")"
  actual_sha256="$(shasum -a 256 "$artifact" | awk '{print $1}')"
  [[ -n "$expected_sha256" && "$expected_sha256" == "$actual_sha256" ]] || \
    die "产物 SHA256 校验失败"
  expected_exe_sha256="$(awk -F= '$1 == "exe_sha256" { print $2; exit }' "$metadata")"
  actual_exe_sha256="$(shasum -a 256 "$exe" | awk '{print $1}')"
  [[ -n "$expected_exe_sha256" && "$expected_exe_sha256" == "$actual_exe_sha256" ]] || \
    die "Windows 安装包 SHA256 校验失败"
  read -r checksum_sha256 checksum_name < "$checksum"
  [[ "$checksum_sha256" == "$expected_sha256" && "$checksum_name" == "$(basename "$artifact")" ]] || \
    die "macOS 校验文件的摘要或文件名不对"
  read -r exe_checksum_sha256 exe_checksum_name < "$exe_checksum"
  [[ "$exe_checksum_sha256" == "$expected_exe_sha256" && "$exe_checksum_name" == "$(basename "$exe")" ]] || \
    die "Windows 校验文件的摘要或文件名不对"
}

# 只核对远端资产名不够：仓库可能已经上传了别的内容。这里按 GitHub 返回的摘要逐个比对本地文件。
verify_release_assets() {
  local repository="$1"
  local tag="$2"
  shift 2
  local asset name remote_digest local_digest
  local names digests name_count digest_count

  names="$(gh release view "$tag" --repo "$repository" --json assets --jq '.assets[].name')"
  digests="$(gh release view "$tag" --repo "$repository" --json assets --jq '.assets[].digest')"
  name_count="$(printf '%s\n' "$names" | awk 'NF' | wc -l | tr -d ' ')"
  digest_count="$(printf '%s\n' "$digests" | awk 'NF' | wc -l | tr -d ' ')"
  [[ "$name_count" -eq "$digest_count" ]] || die "GitHub Release 资产清单不完整"
  for asset in "$@"; do
    name="$(basename "$asset")"
    remote_digest="$(paste <(printf '%s\n' "$names") <(printf '%s\n' "$digests") \
      | awk -v name="$name" '$1 == name { print $2; exit }')"
    [[ -n "$remote_digest" ]] || \
      die "GitHub Release 缺少资产：$(basename "$asset")"
    local_digest="sha256:$(shasum -a 256 "$asset" | awk '{print $1}')"
    [[ "$remote_digest" == "$local_digest" ]] || \
      die "GitHub Release 资产内容不一致：$(basename "$asset")"
  done
}

publish_release() {
  local version="$1"
  local tag repository artifact metadata checksum notes
  local existing_commit confirmation is_draft exe exe_checksum

  ensure_macos
  require_command gh
  ensure_release_source "$version"
  verify_prepared_artifact "$version"
  # CI 里用 GH_TOKEN / GITHUB_TOKEN，没有交互式登录。
  if [[ -z "${GH_TOKEN:-}${GITHUB_TOKEN:-}" ]]; then
    gh auth status --hostname github.com >/dev/null 2>&1 || die "请先执行 gh auth login"
  fi

  tag="v${version}"
  artifact="$(artifact_path "$version")"
  metadata="$(metadata_path "$version")"
  checksum="$(checksum_path "$version")"
  notes="$(release_notes_path "$version")"
  exe="$(exe_path "$version")"
  exe_checksum="$(exe_checksum_path "$version")"

  if git -C "$ROOT_DIR" rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
    existing_commit="$(git -C "$ROOT_DIR" rev-list -n 1 "$tag")"
    [[ "$existing_commit" == "$(git -C "$ROOT_DIR" rev-parse HEAD)" ]] || \
      die "$tag 已经指向其他提交：$existing_commit"
  else
    printf '请输入要创建的 tag（%s）：' "$tag"
    IFS= read -r confirmation
    [[ "$confirmation" == "$tag" ]] || die "tag 确认不匹配"
    git -C "$ROOT_DIR" tag -a "$tag" -m "Release $tag"
  fi

  if ! git -C "$ROOT_DIR" ls-remote --exit-code --tags origin "refs/tags/$tag" >/dev/null 2>&1; then
    info "推送 $tag"
    git -C "$ROOT_DIR" push origin "refs/tags/$tag"
  fi

  repository="$(resolve_github_repository)"
  if gh release view "$tag" --repo "$repository" >/dev/null 2>&1; then
    is_draft="$(gh release view "$tag" --repo "$repository" --json isDraft --jq '.isDraft')"
    if [[ "$is_draft" != "true" ]]; then
      # 本地和 CI 都会在打标签后发布：另一边先发完时，前面已经核对过 tag 指向当前提交，就是同一次发布。
      info "$tag 已经发布过（tag 指向当前提交），无需重复发布"
      return 0
    fi
    info "更新 GitHub Draft Release $tag"
    gh release edit "$tag" --repo "$repository" --title "GPT Switch $version" \
      --notes-file "$notes" --draft=true >/dev/null
    gh release upload "$tag" --repo "$repository" --clobber \
      "$artifact" "$metadata" "$checksum" "$exe" "$exe_checksum"
  else
    info "创建 GitHub Draft Release $tag"
    gh release create "$tag" --repo "$repository" --verify-tag \
      --title "GPT Switch $version" --notes-file "$notes" --draft \
      "$artifact" "$metadata" "$checksum" "$exe" "$exe_checksum" >/dev/null
  fi

  verify_release_assets "$repository" "$tag" "$artifact" "$metadata" "$checksum" "$exe" "$exe_checksum"
  info "GitHub Release 资产校验通过，发布 $tag"
  gh release edit "$tag" --repo "$repository" --draft=false --prerelease=false >/dev/null
  info "已发布 GitHub Release：$tag"
}

main() {
  local action="${1:-}"
  local version="${2:-}"

  if [[ "$action" == "--help" || "$action" == "-h" ]]; then
    usage
    return 0
  fi
  [[ $# -eq 2 ]] || { usage; exit 2; }
  validate_version "$version"
  [[ "$KEEP_RELEASES" =~ ^[1-9][0-9]*$ ]] || die "GPT_SWITCH_KEEP_RELEASES 必须是正整数"

  case "$action" in
    prepare) prepare_release "$version" ;;
    publish) publish_release "$version" ;;
    *) usage; exit 2 ;;
  esac
}

main "$@"
