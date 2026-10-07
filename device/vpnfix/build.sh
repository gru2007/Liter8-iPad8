#!/bin/sh
set -eu
cd "$(dirname "$0")"
SDK=${LITER8_IOS_SDK:-$HOME/theos/sdks/iPhoneOS16.5.sdk}
for name in issue l8vpn; do
    extra=""
    [ "$name" != l8vpn ] || extra="-dynamiclib -Wl,-not_for_dyld_shared_cache -install_name /var/jb/usr/lib/TweakInject/l8vpn.dylib"
    xcrun clang -isysroot "$SDK" -arch arm64 -arch arm64e -miphoneos-version-min=15.0 -O2 -Wall -Wextra $extra "$name.c" -o "$name.build"
    ../../tools/ldid_macosx_arm64 -S -Cadhoc "$name.build"
done
mv issue.build issue
mv l8vpn.build l8vpn.dylib
