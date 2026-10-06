#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$PROJECT_ROOT/Scripts/build.sh"

# Launch this separate bundle to exercise real mouse gestures without editing
# the user's saved layout. Each preparation gets a fresh private data directory.
python3 - "$PROJECT_ROOT" <<'PY'
import pathlib
import plistlib
import shutil
import sys
import tempfile

root = pathlib.Path(sys.argv[1])
app = root / "build" / "启动台测试.app"
shutil.copytree(root / "build" / "启动台.app", app, dirs_exist_ok=True)
data = pathlib.Path(tempfile.mkdtemp(prefix="ui-test-data-", dir=root / "build"))
info = app / "Contents" / "Info.plist"
with info.open("rb") as file:
    plist = plistlib.load(file)
plist["CFBundleIdentifier"] = "com.local.ClassicLaunchpad.uitest"
plist["CFBundleDisplayName"] = "启动台测试"
plist["CFBundleName"] = "启动台测试"
plist["LSEnvironment"] = {
    "CLASSIC_LAUNCHPAD_DATA_DIR": str(data),
    "CLASSIC_LAUNCHPAD_UI_TEST": "1",
    "CLASSIC_LAUNCHPAD_DRAG_DEBUG": "1",
    "CLASSIC_LAUNCHPAD_DRAG_LOG": str(data / "drag.log"),
}
with info.open("wb") as file:
    plistlib.dump(plist, file)
(root / "build" / "ui-test-data-path.txt").write_text(str(data))
print(f"界面测试应用：{app}\n独立布局与拖拽日志：{data}")
PY
codesign --force --sign - "$PROJECT_ROOT/build/启动台测试.app"
