# Host setup

> From a new Mac to the first lease: install, `cryo doctor`, what `--fix` may change, and stopping
> the bay. Images: [image.md](image.md).

## Flow

```
brew install rizwankce/tap/cryo   (or from a checkout: scripts/install.sh, which builds and
                                   signs cryo into ~/.cryo/bin, then runs the next step)
cryo bay install                  one command, one sudo prompt:
   ├ creates ~/.cryo + config.toml, marks it no-Spotlight
   ├ installs the root helper (at every boot: loads pf, clears stale 10.77 DHCP bindings)
   ├ installs the LaunchAgent dev.rizwan.cryo.bay (bay starts at login) and loads it
   └ runs cryo doctor (fix what fails with `cryo doctor --fix` and the hints)
                                  (cryo bay uninstall: removes both, keeps ~/.cryo)
cryo image build --xcode          builds a golden image (image.md)
cryo image use <digest>           freezes both capsules from it
                                  (until an image is set the bay exits at start and launchd
                                   retries every minute, so it comes up on the image by itself)
cryo lease
```

## `cryo doctor`

The bay runs it at start and won't thaw until the checks that block thawing pass ([bay.md](bay.md)).
With no bay running, `cryo doctor` reads the host itself (14 checks, no root).

| Check | `--fix` | Blocks thawing |
|---|---|---|
| macOS 27.x | — (reports) | yes |
| Apple silicon | — (reports) | yes |
| ≥150 GB free | — (reports) | no |
| RAM for the capsules × image RAM + 4 GB host | — (reports; or `capsules = 1`) | yes |
| Binary not under `~/Documents`, `~/Desktop` or `~/Downloads` (vmnet refuses it there) | — (hint: `scripts/build-bay.sh`) | yes |
| `~/.cryo` excluded from Spotlight | fixes, no sudo | no |
| Sleep and display sleep off, `pmset autorestart 1` | fixes (sudo) | no |
| Automatic macOS updates off | fixes (sudo) | no |
| pf root helper installed | — (hint: `cryo bay install`) | no |
| No DHCP bindings on capsule subnets | guides (kickstart the helper) | no |
| Console owned by this user | — (reports) | yes |
| Screen unlocked | — (reports) | yes |
| Auto-login set to this user | — (guides to System Settings) | no |
| FileVault off | — (guides; decrypting takes hours, so it's your call) | no |

### Which checks block thawing

A check blocks when a thaw *now* would fail or the Mac can't run the capsules: wrong macOS or
CPU, too little RAM for the configured capsules, a binary vmnet refuses, or no unlocked console
session (restores fail without one). The rest keep a host healthy over time or across a reboot
(sleep, updates, auto-login, FileVault, Spotlight, disk space) and the bay works without them,
so they only make `doctor` say `failing`. The pf check only sees the helper's plist (the anchor
needs root to read), so it reports only. To check the fence itself, run
`scripts/check-fence.sh <lease-id>` against a lease.

A running bay adds checks of its own, also report-only: `image <digest> present` (or `image
configured`), and per capsule `capsule N saved state matches` (the thaw's own manifest rule) and
`capsule N usable` (not `broken`, not stuck on a taken subnet), then `host accepts VMs` (no VM-count
leak).

While blocked, the bay serves the API with every capsule `frozen`: `/v1/status` says `doctor:
"failing"` and lists the blocking checks in `bay.blocked_by`, and a lease request fails at once
with `no_capacity` naming them. It re-reads the host every 30 s and on every `/v1/doctor` (so
`cryo doctor` after a fix thaws at once). Once the checks pass it refills, and the gate stays
open until the bay restarts: a later screen lock only fails refills (thawed capsules still lease).

**Escape hatch:** `ignore_doctor = true` in `~/.cryo/config.toml` thaws whatever the checks say
(a dev Mac that isn't set up as a host). The checks still run and report; the bay logs what it ignored.

**`--fix` only changes safe, reversible system settings.** It never touches FileVault or the
auto-login password, and never writes `/etc/kcpassword`.

## Stopping and restarting the bay

The installed bay is the LaunchAgent `dev.rizwan.cryo.bay`; stopping it ends every lease.

| To | Run |
|---|---|
| Stop it | `launchctl bootout gui/$(id -u)/dev.rizwan.cryo.bay` |
| Restart it | `launchctl kickstart -k gui/$(id -u)/dev.rizwan.cryo.bay` |
| Start it again after a stop | `cryo bay install` (or `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/dev.rizwan.cryo.bay.plist`) |
| See what it did | `cryo logs` (`-f` to follow), `cryo status` |

A bay started by hand with `cryo bay start` stops with Ctrl-C. `cryo image use` and `cryo bay
freeze` refuse while a bay runs and print the stop command; stop it before `cryo image build` too
(Apple allows 2 VMs per Mac), and start it again after.
