#!/bin/sh
# Build personainfo, the read-only persona/session diagnostic, and l8persona,
# the install-path persona fallback tweak (runs its host self-test first).
# Ad-hoc signed, no get-task-allow (AMFI SIGKILLs an ad-hoc binary carrying
# it), no entitlements.
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

# Self-test on the host first, with stand-in classes (macOS ships classes of
# the same names, so the test names its own).
if command -v clang >/dev/null 2>&1 && [ "$(uname)" = Darwin ]; then
    marker="$(mktemp -u /tmp/l8persona-marker.XXXXXX)"
    clang -DLITER8_PERSONA_TEST -DL8_PERSONA_MARKER="\"$marker\"" \
        -DL8_PERSONA_OWNER="getuid()" -DL8_IDENTITY_CLASS='"L8TestAppIdentity"' \
        -DL8_USERMGMT_CLASS='"L8TestUserManagement"' \
        -DL8_PRIMARY_SYMBOL='"L8TestPrimaryPersona"' \
        -framework Foundation l8persona.m -o .l8persona-test
    ./.l8persona-test
    rm -f .l8persona-test "$marker"
fi

xcrun clang -isysroot "$SDK" -arch arm64 -arch arm64e \
    -miphoneos-version-min=15.0 -O2 -Wall -Wextra -dynamiclib \
    -Wl,-not_for_dyld_shared_cache -install_name /var/jb/usr/lib/TweakInject/l8persona.dylib \
    -framework Foundation l8persona.m -o l8persona.dylib
"$LDID" -Icom.liter8.l8persona -Cadhoc l8persona.dylib
codesign -d --entitlements :- l8persona.dylib 2>/dev/null | grep -q get-task-allow \
    && { echo "[!] l8persona carries get-task-allow, AMFI will kill it"; exit 1; }
echo "[+] l8persona.dylib  $(wc -c < l8persona.dylib | tr -d ' ') bytes"
