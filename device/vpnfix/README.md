# Karing on the SEP-less iPad 8 port

The existing `l8localauth` fix permits the explicit no-passcode approval flow.
On iPad11,6 / 23H30, nehelper saved the VPN configuration successfully, but
karingService then received a sandbox denial reading its own App Group
`service.json` and reported that the file did not exist.

This separate repair issues a read/write sandbox extension for the existing
`group.com.nebula.karing` directory. Only karingService consumes it through
ElleKit. It does not change app entitlements, app binaries, metadata, persona,
or authentication results. The token stays on the device, root:mobile 0640.

Provisioning installs the tweak, its filter and the issuer
(`/var/jb/usr/libexec/liter8/l8vpn-issue`) from `tweaks.list` and turns the
`vpn` switch on. Tokens last for the current boot, so `liter8 fw tweaks` finds
Karing's app group from its container metadata and issues a new grant after
every boot. It requires the Liter8/ElleKit injection, which the same command
enables. The issuer rejects other models/builds. Disconnect and reconnect
Karing afterwards. After reinstalling Karing, run `fw tweaks` again.

`python3 device/liter8_tweaks.py disable vpn` removes the activation marker; disconnect Karing to
terminate the extension and release its already consumed grant. Files remain
installed but inert, so re-enabling is reversible. This is a Karing repair,
not a general fix for missing personal persona or all VPN applications.

Verified 2026-10-07: `l8vpn: ... consumed=1 pid=6655`, followed by the primary
VPN session becoming connected at 19:10:30 and Karing clearing its prior file
error. The user confirmed VPN works. Tokens/configuration contents are never
included in the repository.
