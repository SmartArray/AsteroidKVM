#!/bin/bash
# Normalize a stable release version before using it in build settings, tags, or filenames.
set -euo pipefail
if [[ $# != 1 ]]; then
  echo "Usage: scripts/release-version.sh [v]MAJOR.MINOR.PATCH" >&2
  exit 2
fi
version=${1#v}
if [[ ! "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
  echo "Version must be three numbers without leading zeros, such as 1.2.3 or v1.2.3." >&2
  exit 2
fi
printf '%s\n' "$version"
