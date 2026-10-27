#!/bin/sh
# Build l8files, the local Files compatibility tweak, and l8lsreg, the
# LaunchServices plug-in inspector used to diagnose Files' "On My iPad".
# l8lsreg is ad-hoc signed with uicache's entitlements (it uses the same
# LSApplicationWorkspace calls); no get-task-allow. See README.md.
set -eu
cd "$(dirname "$0")"
. ../build_env.sh

xcrun clang -isysroot "$SDK" -arch arm64 -arch arm64e \
    -miphoneos-version-min=15.0 -O2 -Wall -Wextra -fobjc-arc \
    -framework Foundation l8lsreg.m -o l8lsreg
"$LDID" -Icom.liter8.l8lsreg -Sl8lsreg.entitlements -Cadhoc l8lsreg
l8_no_task_allow l8lsreg
echo "[+] l8lsreg  $(wc -c < l8lsreg | tr -d ' ') bytes"

xcrun clang -isysroot "$SDK" -arch arm64 -arch arm64e \
    -miphoneos-version-min=15.0 -O2 -Wall -Wextra -fobjc-arc -dynamiclib \
    -Wl,-not_for_dyld_shared_cache -install_name /var/jb/usr/lib/TweakInject/l8files.dylib \
    -framework Foundation l8files.m -o l8files.dylib
"$LDID" -S -Cadhoc l8files.dylib
l8_no_task_allow l8files.dylib
echo "[+] l8files.dylib  $(wc -c < l8files.dylib | tr -d ' ') bytes"
