#!/bin/sh
# Build l8lsreg, the LaunchServices plug-in inspector used to diagnose Files'
# "On My iPad". Ad-hoc signed with uicache's entitlements (it uses the same
# LSApplicationWorkspace calls); no get-task-allow. See README.md.
set -e
cd "$(dirname "$0")"
LDID=../../tools/ldid_macosx_arm64
"$LDID" -v 2>&1 | grep -q "Link Identity Editor" || LDID=$(command -v ldid || true)
# Command Line Tools have no iPhoneOS SDK. Point LITER8_IOS_SDK at an
# unpacked one (for example Theos's) to build without Xcode.
SDK="${LITER8_IOS_SDK:-$(xcrun --sdk iphoneos --show-sdk-path)}"
[ -d "$SDK" ] || { echo "[!] iOS SDK missing: $SDK" >&2; exit 1; }

xcrun clang -isysroot "$SDK" -arch arm64 -arch arm64e \
    -miphoneos-version-min=15.0 -O2 -Wall -Wextra -fobjc-arc \
    -framework Foundation l8lsreg.m -o l8lsreg
"$LDID" -Icom.liter8.l8lsreg -Sl8lsreg.entitlements -Cadhoc l8lsreg
codesign -d --entitlements :- l8lsreg 2>/dev/null | grep -q get-task-allow \
    && { echo "[!] l8lsreg carries get-task-allow, AMFI will kill it"; exit 1; }
echo "[+] l8lsreg  $(wc -c < l8lsreg | tr -d ' ') bytes"

