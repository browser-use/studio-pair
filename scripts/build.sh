#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export MACOSX_DEPLOYMENT_TARGET=14.2
cargo build --release --locked
destination="${STUDIO_PAIR_BUILD_DEST:-$PWD/build/Studio Pair.app}"
mkdir -p "$destination/Contents/MacOS"
cp target/release/studio-pair-engine "$destination/Contents/MacOS/studio-pair-engine"
cp Info.plist "$destination/Contents/Info.plist"
mkdir -p build
clang -O2 -Wall -Wextra -Werror -mmacosx-version-min=14.2 -c app/DisplayHardware.c -o build/DisplayHardware.o
clang -O2 -Wall -Wextra -Werror -mmacosx-version-min=14.2 app/DisplayGuard.c build/DisplayHardware.o -framework CoreGraphics -o "$destination/Contents/MacOS/studio-pair-display"
swiftc -O -swift-version 5 -target "$(uname -m)-apple-macosx14.2" -import-objc-header app/DisplayHardware.h build/DisplayHardware.o app/*.swift -o "$destination/Contents/MacOS/StudioPair" -framework AppKit -framework ServiceManagement
codesign --force --sign - --identifier com.browseruse.studiopair.engine "$destination/Contents/MacOS/studio-pair-engine"
codesign --force --sign - --identifier com.browseruse.studiopair.display "$destination/Contents/MacOS/studio-pair-display"
codesign --force --sign - "$destination"
codesign --verify --deep --strict "$destination"
printf 'Built %s\n' "$destination"
