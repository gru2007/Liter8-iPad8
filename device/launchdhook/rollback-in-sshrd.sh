#!/bin/sh
set -eu
backup=${1:?usage: rollback-in-sshrd.sh /mnt2/jb/var/backups/liter8-integrated-lhook-TIMESTAMP}
[ -f "$backup/lhook" ] && [ -f /mnt1/sbin/launchd ]
mount | grep -q ' on /mnt1 '
mount | grep -q ' on /mnt2 '
cp -p "$backup/lhook" /mnt1/usr/lib/lhook.rollback
mv /mnt1/usr/lib/lhook.rollback /mnt1/usr/lib/lhook
for name in .lhook_enabled .lhook_scoped_enabled .lhook_scoped_debug .spawnbridge_enabled .spawnbridge_debug; do
    rm -f "/mnt2/jb/$name"
    if [ -e "$backup/$name" ]; then cp -p "$backup/$name" "/mnt2/jb/$name"; fi
done
if [ -f "$backup/Liter8SpawnBridge.dylib" ]; then
    cp -p "$backup/Liter8SpawnBridge.dylib" /mnt2/jb/usr/lib/Liter8SpawnBridge.dylib
fi
if [ -f "$backup/lhook.deny" ]; then cp -p "$backup/lhook.deny" /mnt2/jb/etc/lhook.deny; fi
sync
printf 'Restored previous lhook and flags from %s\n' "$backup"
