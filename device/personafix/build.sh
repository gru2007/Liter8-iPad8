#!/bin/sh
# Build personainfo, the read-only persona/session diagnostic. Ad-hoc signed,
# no get-task-allow (AMFI SIGKILLs an ad-hoc binary carrying it). It reads
# state only, so it needs no entitlement.
set -e
cd "$(dirname "$0")"
LDID=../../tools/ldid_macosx_arm64
"$LDID" -v 2>&1 | grep -q "Link Identity Editor" || LDID=$(command -v ldid || true)
# Command Line Tools have no iPhoneOS SDK. Point LITER8_IOS_SDK at an
# unpacked one (for example Theos's) to build without Xcode.
SDK="${LITER8_IOS_SDK:-$(xcrun --sdk iphoneos --show-sdk-path)}"
[ -d "$SDK" ] || { echo "[!] iOS SDK missing: $SDK" >&2; exit 1; }

xcrun clang -isysroot "$SDK" -arch arm64 -arch arm64e \
    -miphoneos-version-min=15.0 -O2 -Wall -Wextra personainfo.c -o personainfo
"$LDID" -Icom.liter8.personainfo -Cadhoc personainfo
codesign -d --entitlements :- personainfo 2>/dev/null | grep -q get-task-allow \
    && { echo "[!] personainfo carries get-task-allow, AMFI will kill it"; exit 1; }
echo "[+] personainfo  $(wc -c < personainfo | tr -d ' ') bytes"
