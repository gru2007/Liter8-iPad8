#!/bin/sh
set -eu
cd "$(dirname "$0")"
SDK=${LITER8_IOS_SDK:-$HOME/theos/sdks/iPhoneOS16.5.sdk}
xcrun clang -isysroot "$SDK" -arch arm64 -arch arm64e -miphoneos-version-min=15.0 \
    -O0 -Wall -Wextra taskprobe.c -o taskprobe
../../tools/ldid_macosx_arm64 -S -Icom.liter8.taskprobe -Cadhoc taskprobe
xcrun clang -isysroot "$SDK" -arch arm64 -arch arm64e -miphoneos-version-min=15.0 \
    -fobjc-arc -O2 -Wall -Wextra -dynamiclib -framework Foundation \
    -install_name /var/jb/usr/lib/TweakInject/l8selfdump.dylib l8selfdump.m -o l8selfdump.dylib
../../tools/ldid_macosx_arm64 -S -Cadhoc l8selfdump.dylib
