#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h}
app_dir="$project_dir/build/Codex Usage Menu.app"
mkdir -p "$app_dir/Contents/MacOS"
mkdir -p "$project_dir/build/ModuleCache"
cp "$project_dir/Info.plist" "$app_dir/Contents/Info.plist"
printf 'APPL????' > "$app_dir/Contents/PkgInfo"
swiftc -O -parse-as-library -module-cache-path "$project_dir/build/ModuleCache" \
  -Xcc -fmodules-cache-path="$project_dir/build/ModuleCache" \
  -framework AppKit -framework SwiftUI \
  -o "$app_dir/Contents/MacOS/CodexUsageMenu" \
  "$project_dir/Sources/main.swift"
codesign --force --deep --sign - "$app_dir" >/dev/null
echo "$app_dir"
