#!/bin/sh
set -eu
cd "$(dirname "$0")"
SDK=${LITER8_IOS_SDK:-$HOME/theos/sdks/iPhoneOS16.5.sdk}
for name in icleaner-launch newterm-login; do
 xcrun clang -isysroot "$SDK" -arch arm64 -arch arm64e -miphoneos-version-min=15.0 -Wall -Wextra "$name.c" -o "$name"
 ../../tools/ldid_macosx_arm64 -S../spawnprobe/e_both.plist -Cadhoc "$name"
done
