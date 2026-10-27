#!/bin/sh
# Build csprobe, the self-modifying-code test. Ad-hoc signed with no
# get-task-allow, like the other diagnostics: AMFI SIGKILLs an ad-hoc binary
# carrying it. csprobe needs no special entitlement, because the whole point is
# to measure what a stock process is allowed to do.
set -e
cd "$(dirname "$0")"
LDID=../../tools/ldid_macosx_arm64
"$LDID" -v 2>&1 | grep -q "Link Identity Editor" || LDID=$(command -v ldid || true)
# Command Line Tools have no iPhoneOS SDK. Point LITER8_IOS_SDK at an
# unpacked one (for example Theos's) to build without Xcode.
SDK="${LITER8_IOS_SDK:-$(xcrun --sdk iphoneos --show-sdk-path)}"
[ -d "$SDK" ] || { echo "[!] iOS SDK missing: $SDK" >&2; exit 1; }

xcrun clang -isysroot "$SDK" -arch arm64 -arch arm64e \
    -miphoneos-version-min=15.0 -O0 -Wall -Wextra csprobe.c -o csprobe
"$LDID" -S -Icom.liter8.csprobe -Cadhoc csprobe
codesign -d --entitlements :- csprobe 2>/dev/null | grep -q get-task-allow \
    && { echo "[!] csprobe carries get-task-allow, AMFI will kill it"; exit 1; }
echo "[+] csprobe  $(wc -c < csprobe | tr -d ' ') bytes"
