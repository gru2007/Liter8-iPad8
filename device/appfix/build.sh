#!/bin/sh
set -eu
cd "$(dirname "$0")"
SDK=${LITER8_IOS_SDK:-$HOME/theos/sdks/iPhoneOS16.5.sdk}
for name in newterm-login newterm-helper; do
 source="$name.c"
 frameworks=""

 xcrun clang -isysroot "$SDK" -arch arm64 -arch arm64e -miphoneos-version-min=15.0 -Wall "$source" $frameworks -o "$name"
 if [ "$name" = newterm-login ]; then ../../tools/ldid_macosx_arm64 -S../spawnprobe/e_both.plist -Cadhoc "$name"; else ../../tools/ldid_macosx_arm64 -S -Cadhoc "$name"; fi
done
