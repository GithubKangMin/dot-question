#!/bin/bash
set -euo pipefail
# Process/job scoped only. Never use sudo or xcode-select --switch.
for developer in /Applications/Xcode.app/Contents/Developer /Applications/Xcode_*.app/Contents/Developer; do
  [[ -d "$developer" ]] || continue
  if DEVELOPER_DIR="$developer" xcrun --find xctest >/dev/null 2>&1 &&
     DEVELOPER_DIR="$developer" xcrun --find swift >/dev/null 2>&1; then
    echo "DEVELOPER_DIR=$developer" >> "$GITHUB_ENV"
    DEVELOPER_DIR="$developer" xcodebuild -version
    DEVELOPER_DIR="$developer" xcrun swift --version
    exit 0
  fi
done
echo 'No usable preinstalled Xcode with XCTest. No installation attempted.' >&2
exit 1
