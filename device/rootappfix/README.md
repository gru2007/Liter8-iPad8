# Native root GUI launch for iCleaner (iPad11,6 / 23H30)

The earlier parent/child adapter showed a black window: the registered parent
was an empty UIKit app, and the real root child's window had a different process
identity. Its process survival did not prove that the UI worked.

This tweak modifies only iCleaner's exact executable job to request UserName
root and GroupName wheel before RunningBoard submits it to launchd. The actual
original app then runs as root with its own registered RunningBoard identity;
there is no proxy window or second iCleaner process.

The ABI was inspected in the local 23H30 RunningBoard cache. Its job plist data
is an XPC dictionary, not NSDictionary. Three Objective-C methods are hooked:
RBLaunchdInterface jobWithPlist:domain:, jobWithPlist:, and RBLaunchdJobManager
_generateDataWithIdentity:context:actualIdentity:error:. The initial experiment
hooking only the first method was not invoked by this app's launch path.

## Deployment

- Restore iCleaner's original executable (`tools/app-launch apply` removes the
  failed proxy if its original `.liter8-real` backup exists).
- `tools/icleaner-root prepare` builds/signs and installs the tweak and filter.
- `tools/icleaner-root enable` creates a root-owned 0600 marker and removes only
  a stale iCleaner application job so a fresh launch can receive the new policy.
- The tweak must load in runningboardd. Installation on an already running daemon
  does not load it. A daemon restart or a live injection mechanism is necessary.
  The utility never restarts runningboardd or SpringBoard automatically.
- `tools/icleaner-root disable` removes the marker and stale iCleaner jobs.
  It closes a currently running iCleaner; other apps/daemons are untouched.

Build guard: iPad11,6, 23H30, euid 0. Filter: runningboardd only. Without marker,
new launch data passes through unchanged. Job UserName can persist in cached app
jobs, which is why enable/disable clear only this application's job.

## Verification, 2026-10-07

The owner explicitly approved restarting runningboardd for this experiment.
It was restarted, and SpringBoard retained PID 8786; no reboot occurred.
Logs showed all three hooks installed and iCleaner's original executable job
receiving root. Original iCleaner PID 10541 had uid 0, was registered as
app<com.ivanobilenchi.icleaner>, and remained alive beyond the previous 20-second
watchdog limit without a new crash report. This validates native launch and
process identity; the owner's confirmation of the visible UI is still pending.
No cleaning operation was run. These checks do not prove every cleanup option
safe or compatible with this experimental OS build.
