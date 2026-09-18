#!/bin/zsh
set -euo pipefail

SWIFT_COMPILER="$(/usr/bin/xcrun --find swiftc)"
SWIFT_HEADERS="$(dirname "$(dirname "$SWIFT_COMPILER")")/include/swift"
SWIFT_OPTIONS=()
if [[ -f "$SWIFT_HEADERS/module.modulemap" && -f "$SWIFT_HEADERS/bridging.modulemap" ]] &&
   /usr/bin/grep -q 'module SwiftBridging' "$SWIFT_HEADERS/module.modulemap" &&
   /usr/bin/grep -q 'module SwiftBridging' "$SWIFT_HEADERS/bridging.modulemap"; then
  SDK_PATH="$(/usr/bin/xcrun --show-sdk-path)"
  SWIFT_SHIMS="$SDK_PATH/usr/lib/swift/shims/module.modulemap"
  [[ -f "$SWIFT_SHIMS" ]] || exit 1

  OVERLAY_DIR="$(mktemp -d "${TMPDIR:-/tmp}/gpt-switch-swift.XXXXXX")"
  trap 'rm -rf "$OVERLAY_DIR"' EXIT
  OVERLAY="$OVERLAY_DIR/overlay.json"
  print -r -- "{\"version\":0,\"case-sensitive\":false,\"roots\":[{\"name\":\"$SWIFT_HEADERS/module.modulemap\",\"type\":\"file\",\"external-contents\":\"/dev/null\"}]}" > "$OVERLAY"
  SWIFT_OPTIONS=(-vfsoverlay "$OVERLAY" -Xcc "-fmodule-map-file=$SWIFT_SHIMS")
fi

/usr/bin/xcrun swiftc "${SWIFT_OPTIONS[@]}" "$@"
