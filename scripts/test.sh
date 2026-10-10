#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
stage_dir=$(mktemp -d "${TMPDIR:-/tmp}/codex-usage-tests.XXXXXX")
trap 'rm -rf "$stage_dir"' EXIT
mkdir -p "$project_root/.build/module-cache"
# Compile the production client directly, without launching the menu bar UI.
sed '/^final class UsageModel:/,$d' "$project_root/Sources/main.swift" > "$stage_dir/main.swift"
cat "$project_root/Tests/QuotaClientTests.swift" >> "$stage_dir/main.swift"
swiftc -module-cache-path "$project_root/.build/module-cache" "$stage_dir/main.swift" -o "$stage_dir/QuotaClientTests" -framework AppKit -framework SwiftUI
"$stage_dir/QuotaClientTests" "$project_root/Tests/fake-server.py"
sed '/^\/\/ Runtime:/,$d' "$project_root/Sources/Watcher.swift" > "$stage_dir/main.swift"
cat "$project_root/Tests/WatcherTests.swift" >> "$stage_dir/main.swift"
swiftc -module-cache-path "$project_root/.build/module-cache" "$stage_dir/main.swift" -o "$stage_dir/WatcherTests" -framework AppKit
"$stage_dir/WatcherTests"
