#!/bin/sh
set -eu
cd "$(dirname "$0")"
. ../build_env.sh
xcrun clang -isysroot "$SDK" -arch arm64 -arch arm64e \
    -miphoneos-version-min=15.0 -O2 -Wall -Wextra -fobjc-arc -framework Foundation \
    eligibility.m -o eligibility
"$LDID" -Seligibility.plist -Icom.liter8.eligibility -Cadhoc eligibility

xcrun clang -isysroot "$SDK" -arch arm64 -arch arm64e \
    -miphoneos-version-min=15.0 -O2 -Wall -Wextra -fobjc-arc -framework Foundation \
    persist.m -o persist
"$LDID" -Seligibility.plist -Icom.liter8.eligibility.persist -Cadhoc persist
for binary in eligibility persist; do l8_no_task_allow "$binary"; done
echo "[+] eligibility, persist"

# Host test of the real writer against temporary plists, never device data.
if [ "$(uname)" = Darwin ]; then
    python3 test.py
fi
