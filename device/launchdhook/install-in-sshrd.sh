#!/bin/sh
# Run in SSHRD with System mounted at /mnt1 and Data at /mnt2.
# Supply the freshly built universal lhook.dylib as the only argument.
set -eu
src=${1:?usage: install-in-sshrd.sh /path/to/new/lhook.dylib}
[ -s "$src" ]
[ -f /mnt1/sbin/launchd ] && [ -f /mnt1/usr/lib/lhook ]
[ -d /mnt2/jb/usr/lib ]
mount | grep -q ' on /mnt1 '
mount | grep -q ' on /mnt2 '
backup="/mnt2/jb/var/backups/liter8-integrated-lhook-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$backup"
cp -p /mnt1/usr/lib/lhook "$backup/lhook"
for name in .lhook_enabled .lhook_scoped_enabled .lhook_scoped_debug .spawnbridge_enabled .spawnbridge_debug; do
    if [ -e "/mnt2/jb/$name" ]; then cp -p "/mnt2/jb/$name" "$backup/$name"; fi
done
if [ -e /mnt2/jb/usr/lib/Liter8SpawnBridge.dylib ]; then
    cp -p /mnt2/jb/usr/lib/Liter8SpawnBridge.dylib "$backup/Liter8SpawnBridge.dylib"
fi
# Replace atomically; keep the previous image and flags for offline rollback.
cp "$src" /mnt1/usr/lib/lhook.integrated-new
chown 0:0 /mnt1/usr/lib/lhook.integrated-new
chmod 755 /mnt1/usr/lib/lhook.integrated-new
cmp "$src" /mnt1/usr/lib/lhook.integrated-new
mv /mnt1/usr/lib/lhook.integrated-new /mnt1/usr/lib/lhook
rm -f /mnt2/jb/.lhook_scoped_enabled /mnt2/jb/.lhook_scoped_debug \
      /mnt2/jb/.spawnbridge_enabled /mnt2/jb/.spawnbridge_debug
if [ -e /mnt2/jb/usr/lib/Liter8SpawnBridge.dylib ]; then
    mv /mnt2/jb/usr/lib/Liter8SpawnBridge.dylib "$backup/Liter8SpawnBridge.removed.dylib"
fi
# Existing denylist stays intact except for the required xpcproxy transition.
if [ -f /mnt2/jb/etc/lhook.deny ]; then
    cp -p /mnt2/jb/etc/lhook.deny "$backup/lhook.deny"
    sed '/^[[:space:]]*xpcproxy[[:space:]]*$/d' /mnt2/jb/etc/lhook.deny > /mnt2/jb/etc/lhook.deny.new
    chmod 644 /mnt2/jb/etc/lhook.deny.new
    mv /mnt2/jb/etc/lhook.deny.new /mnt2/jb/etc/lhook.deny
fi
# First boot establishes SSH before enabling injection into new processes.
rm -f /mnt2/jb/.lhook_enabled
sync
printf 'Installed integrated lhook. Backup: %s\n' "$backup"
