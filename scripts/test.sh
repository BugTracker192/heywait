#!/usr/bin/env bash
set -euo pipefail

derived_path="${DERIVED_DATA_PATH:-.derived-data}"
device_id="$(
  xcrun simctl list devices available --json |
    python3 -c 'import json,sys
d=json.load(sys.stdin)["devices"]
for runtime, devices in reversed(list(d.items())):
    for device in devices:
        if device.get("isAvailable") and device["name"].startswith("iPhone"):
            print(device["udid"])
            raise SystemExit
raise SystemExit("No available iPhone simulator")'
)"

xcodebuild \
  -project ScreenShare.xcodeproj \
  -scheme ScreenShareReceiver \
  -configuration Debug \
  -destination "platform=iOS Simulator,id=${device_id}" \
  -derivedDataPath "$derived_path" \
  CODE_SIGNING_ALLOWED=NO \
  test

