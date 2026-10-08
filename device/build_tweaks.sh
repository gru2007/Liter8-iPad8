#!/bin/sh
# build_tweaks.sh - build and stage every Data-volume payload in tweaks.list.
#
# Runs on the host. Each component's own build.sh compiles and signs it (and
# runs its host self-test where it has one); this script then copies exactly
# the files tweaks.list names into payload/tweaks/root, checks them, and writes
#
#   payload/tweaks/MANIFEST   <sha256> <mode> <device path> <staged path>
#   payload/tweaks/MARKERS    <name> <device path> <on|off>
#
# which is all sshrd_provision.sh `tweaks` and liter8_tweaks.py read. The set is
# published atomically, so a failed build never leaves a half-updated manifest.
#
# Needs no firmware: fetch_payloads.sh calls it during provisioning, and
# `liter8 fw tweaks` calls it again so a source change reaches a running device
# over SSH without another SSHRD trip.

set -eu
BASE="$(cd "$(dirname "$0")" && pwd)"
cd "$BASE"

LIST="$BASE/tweaks.list"
OUT="$BASE/payload/tweaks"
NEW="$BASE/payload/tweaks.new"

say() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
ok()  { printf '    [+] %s\n' "$1"; }
die() { printf '    [!] %s\n' "$1" >&2; exit 1; }

# Only the two record kinds, with exactly the expected fields. A typo here would
# otherwise surface as a missing file on the device.
entries() {
    sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "$LIST" | while read -r kind a b c d extra; do
        case "$kind" in
            file)
                [ -n "$d" ] && [ -z "$extra" ] || die "malformed file entry: $kind $a $b $c $d $extra"
                case "$c" in /var/jb/*) ;; *) die "$c is not under /var/jb" ;; esac
                case "$c" in *..*) die "$c contains .." ;; esac
                case "$d" in 0644|0755) ;; *) die "unexpected mode $d for $c" ;; esac
                printf 'file %s %s %s %s\n' "$a" "$b" "$c" "$d"
                ;;
            marker)
                [ -n "$c" ] && [ -z "$d" ] || die "malformed marker entry: $kind $a $b $c $d"
                case "$b" in /var/jb/.liter8-*) ;; *) die "marker $b must be /var/jb/.liter8-*" ;; esac
                case "$c" in on|off) ;; *) die "marker $a default must be on or off" ;; esac
                printf 'marker %s %s %s\n' "$a" "$b" "$c"
                ;;
            *) die "unknown tweaks.list record: $kind" ;;
        esac
    done
}

ENTRIES=$(entries) || exit 1
[ -n "$ENTRIES" ] || die "tweaks.list is empty"

say "build"
mkdir -p "$BASE/payload"
COMPONENTS=$(printf '%s\n' "$ENTRIES" | awk '$1 == "file" && !seen[$2]++ {print $2}')
for component in $COMPONENTS; do
    [ -f "$component/build.sh" ] || die "$component has no build.sh"
    if ( cd "$component" && sh ./build.sh >"$BASE/payload/.build-$component.log" 2>&1 ); then
        ok "$component"
    else
        sed 's/^/        /' "$BASE/payload/.build-$component.log" >&2
        die "$component build failed"
    fi
done

say "stage"
rm -rf "$NEW"
mkdir -p "$NEW/root"
: > "$NEW/MANIFEST"
: > "$NEW/MARKERS"
printf '%s\n' "$ENTRIES" | while read -r kind a b c d; do
    if [ "$kind" = marker ]; then
        printf '%s %s %s\n' "$a" "$b" "$c" >> "$NEW/MARKERS"
        continue
    fi
    source="$a/$b"
    staged="root/${c#/var/jb/}"
    [ -f "$source" ] || die "$a build did not produce $source"
    mkdir -p "$(dirname "$NEW/$staged")"
    cp "$source" "$NEW/$staged"
    case "$b" in
        *.plist)
            plutil -lint "$NEW/$staged" >/dev/null || die "$source is not a valid plist"
            ;;
        *)
            codesign -v "$NEW/$staged" || die "$source has an invalid signature"
            archs=$(lipo -archs "$NEW/$staged")
            case " $archs " in *" arm64 "*) ;; *) die "$source lacks arm64" ;; esac
            ;;
    esac
    sha=$(shasum -a 256 "$NEW/$staged" | awk '{print $1}')
    printf '%s %s %s %s\n' "$sha" "$d" "$c" "$staged" >> "$NEW/MANIFEST"
done

files=$(wc -l < "$NEW/MANIFEST" | tr -d ' ')
markers=$(wc -l < "$NEW/MARKERS" | tr -d ' ')
[ "$files" -gt 0 ] || die "no files staged"
rm -rf "$OUT.prev"
[ ! -d "$OUT" ] || mv "$OUT" "$OUT.prev"
mv "$NEW" "$OUT"
rm -rf "$OUT.prev"
ok "payload/tweaks: $files files, $markers switches"
