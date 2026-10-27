#!/bin/sh
# Build the MobileGestalt cache and sharingd preference writer. It claims only
# the storage entitlement and system group Apple's MobileGestaltHelper has.
set -eu
cd "$(dirname "$0")"
. ../build_env.sh
xcrun clang -isysroot "$SDK" -arch arm64 -arch arm64e -miphoneos-version-min=15.0 \
    -framework Foundation prefs.m -o prefs
"$LDID" -Sentitlements.plist -Icom.liter8.deviceprefs -Cadhoc prefs
l8_no_task_allow prefs
echo "[+] prefs"
