#!/bin/sh
# Scoped, opt-in Telegram self-process decryption diagnostic.
set -eu
cd "$(dirname "$0")"
case "${1:-}" in
    install)
        sh build.sh
        COPYFILE_DISABLE=1 tar -cf - l8selfdump.dylib l8selfdump.plist |
            ../../tools/sshdev 'tar -xof - -C /var/jb/usr/lib/TweakInject && chmod 0644 /var/jb/usr/lib/TweakInject/l8selfdump.*'
        ;;
    enable)
        ../../tools/sshdev 'touch /var/jb/.liter8-selfdump-telegram; chmod 0644 /var/jb/.liter8-selfdump-telegram'
        echo 'Close and reopen Telegram. Output: its Documents/Liter8Decrypted/Telegram.app.'
        ;;
    disable)
        ../../tools/sshdev 'rm -f /var/jb/.liter8-selfdump-telegram'
        ;;
    remove)
        ../../tools/sshdev 'rm -f /var/jb/.liter8-selfdump-telegram /var/jb/usr/lib/TweakInject/l8selfdump.dylib /var/jb/usr/lib/TweakInject/l8selfdump.plist'
        ;;
    *) echo 'usage: selfdump.sh install|enable|disable|remove' >&2; exit 2 ;;
esac
