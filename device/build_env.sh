# build_env.sh - SDK and ldid selection shared by the Data-volume payload builds.
#
# Sourced, not executed. Sets SDK and LDID or exits with a reason.
#
# SDK: LITER8_IOS_SDK first, then the Xcode iPhoneOS SDK, then the Theos SDK the
# iPad 8 work was validated with. Command Line Tools alone have no iPhoneOS SDK.
# LDID: the bundled arm64 ldid, else the one on PATH (an Intel Mac cannot run
# the bundled copy). See https://github.com/Xplo8E/Liter8/issues/2.

L8_DEVICE_DIR="$(cd "$(dirname "$0")/.." && pwd)"

if [ -n "${LITER8_IOS_SDK:-}" ]; then
    SDK=$LITER8_IOS_SDK
elif SDK=$(xcrun --sdk iphoneos --show-sdk-path 2>/dev/null) && [ -d "$SDK" ]; then
    :
else
    SDK="$HOME/theos/sdks/iPhoneOS16.5.sdk"
fi
[ -d "$SDK" ] || { echo "[!] iOS SDK missing: $SDK (set LITER8_IOS_SDK)" >&2; exit 1; }

LDID="$L8_DEVICE_DIR/../tools/ldid_macosx_arm64"
"$LDID" -v 2>&1 | grep -q "Link Identity Editor" || LDID=$(command -v ldid || true)
"$LDID" -v 2>&1 | grep -q "Link Identity Editor" \
    || { echo "[!] no runnable ldid; brew install ldid-procursus" >&2; exit 1; }

# AMFI SIGKILLs an ad-hoc binary that carries get-task-allow.
l8_no_task_allow() {
    if "$LDID" -e "$1" 2>/dev/null | grep -q get-task-allow; then
        echo "[!] $1 carries get-task-allow, AMFI will kill it" >&2
        exit 1
    fi
}
