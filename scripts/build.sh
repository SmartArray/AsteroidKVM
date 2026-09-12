#!/bin/bash
# Build an ad-hoc signed native application using the checked-in Xcode project.
set -euo pipefail
cd "$(dirname "$0")/.."
xcodebuild -project CometKVM.xcodeproj -scheme CometKVM -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath build/DerivedData \
  -clonedSourcePackagesDirPath .build/xcode-packages build
