#!/bin/sh
# Build the scoped AppBundles writer that replaces only TrollDecrypt's executable.
set -eu
cd "$(dirname "$0")"
. ../build_env.sh
xcrun clang -isysroot "$SDK" -arch arm64 -arch arm64e -miphoneos-version-min=15.0 \
    -O2 -Wall -Wextra -Werror replace.c -o writer
"$LDID" -Swriter.entitlements -Icom.liter8.trollwrite -Cadhoc writer
l8_no_task_allow writer
echo "[+] writer"
