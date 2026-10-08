#!/bin/sh
set -eu
cd "$(dirname "$0")"
. ../build_env.sh
xcrun clang -isysroot "$SDK" -arch arm64 -arch arm64e -miphoneos-version-min=15.0 \
    -dynamiclib -Wl,-not_for_dyld_shared_cache \
    -install_name /var/jb/usr/lib/TweakInject/l8rootapps.dylib \
    -framework Foundation -Wall l8rootapps.m -o l8rootapps.dylib
"$LDID" -S -Cadhoc l8rootapps.dylib
l8_no_task_allow l8rootapps.dylib
echo "[+] l8rootapps.dylib"
