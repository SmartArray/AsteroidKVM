#!/bin/bash
# Build the shared Swift EDID tool, then preserve the caller's directory for relative output paths.
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
swift build --package-path "$project_dir" --product create-edid >&2
binary_dir="$(swift build --package-path "$project_dir" --show-bin-path)"
exec "$binary_dir/create-edid" "$@"
