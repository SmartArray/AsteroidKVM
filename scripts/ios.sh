#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
case "${1:-build}" in
  build)
    xcodebuild -project AsteroidKVM.xcodeproj -scheme AsteroidKVMiOS \
      -destination 'generic/platform=iOS Simulator' -derivedDataPath build/iOSDerivedData CODE_SIGNING_ALLOWED=NO build
    ;;
  device)
    xcodebuild -project AsteroidKVM.xcodeproj -scheme AsteroidKVMiOS \
      -destination 'generic/platform=iOS' -derivedDataPath build/iOSDeviceDerivedData CODE_SIGNING_ALLOWED=NO build
    ;;
  test)
    simulator_id="${2:-$(xcrun simctl list devices available -j | python3 -c 'import json,sys; d=json.load(sys.stdin); print(next(x["udid"] for r,v in d["devices"].items() if "iOS" in r for x in v if "iPhone" in x["name"]))')}"
    xcodebuild -project AsteroidKVM.xcodeproj -scheme AsteroidKVMiOS \
      -destination "platform=iOS Simulator,id=$simulator_id" -derivedDataPath "${ASTEROID_IOS_TEST_BUILD_DIR:-${TMPDIR:-/tmp}/AsteroidKVM-iOS-Tests}" \
      -collect-test-diagnostics never CODE_SIGNING_ALLOWED=NO test
    ;;
  *) echo 'Usage: scripts/ios.sh [build|device|test [simulator UUID]]' >&2; exit 2 ;;
esac
