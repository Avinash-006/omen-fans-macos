#!/bin/bash
set -euo pipefail
source_dir=$(cd "$(dirname "$0")" && pwd)
output_dir=${1:-"$source_dir/dist"}
sdk=$(xcrun --sdk macosx --show-sdk-path)
kernel_headers="$sdk/System/Library/Frameworks/Kernel.framework/Headers"
app="$output_dir/OMEN Fans.app"
bridge="$output_dir/OmenFanBridge.kext"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$bridge/Contents/MacOS"
cp "$source_dir/App-Info.plist" "$app/Contents/Info.plist"
cp "$source_dir/Bridge-Info.plist" "$bridge/Contents/Info.plist"
object_dir=$(mktemp -d)
trap 'rm -rf "$object_dir"' EXIT
clang++ -arch x86_64 -std=c++17 -mmacosx-version-min=26.5 -O2 -mkernel -fapple-kext \
    -fno-exceptions -fno-rtti -fno-stack-protector -nostdinc -DKERNEL \
    -isystem "$(clang -print-resource-dir)/include" -isystem "$kernel_headers" \
    -Wall -Wextra -Werror -c "$source_dir/OmenFanBridge.cpp" -o "$object_dir/bridge.o"
clang++ -arch x86_64 -mmacosx-version-min=26.5 -nostdlib -Wl,-kext \
    "$object_dir/bridge.o" "$sdk/usr/lib/libkmodc++.a" "$sdk/usr/lib/libkmod.a" \
    -o "$bridge/Contents/MacOS/OmenFanBridge"
clang -arch x86_64 -isysroot "$sdk" -mmacosx-version-min=15.0 -Wall -Wextra -Werror \
    -c "$source_dir/Sensors.c" -o "$object_dir/sensors.o"
swiftc -import-objc-header "$source_dir/Sensors.h" -sdk "$sdk" -target x86_64-apple-macos15.0 -O -warnings-as-errors \
    "$source_dir/OmenFans.swift" "$object_dir/sensors.o" -framework IOKit -o "$app/Contents/MacOS/OmenFans"
swift "$source_dir/MakeIcon.swift" "$object_dir/OmenFans.iconset"
iconutil --convert icns --output "$app/Contents/Resources/OmenFans.icns" "$object_dir/OmenFans.iconset"
codesign --force --sign - "$app"
