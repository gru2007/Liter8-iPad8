#!/bin/sh
set -eu
cd "$(dirname "$0")"
SDK=${LITER8_IOS_SDK:-$HOME/theos/sdks/iPhoneOS16.5.sdk}
xcrun clang -isysroot "$SDK" -arch arm64 -arch arm64e -miphoneos-version-min=15.0 -dynamiclib -framework Foundation -Wall l8rootapps.m -o l8rootapps.dylib
../../tools/ldid_macosx_arm64 -S -Cadhoc l8rootapps.dylib
