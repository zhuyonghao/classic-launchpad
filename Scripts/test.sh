#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$PROJECT_ROOT/Scripts/build.sh"

TEST_DIRECTORY="$(mktemp -d "${TMPDIR:-/tmp}/classic-launchpad-tests.XXXXXX")"
trap 'rm -rf "$TEST_DIRECTORY"' EXIT
CLASSIC_LAUNCHPAD_DATA_DIR="$TEST_DIRECTORY" \
    "$PROJECT_ROOT/build/启动台.app/Contents/MacOS/ClassicLaunchpad" --smoke-test
