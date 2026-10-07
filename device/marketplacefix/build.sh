#!/bin/sh
set -eu
cd "$(dirname "$0")"
if [ -n "${LITER8_IOS_SDK:-}" ]; then
    SDK=$LITER8_IOS_SDK
elif [ -d "$HOME/theos/sdks/iPhoneOS16.5.sdk" ]; then
    SDK="$HOME/theos/sdks/iPhoneOS16.5.sdk"
else
    SDK=$(xcrun --sdk iphoneos --show-sdk-path)
fi
xcrun clang -isysroot "$SDK" -arch arm64 -arch arm64e \
    -miphoneos-version-min=15.0 -O2 -Wall -Wextra -fobjc-arc -framework Foundation \
    eligibility.m -o eligibility
../../tools/ldid_macosx_arm64 -Seligibility.plist -Icom.liter8.eligibility -Cadhoc eligibility

xcrun clang -isysroot "$SDK" -arch arm64 -arch arm64e \
    -miphoneos-version-min=15.0 -O2 -Wall -Wextra -fobjc-arc -framework Foundation \
    persist.m -o persist
../../tools/ldid_macosx_arm64 -Seligibility.plist -Icom.liter8.eligibility.persist -Cadhoc persist
