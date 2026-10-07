#!/bin/sh
set -eu
cd "$(dirname "$0")"
SDK=${LITER8_IOS_SDK:-$(xcrun --sdk iphoneos --show-sdk-path)}
xcrun clang -isysroot "$SDK" -arch arm64 -arch arm64e \
    -miphoneos-version-min=15.0 -O2 -Wall -Wextra -fobjc-arc -framework Foundation \
    eligibility.m -o eligibility
../../tools/ldid_macosx_arm64 -Seligibility.plist -Icom.liter8.eligibility -Cadhoc eligibility
