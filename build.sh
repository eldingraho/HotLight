#!/bin/sh
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
bundle="$here/LightHot.app"
mkdir -p "$bundle/Contents/MacOS"
cp "$here/Info.plist" "$bundle/Contents/Info.plist"
if [ -d /Applications/Xcode.app/Contents/Developer ]; then
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  export DEVELOPER_DIR
fi
"$(xcrun --find clang)" -isysroot "$(xcrun --sdk macosx --show-sdk-path)" -arch arm64 -Os -fobjc-arc "$here/main.m" -framework AppKit -framework IOKit -o "$bundle/Contents/MacOS/LightHot"
printf '%s\n' "$bundle"
