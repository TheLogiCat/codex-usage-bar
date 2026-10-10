#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
stage_dir="$(mktemp -d "${TMPDIR:-/tmp}/codex-usage-bar.XXXXXX")"
trap 'rm -rf "$stage_dir"' EXIT
app_dir="$stage_dir/CodexUsageBar.app"
mkdir -p "$app_dir/Contents/Helpers" "$app_dir/Contents/MacOS" "$project_root/.build/module-cache" "$project_root/dist"

case "$(uname -m)" in
  arm64) target="arm64-apple-macosx13.0" ;;
  x86_64) target="x86_64-apple-macosx13.0" ;;
  *) echo "Unsupported architecture" >&2; exit 1 ;;
esac

swiftc -O -target "$target" \
  -module-cache-path "$project_root/.build/module-cache" \
  "$project_root/Sources/main.swift" \
  -o "$app_dir/Contents/MacOS/CodexUsageBar" \
  -framework AppKit -framework SwiftUI
swiftc -O -target "$target" \
  -module-cache-path "$project_root/.build/module-cache" \
  "$project_root/Sources/Watcher.swift" \
  -o "$app_dir/Contents/Helpers/CodexUsageWatcher" -framework AppKit
cp "$project_root/Resources/Info.plist" "$app_dir/Contents/Info.plist"
xattr -cr "$app_dir"
codesign --force --sign - "$app_dir/Contents/Helpers/CodexUsageWatcher"
codesign --force --sign - "$app_dir"
codesign --verify --deep --strict "$app_dir"
ditto --norsrc "$app_dir" "$project_root/dist/CodexUsageBar.app"
ditto -c -k --norsrc --keepParent "$app_dir" "$project_root/dist/CodexUsageBar.zip"
echo "Built: $project_root/dist/CodexUsageBar.zip"
