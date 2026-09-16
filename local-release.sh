#!/bin/bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFO_PLIST="${SCRIPT_DIR}/Info.plist"
BUILD_DIR="${OUTPUT_DIR:-${SCRIPT_DIR}/dist}"
ARTIFACT_DIR="${GPT_SWITCH_RELEASE_ARTIFACT_DIR:-${HOME}/.cache/gpt-switch/releases}"
KEEP_RELEASES="${GPT_SWITCH_KEEP_RELEASES:-4}"
GITHUB_REPOSITORY="${GPT_SWITCH_GITHUB_REPOSITORY:-}"
APP_NAME="GPT Switch.app"

if [[ "${BUILD_DIR}" != /* ]]; then BUILD_DIR="${SCRIPT_DIR}/${BUILD_DIR}"; fi
if [[ "${ARTIFACT_DIR}" != /* ]]; then ARTIFACT_DIR="${SCRIPT_DIR}/${ARTIFACT_DIR}"; fi
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

  current_branch="$(git -C "$SCRIPT_DIR" branch --show-current)"
  [[ "$current_branch" == "main" ]] || \
    die "发布必须从 main 分支执行，当前分支：${current_branch}"
  [[ -z "$(git -C "$SCRIPT_DIR" status --porcelain)" ]] || \
    die "工作树不干净，请先提交当前改动"

  if [[ -z "${GPT_SWITCH_RELEASE_SKIP_SYNC:-}" ]]; then
    git -C "$SCRIPT_DIR" fetch origin main --quiet
    [[ "$(git -C "$SCRIPT_DIR" rev-parse HEAD)" == "$(git -C "$SCRIPT_DIR" rev-parse origin/main)" ]] || \
      die "本地 main 必须与 origin/main 完全一致"
  fi
}

run_release_gate() {
  require_command git
  require_command node
  require_command shasum
  require_command hdiutil

  /usr/bin/plutil -lint "$INFO_PLIST"
  "$SCRIPT_DIR/test.sh"
  git -C "$SCRIPT_DIR" diff --check
  node -e '
    const fs = require("fs");
    const value = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    const models = Array.isArray(value) ? value : value.models;
    if (!Array.isArray(models)) throw new Error("models.json 缺少模型列表");
    for (const model of models) {
      if (!model || typeof model.id !== "string" || !model.id.trim()) {
        throw new Error("models.json 中存在无效模型 ID");
      }
    }
  ' "$SCRIPT_DIR/models.json"
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

release_notes_path() {
  printf '%s/GPT-Switch-v%s-macOS-release-notes.md\n' "$ARTIFACT_DIR" "$1"
}

record_local_artifact() {
  local filename="$1"
  local history="${ARTIFACT_DIR}/history"
  local temporary candidate item

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
}

generate_release_notes() {
  local version="$1"
  local output="$2"
  local commit

  commit="$(git -C "$SCRIPT_DIR" rev-parse --short=12 HEAD)"

  {
    printf '# GPT Switch %s\n\n' "$version"
    printf '> 构建提交：`%s`。\n\n' "$commit"
    printf '## 更新内容\n\n'
    printf '%s\n' '- 支持从 `models.json` 读取自定义模型名称和模型 ID。'
    printf '%s\n' '- 将模型名称注入界面，选中后按配置的模型 ID 发起请求。'
    printf '%s\n' '- 提供 macOS DMG 安装包。'
    printf '\n## 模型配置\n\n'
    printf '%s\n' '`displayName` 用于界面显示，`id` 用于客户端模型标识和实际请求。'
  } > "$output"
}

prepare_release() {
  local version="$1"
  local artifact metadata checksum notes
  local artifact_tmp metadata_tmp checksum_tmp notes_tmp
  local dmg_source commit build_date artifact_sha256

  ensure_macos
  ensure_release_source "$version"
  run_release_gate

  info "构建 ${APP_NAME}"
  OUTPUT_DIR="$BUILD_DIR" "$SCRIPT_DIR/build.sh" >/dev/null
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
  commit="$(git -C "$SCRIPT_DIR" rev-parse HEAD)"
  build_date="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  dmg_source="$(mktemp -d "${TMPDIR:-/tmp}/gpt-switch-dmg.XXXXXX")"
  trap 'rm -rf "$dmg_source"; rm -f "$artifact_tmp" "$metadata_tmp" "$checksum_tmp" "$notes_tmp"' EXIT
  info "打包 macOS 应用"
  /usr/bin/ditto "$APP_PATH" "$dmg_source/$APP_NAME"
  /bin/ln -s /Applications "$dmg_source/Applications"
  /usr/bin/hdiutil create -quiet -ov -format UDZO \
    -volname "GPT Switch" -srcfolder "$dmg_source" "$artifact_tmp"
  artifact_sha256="$(shasum -a 256 "$artifact_tmp" | awk '{print $1}')"
  {
    printf 'version=%s\n' "$version"
    printf 'commit=%s\n' "$commit"
    printf 'app=%s\n' "$APP_NAME"
    printf 'created_at=%s\n' "$build_date"
    printf 'sha256=%s\n' "$artifact_sha256"
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
}

resolve_github_repository() {
  local remote_url repository

  if [[ -n "$GITHUB_REPOSITORY" ]]; then
    repository="$GITHUB_REPOSITORY"
  else
    remote_url="$(git -C "$SCRIPT_DIR" remote get-url origin)"
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

  artifact="$(artifact_path "$version")"
  metadata="$(metadata_path "$version")"
  checksum="$(checksum_path "$version")"
  notes="$(release_notes_path "$version")"
  expected_commit="$(git -C "$SCRIPT_DIR" rev-parse HEAD)"
  [[ -s "$artifact" && -s "$metadata" && -s "$checksum" && -s "$notes" ]] || \
    die "找不到完整的 prepare 产物，请先执行 prepare $version"
  artifact_commit="$(awk -F= '$1 == "commit" { print $2; exit }' "$metadata")"
  [[ "$artifact_commit" == "$expected_commit" ]] || \
    die "产物属于提交 ${artifact_commit}，当前提交为 ${expected_commit}"
  expected_sha256="$(awk -F= '$1 == "sha256" { print $2; exit }' "$metadata")"
  actual_sha256="$(shasum -a 256 "$artifact" | awk '{print $1}')"
  [[ -n "$expected_sha256" && "$expected_sha256" == "$actual_sha256" ]] || \
    die "产物 SHA256 校验失败"
}

verify_release_assets() {
  local repository="$1"
  local tag="$2"
  shift 2
  local asset names

  names="$(gh release view "$tag" --repo "$repository" --json assets --jq '.assets[].name')"
  for asset in "$@"; do
    grep -Fqx "$(basename "$asset")" <<< "$names" || \
      die "GitHub Release 缺少资产：$(basename "$asset")"
  done
}

publish_release() {
  local version="$1"
  local tag repository artifact metadata checksum notes
  local existing_commit confirmation is_draft

  ensure_macos
  require_command gh
  ensure_release_source "$version"
  verify_prepared_artifact "$version"
  gh auth status --hostname github.com >/dev/null 2>&1 || die "请先执行 gh auth login"

  tag="v${version}"
  artifact="$(artifact_path "$version")"
  metadata="$(metadata_path "$version")"
  checksum="$(checksum_path "$version")"
  notes="$(release_notes_path "$version")"

  if git -C "$SCRIPT_DIR" rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
    existing_commit="$(git -C "$SCRIPT_DIR" rev-list -n 1 "$tag")"
    [[ "$existing_commit" == "$(git -C "$SCRIPT_DIR" rev-parse HEAD)" ]] || \
      die "$tag 已经指向其他提交：$existing_commit"
  else
    printf '请输入要创建的 tag（%s）：' "$tag"
    IFS= read -r confirmation
    [[ "$confirmation" == "$tag" ]] || die "tag 确认不匹配"
    git -C "$SCRIPT_DIR" tag -a "$tag" -m "Release $tag"
  fi

  if ! git -C "$SCRIPT_DIR" ls-remote --exit-code --tags origin "refs/tags/$tag" >/dev/null 2>&1; then
    info "推送 $tag"
    git -C "$SCRIPT_DIR" push origin "refs/tags/$tag"
  fi

  repository="$(resolve_github_repository)"
  if gh release view "$tag" --repo "$repository" >/dev/null 2>&1; then
    is_draft="$(gh release view "$tag" --repo "$repository" --json isDraft --jq '.isDraft')"
    [[ "$is_draft" == "true" ]] || die "$tag 的 GitHub Release 已存在且不是 Draft，请使用新的版本号"
    info "更新 GitHub Draft Release $tag"
    gh release edit "$tag" --repo "$repository" --title "GPT Switch $version" \
      --notes-file "$notes" --draft=true >/dev/null
    gh release upload "$tag" --repo "$repository" --clobber \
      "$artifact" "$metadata" "$checksum"
  else
    info "创建 GitHub Draft Release $tag"
    gh release create "$tag" --repo "$repository" --verify-tag \
      --title "GPT Switch $version" --notes-file "$notes" --draft \
      "$artifact" "$metadata" "$checksum" >/dev/null
  fi

  verify_release_assets "$repository" "$tag" "$artifact" "$metadata" "$checksum"
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
