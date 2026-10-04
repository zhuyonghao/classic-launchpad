#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"

export CLANG_MODULE_CACHE_PATH="$PROJECT_ROOT/.build/clang-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PROJECT_ROOT/.build/swift-module-cache"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$SWIFTPM_MODULECACHE_OVERRIDE"

if [[ ! -f Resources/AppIcon.icns ]]; then
    "$PROJECT_ROOT/Scripts/make-icon.sh"
fi

BUILD_ARGUMENTS=(
    --configuration release
    --disable-sandbox
    --cache-path "$PROJECT_ROOT/.build/swiftpm-cache"
    --config-path "$PROJECT_ROOT/.build/swiftpm-config"
    --security-path "$PROJECT_ROOT/.build/swiftpm-security"
)
swift build "${BUILD_ARGUMENTS[@]}"
BINARY_DIRECTORY="$(swift build "${BUILD_ARGUMENTS[@]}" --show-bin-path)"
APP_DIRECTORY="$PROJECT_ROOT/build/启动台.app"
mkdir -p "$APP_DIRECTORY/Contents/MacOS" "$APP_DIRECTORY/Contents/Resources"
cp "$BINARY_DIRECTORY/ClassicLaunchpad" "$APP_DIRECTORY/Contents/MacOS/ClassicLaunchpad"
cp "$PROJECT_ROOT/Resources/Info.plist" "$APP_DIRECTORY/Contents/Info.plist"
cp "$PROJECT_ROOT/Resources/AppIcon.icns" "$APP_DIRECTORY/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP_DIRECTORY/Contents/PkgInfo"
codesign --force --sign - "$APP_DIRECTORY"
codesign --verify --strict "$APP_DIRECTORY"
printf '\n已构建：%s\n' "$APP_DIRECTORY"
printf '运行：open "%s"\n' "$APP_DIRECTORY"
