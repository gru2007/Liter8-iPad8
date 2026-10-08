#!/bin/sh
set -eu
cd "$(dirname "$0")"
. ../build_env.sh
for name in issue l8vpn; do
    extra=""
    [ "$name" != l8vpn ] || extra="-dynamiclib -Wl,-not_for_dyld_shared_cache -install_name /var/jb/usr/lib/TweakInject/l8vpn.dylib"
    # extra is a fixed, source-controlled linker option set and must word-split.
    # shellcheck disable=SC2086
    xcrun clang -isysroot "$SDK" -arch arm64 -arch arm64e -miphoneos-version-min=15.0 \
        -O2 -Wall -Wextra $extra "$name.c" -o "$name.build"
    "$LDID" -S -Cadhoc "$name.build"
    l8_no_task_allow "$name.build"
done
mv issue.build issue
mv l8vpn.build l8vpn.dylib
echo "[+] issue, l8vpn.dylib"
