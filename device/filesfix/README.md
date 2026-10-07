# Local Files on the SEP-less iPad 8 boot

**Working local storage**, confirmed on iPad11,6 / iPadOS 26.7.1 `23H30`,
2026-10-07. VPN is a separate repair in `device/vpnfix`.

```
tools/files-local apply
tools/files-local status
tools/files-local disable
```

The Mac wrapper builds/signs the tweak, installs it through localhost:2222,
and restarts only FileProvider. It needs the existing ElleKit injection and
`/var/tmp/liter8-launchctl` helper. No device reboot or SpringBoard restart.
Apply watches the daemon and disables the marker if it repeatedly exits.
Disable restores stock behavior without deleting documents. Reopen Files
following either change. Both wrapper and payload reject other model/builds.

## Why this works

This boot has no personal persona: usermanagerd lists none, the kernel table
holds only Liter8's persona 99, and `persona.kb` is absent. FileProvider drops
persona-less extensions and cannot initialize its local volume database.
Merely preserving their registrations shows an unusable "On My iPad".

`l8files` provides a consistent process-local UserManagement view of the
already mounted single-user volume, only inside fileproviderd and
LocalStorageFileProvider. It does not allocate a kernel persona, alter keybags,
or enable Shared iPad. Existing successful attribute/current-persona results
are preserved; the fallback handles missing results.

The extension must launch without the fallback UUID: it is not a real kernel
persona. EXPersona's encoder reads the ivar directly, bypassing getter hooks.
The tweak therefore encodes an empty EXPersona for that one fallback UUID.
The extension receives the same local UM view after launch, so its persona
comparison with the host succeeds.

Only the LocalStorage provider is admitted while active. CloudDocs/iCloud and
Photos are excluded: their unmodified extensions cannot match the fallback
persona and would terminate fileproviderd. This repair does **not** establish
working iCloud Drive, real persona support, or the security properties of SEP.

## Verification

- Local volume `/dev/disk1s2` initialized.
- LocalStorage launched normally through ExtensionKit, with no kernel persona.
- Provider list returns LocalStorage enabled.
- `FPItemManager` root lookup succeeds with read/write capabilities.
- `FPCreateFolderOperation` created a unique test folder without error; the
  empty test folder was then removed.
- The user confirmed creating a folder in Files works.

## Earlier unsuccessful attempts

Keeping persona-less descriptors alone left disabled providers and no DB.
Claiming Shared iPad caused a sync-bubble assertion. Fallback attributes alone
caused `FPPerformWithPersona` to assert because current persona was missing.
Allowing all providers after the local workaround caused CloudDocs to report
non-matching personas and shut down the daemon. None is a standalone fix.

`l8lsreg list [substring]` remains available for read-only plug-in inspection.
