#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
if [[ "$(uname -s)" != Darwin ]]; then
  echo 'macOS에서 실행해야 합니다. Linux에서는 AppKit/Vision 앱을 빌드할 수 없습니다.' >&2
  exit 1
fi
if ! xcrun --find swift >/dev/null 2>&1; then
  echo 'Apple Command Line Tools가 필요합니다. 터미널에서 xcode-select --install 을 실행하세요.' >&2
  exit 1
fi
# Standalone Command Line Tools can compile the app but may omit XCTest.
# Prefer an already installed Xcode for this process only; never run xcode-select.
if ! xcrun --find xctest >/dev/null 2>&1; then
  if [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  else
    echo 'XCTest가 포함된 Xcode가 필요합니다. Xcode 설치 및 초기 설정을 직접 완료하세요.' >&2
    exit 1
  fi
fi
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFT_MODULECACHE_PATH="$PWD/.build/ModuleCache"
SWIFT_OPTIONS=(--cache-path "$PWD/.build/cache" --config-path "$PWD/.build/config" --security-path "$PWD/.build/security")
xcrun swift test "${SWIFT_OPTIONS[@]}"
xcrun swift build -c release "${SWIFT_OPTIONS[@]}"
BIN_DIR="$(xcrun swift build -c release "${SWIFT_OPTIONS[@]}" --show-bin-path)"
APP="$PWD/dist/dot question.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/DotQuestion" "$APP/Contents/MacOS/DotQuestion"
cp Info.plist "$APP/Contents/Info.plist"
/usr/bin/plutil -lint "$APP/Contents/Info.plist"
/usr/bin/codesign --force --sign - "$APP"
/usr/bin/codesign --verify --verbose "$APP"
echo "완료: $APP"
echo 'Finder에서 dist 폴더의 dot question.app을 열어 실행하세요.'
