#!/bin/bash
# Keep hardware and desktop automation explicit so a missing prerequisite cannot masquerade as a pass.
set -euo pipefail
cd "$(dirname "$0")/.."
case "${1:-local}" in
  local)
    swift test
    ;;
  --hardware)
    export COMET_E2E_SESSION="${COMET_E2E_SESSION:-$HOME/.cache/qrx/comet-session.json}"
    test -r "$COMET_E2E_SESSION"
    swift test --filter HardwareE2ETests
    ;;
  --ui)
    xcodebuild -project CometKVM.xcodeproj -scheme CometKVM -destination 'platform=macOS' \
      -derivedDataPath build/DerivedData -clonedSourcePackagesDirPath .build/xcode-packages \
      -only-testing:CometUITests test
    ;;
  --ui-hardware)
    export TEST_RUNNER_COMET_UI_SESSION_FILE="${COMET_E2E_SESSION:-$HOME/.cache/qrx/comet-session.json}"
    test -r "$TEST_RUNNER_COMET_UI_SESSION_FILE"
    xcodebuild -project CometKVM.xcodeproj -scheme CometKVM -destination 'platform=macOS' \
      -derivedDataPath build/DerivedData -clonedSourcePackagesDirPath .build/xcode-packages \
      -only-testing:CometUITests test
    ;;
  --video)
    swift test --filter ProtocolE2ETests/testNativeWebRTCVideoEndToEndThroughJanusAndMetal
    ;;
  *)
    printf 'Usage: scripts/test.sh [local|--hardware|--ui|--ui-hardware|--video]\n' >&2
    exit 2
    ;;
esac
