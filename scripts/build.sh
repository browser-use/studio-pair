#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export MACOSX_DEPLOYMENT_TARGET=14.2
cargo build --release --locked
destination="${STUDIO_PAIR_BUILD_DEST:-$PWD/build/Studio Pair.app}"
mkdir -p "$destination/Contents/MacOS"
cp target/release/studio-pair-engine "$destination/Contents/MacOS/studio-pair-engine"
cp Info.plist "$destination/Contents/Info.plist"
swiftc -O -swift-version 5 -target "$(uname -m)-apple-macosx14.2" app/App.swift -o "$destination/Contents/MacOS/StudioPair" -framework AppKit -framework ServiceManagement
codesign --force --sign - --identifier com.browseruse.studiopair.engine "$destination/Contents/MacOS/studio-pair-engine"
codesign --force --sign - "$destination"
codesign --verify --deep --strict "$destination"
printf 'Built %s\n' "$destination"
