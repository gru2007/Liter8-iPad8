# Files "On My iPad" on the SEP-less iPad 8 boot

Status: **not fixed.** Measured on iPad11,6 / iPadOS 26.7.1 `23H30`, 2026-10-07.
This records the cause and what was tried, so the next attempt starts here.

## Cause, from fileproviderd's own log

usermanagerd never created personas on this boot: the kernel persona table holds
only Liter8's persona 99, and `/private/var/keybags` has `usersession.kb` but no
`persona.kb`. fileproviderd then fails in a chain:

1. `personaAttributesForPersonaType for type:0/2/5 failed` (UserManagement).
2. `Failed gathering persona for role: 1 - failing volume init`, so
   `/dev/disk1s2` is "not eligible to store FP library": no domain database.
3. `Failed finding the default persona` / `Failed to adopt default persona`.
4. `Extension com.apple.FileProvider.LocalStorage has persona (null)` →
   `Extension without persona out of the EDU case, dropping ... registration`,
   so `providerDomainsCompletionHandler` returns 0 providers.

The LocalStorage extension itself **is** registered with LaunchServices
(`l8lsreg list fileprovider` shows it), and its app-group container exists, so
neither re-registration nor container creation is the fix.

## What was tried (tweak in fileproviderd only, marker-gated)

| Attempt | Result |
| --- | --- |
| Keep persona-less extensions (`-[FPDProviderDescriptor isPersonaLegit]` → YES) | 3 providers returned, but `state:disabled`, `db:(null)`; root lookup fails `NSFileProviderErrorDomain -2001/-2013`. Volume init (step 2) still fails. |
| `-[UMUserManager isSharedIPad]` → YES (the EDU branches) | **Crash loop**: fileproviderd enters the Shared iPad sync-bubble path and asserts (`FPDSyncBubble.m:38`). |
| Synthetic personal persona attributes (`UMUserPersonaAttributes`, type 0) | **Crash loop**: `[CRIT] One persona is unexpectedly nil: existing (null), requested <uuid>`. fileproviderd adopts the persona for real; a process with no kernel/voucher persona cannot. |

All three were removed from the device; fileproviderd returned to stock.

## What a real fix needs

A real personal persona: usermanagerd creating it (kernel persona plus its
manifest), so processes get a voucher persona and UserManagement answers type 0.
Client-side substitution stops at persona adoption. The install path has its own
working workaround (`device/personafix/l8persona`, `device/marketplacefix`).

## Tool

`l8lsreg list [substring]` prints registered plug-ins (identifier, extension
point, path); `framework <path>` and `plugin <path>` re-register through
LSApplicationWorkspace. Build with `device/filesfix/build.sh`.
