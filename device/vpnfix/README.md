# Karing on the SEP-less iPad 8 port

The existing `l8localauth` fix permits the explicit no-passcode approval flow.
On iPad11,6 / 23H30, nehelper saved the VPN configuration successfully, but
karingService then received a sandbox denial reading its own App Group
`service.json` and reported that the file did not exist.

This separate repair issues a read/write sandbox extension for the existing
`group.com.nebula.karing` directory. Only karingService consumes it through
ElleKit. It does not change app entitlements, app binaries, metadata, persona,
or authentication results. The token stays on the device, root:mobile 0640.

From the repository on the Mac, with the iPad available on localhost:2222:

```
tools/karing-vpn apply
tools/karing-vpn status
tools/karing-vpn disable
```

Apply discovers the container from metadata, builds/signs the native payloads,
and installs them. It requires the existing Liter8/ElleKit injection to work.
The issuer rejects other models/builds. Disconnect and reconnect Karing after
applying; no device reboot or SpringBoard restart is needed.

Tokens last for the current boot. Repeat apply after a device reboot or Karing
reinstallation. Disable removes the activation marker; disconnect Karing to
terminate the extension and release its already consumed grant. Files remain
installed but inert, so re-enabling is reversible. This is a Karing repair,
not a general fix for missing personal persona or all VPN applications.

Verified 2026-10-07: `l8vpn: ... consumed=1 pid=6655`, followed by the primary
VPN session becoming connected at 19:10:30 and Karing clearing its prior file
error. The user confirmed VPN works. Tokens/configuration contents are never
included in the repository.
