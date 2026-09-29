#!/bin/bash
# Build an ad-hoc signed native application; optional arguments override Xcode build settings.
set -euo pipefail
cd "$(dirname "$0")/.."
xcodebuild -project AsteroidKVM.xcodeproj -scheme AsteroidKVM -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath build/DerivedData \
  -clonedSourcePackagesDirPath .build/xcode-packages build "$@"
