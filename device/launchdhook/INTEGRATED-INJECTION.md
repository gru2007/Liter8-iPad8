# Integrated Liter8 injection — 2026-10-03

Status: built and tested in standalone processes on iPad11,6 / 23H30.
Not installed in System yet. MarketplaceEnabler is not verified working.

## Design

`launchd -> lhook -> xpcproxy -> lhook -> target -> lhook -> ElleKit`

Only `/usr/lib/lhook` is inserted by dyld. The child environment also carries a
boot-specific read-only sandbox extension for `/private/var/jb`. The constructor
consumes it inside the new process before loading TweakLoader using dlopen.
PID 1 and xpcproxy never load tweaks. No SpawnBridge or separate Stage0 is required.
The historical icon helper can remain installed but is no longer injected here.

Enable switch: `/var/jb/.lhook_enabled`. Removing it stops further propagation;
already-loaded tweaks stay in memory until their host exits. Denied children have
Liter8 insertion paths and its token stripped; unrelated insertion paths survive.
The inherited token is a fallback when a sandboxed parent cannot issue a fresh one.
Tokens must never be printed to logs.

## Observed checks

- Universal arm64 + arm64e build and existing dependency checks passed.
- On-device environment regression: enable/disable, duplicate environment keys,
  preservation of unrelated libraries, pointer ownership, hard denylist: PASS.
- Standalone ordinary spawn: parent rc=0, child PASS.
- Standalone SETEXEC: child PASS without recursion/crash.
- Embedded `temporary-sandbox` test: before grant read=0 errno=1;
  `liter8_load_tweaks()` returned 1; after grant read=1; exit=0.
  This checks real ElleKit loading in a sandbox, not native daemon compatibility.

Build: set LITER8_IOS_SDK to an installed iPhoneOS SDK and run `sh build.sh`.
Test sources: environment-test.c and sandbox-test.c. The latter requires an
embedded temporary-sandbox entitlement and a current boot read-extension passed
in LITER8_SANDBOX_READ_TOKEN. It must run as a standalone process.

## Installation and rollback

Transfer lhook.dylib and install-in-sshrd.sh into SSHRD. With System mounted at
/mnt1 and Data at /mnt2, run `sh install-in-sshrd.sh /path/to/lhook.dylib`.
The script requires both mounts, backs up the current hook and flags under
/mnt2/jb/var/backups, removes SpawnBridge from its active path, and starts disabled.
No repartitioning, data erase, firmware restore or kernel replacement is performed.

After normal boot and SSH verification, create /var/jb/.lhook_enabled and restart
managedappdistributiond and appstorecomponentsd in user/foreground. Verify mapped
ElleKit and tweak images and service survival before restarting UI processes.
For rollback in SSHRD run rollback-in-sshrd.sh with the printed backup directory.

## Still outstanding

Native daemon loading, UI process compatibility, and actual MarketplaceEnabler
behavior require the System-volume installation. Separate C-hook executable-memory
restrictions remain; this userland change does not repair kernel permissions.
Files, Karing VPN and CocoaTop are not fixed by this result. No public release made.
