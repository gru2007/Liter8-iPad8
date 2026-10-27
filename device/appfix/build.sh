#!/bin/sh
# Build the NewTerm login adapters. icleaner-launch.m is kept only as evidence
# of the failed proxy attempt and is deliberately not built; see README.md.
set -eu
cd "$(dirname "$0")"
. ../build_env.sh
for name in newterm-login newterm-helper; do
    xcrun clang -isysroot "$SDK" -arch arm64 -arch arm64e -miphoneos-version-min=15.0 \
        -Wall "$name.c" -o "$name"
    if [ "$name" = newterm-login ]; then
        # Spawns through persona 99, so it needs the bisected AMFI-safe set.
        "$LDID" -S../spawnprobe/e_both.plist -Cadhoc "$name"
    else
        "$LDID" -S -Cadhoc "$name"
    fi
    l8_no_task_allow "$name"
    echo "[+] $name"
done
