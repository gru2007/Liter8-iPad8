#!/bin/sh
# Build the app-side exception-port guard for both device ABIs.
#
#   ./build.sh        l8excport.dylib for /var/jb/usr/lib/TweakInject
#   ./build.sh test   host build of the same source plus the control and shim runs
#
# L8EXCPORT_OUT overrides where the device dylib is written.

set -eu
BASE="$(cd "$(dirname "$0")" && pwd)"
CFLAGS="-O2 -Wall -Wextra -Werror -fvisibility=hidden"

if [ "${1:-}" = test ]; then
    WORK=$(mktemp -d "${TMPDIR:-/tmp}/l8excport-test.XXXXXX")
    trap 'rm -rf "$WORK"' EXIT
    # shellcheck disable=SC2086  # $CFLAGS is an option list
    xcrun clang $CFLAGS -dynamiclib -framework CoreFoundation -framework Security \
        -o "$WORK/l8excport_host.dylib" "$BASE/l8excport.c"
    # shellcheck disable=SC2086
    xcrun clang $CFLAGS -o "$WORK/test_l8excport" "$BASE/test_l8excport.c"
    "$WORK/test_l8excport"
    "$WORK/test_l8excport" "$WORK/l8excport_host.dylib"
    exit 0
fi

TOOLS="$BASE/../../tools"
LDID="$TOOLS/ldid_macosx_arm64"
"$LDID" -v 2>&1 | grep -q "Link Identity Editor" || LDID=$(command -v ldid || true)
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
OUT="${L8EXCPORT_OUT:-$BASE/l8excport.dylib}"

"$LDID" -v 2>&1 | grep -q "Link Identity Editor" \
    || { echo "[!] ldid at $LDID cannot run here; brew install ldid-procursus" >&2; exit 1; }

for arch in arm64 arm64e; do
    # shellcheck disable=SC2086
    xcrun -sdk iphoneos clang -arch "$arch" -miphoneos-version-min=15.0 \
        -isysroot "$SDK" -dynamiclib $CFLAGS \
        -install_name /var/jb/usr/lib/TweakInject/l8excport.dylib \
        -framework CoreFoundation -framework Security \
        -o "$OUT.$arch" "$BASE/l8excport.c"
done

lipo -create "$OUT.arm64" "$OUT.arm64e" -output "$OUT"
rm -f "$OUT.arm64" "$OUT.arm64e"
"$LDID" -S -Cadhoc "$OUT"

archs=$(lipo -archs "$OUT")
case " $archs " in *" arm64 "*) ;; *) echo "[!] missing arm64 slice" >&2; exit 1 ;; esac
case " $archs " in *" arm64e "*) ;; *) echo "[!] missing arm64e slice" >&2; exit 1 ;; esac
# Code patching dies with CODESIGNING / Invalid Page on this device, so the guard
# must not depend on a hooking library, and it must not interpose either: it is
# dlopen'ed by ElleKit, where dyld ignores __interpose.
if otool -L "$OUT" | grep -Eqi 'substrate|ellekit|libhooker'; then
    echo "[!] l8excport links a hooking library" >&2; exit 1
fi
for arch in arm64 arm64e; do
    if otool -arch "$arch" -l "$OUT" | grep -q 'sectname __interpose'; then
        echo "[!] l8excport $arch has an __interpose section" >&2; exit 1
    fi
done
[ -z "$("$LDID" -e "$OUT")" ] \
    || { echo "[!] l8excport unexpectedly carries entitlements" >&2; exit 1; }
plutil -lint "$BASE/l8excport.plist" >/dev/null \
    || { echo "[!] l8excport.plist is not a valid filter" >&2; exit 1; }

echo "[+] $OUT ($archs, app exception-port guard)"
