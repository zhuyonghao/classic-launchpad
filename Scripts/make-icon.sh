#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ICONSET_DIRECTORY="$PROJECT_ROOT/.build/AppIcon.iconset"
export CLANG_MODULE_CACHE_PATH="$PROJECT_ROOT/.build/clang-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PROJECT_ROOT/.build/swift-module-cache"
mkdir -p "$ICONSET_DIRECTORY" "$CLANG_MODULE_CACHE_PATH" "$SWIFTPM_MODULECACHE_OVERRIDE"
swift "$PROJECT_ROOT/Scripts/MakeIcon.swift" "$ICONSET_DIRECTORY"
iconutil --convert icns "$ICONSET_DIRECTORY" --output "$PROJECT_ROOT/Resources/AppIcon.icns"
printf '已生成：%s\n' "$PROJECT_ROOT/Resources/AppIcon.icns"
