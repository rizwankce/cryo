# Bay

> How `cryo bay` runs on one Mac: process, start-up, lease rules, queue, lease inputs, caches and
> config. Capsules: [capsule.md](capsule.md). API: [api.md](api.md).

## Process

- One Swift process; each capsule's VM lives inside it (Virtualization.framework).
- A LaunchAgent in the logged-in user's session, `dev.cryo.bay` (`cryo bay install`): runs
  `cryo bay start` at login with `CRYO_HOME` set, restarts it when it exits non-zero (60 s
  throttle), writes stdout and stderr to `~/.cryo/bay.log`. It needs a logged-in GUI session.
- Logs: a timestamped trace (refills, leases, releases, failures) on stdout, so in `bay.log` for
  the installed bay (`cryo logs`), plus the unified log, subsystem `dev.cryo.bay`.
- Stop or restart the installed bay with `launchctl bootout gui/$(id -u)/dev.cryo.bay` or
  `launchctl kickstart -k gui/$(id -u)/dev.cryo.bay`; a foreground `cryo bay start` stops with
  Ctrl-C. A signal shuts the bay down before its VMs stop, so no refill thaws a VM meanwhile.
- The bay never runs as root and never runs `pfctl`. The root helper (LaunchDaemon `dev.cryo.pf`,
  installed by `cryo bay install`) loads the pf anchor and clears stale 10.77 DHCP bindings at
  every boot.
- **Network listener:** `cryo bay start --listen :7477` ([api.md](api.md)). The installed
  LaunchAgent doesn't pass `--listen`; run the bay by hand to use it.

## Start-up

1. Load `config.toml` and the image; refuse if a bay answers on `bay.sock` or holds `bay.lock`
   (the lock is held for the bay's whole life, so a second bay on the same root refuses).
2. Clean up after earlier processes of this root: delete dead `images/.build-*` folders, stop
   leftover VM processes (`cryo bay start|freeze|thaw-test|lease-test`, which lock `run/<pid>`)
   and wait for their VM services to exit, undo a freeze or `use` that crashed half way
   (`capsules/.tmp-*`). Leases of the last run end (`410 lease_lost`, folders deleted).
3. Doctor gate ([setup.md](setup.md)): while a check that blocks thawing fails, every capsule
   stays `frozen`, `blocked_by` is in status, and the host is re-checked every 30 s and on
   `/v1/doctor`, so a fixed host thaws without a restart. `ignore_doctor = true` skips the gate.
4. Start every capsule's refill (manifest check, restore, rekey; a mismatch cold boots and the
   capsule is refrozen in the background later), then bind the API socket at once: status
   answers and leases queue while the capsules thaw, so one slow capsule doesn't hide the other.

The bay doesn't free vmnet subnets: a subnet a SIGKILLed process left taken stays taken until
`sudo killall InternetSharing` or a reboot. When every capsule fails on a taken subnet and no VM
or lease is live, the bay exits 75 and launchd starts a fresh one a minute later, since a running
process doesn't pick the subnets up again. It leaves the alert in `~/.cryo/bay-restarting` for
`cryo status`.

**A bay restart or crash ends every lease.** VMs live in the bay process, so they stop with it;
clients get `lease_lost`, and the bay refills from saved state in seconds.

## Leases

| Rule | v1 |
|---|---|
| Keep-alive | Activity keeps a lease alive: a renew call or an open `cryo ssh` connection. Idle timeout 5 min for MCP, 60 min default for the CLI ([cli.md](cli.md)) |
| Maximum length | `max_lease_s` (24 h, never more), then released |
| Release | Host `stop()`, detach USB, delete the lease files, refill at once |
| Failed refill | Retried 3× 5 s apart, then `broken` and retried with backoff (30 s up to 10 min; 1 min for a taken subnet) for as long as the bay runs |
| Restore problems | Manifest mismatch or failed restore → cold boot serves the capsule, refrozen in the background. A restored guest that doesn't answer SSH twice in a row → cold boot and refreeze |

## Queue

First come, first served. The client says how long it waits (default `wait_default_s`, 10 min;
`--wait 0` fails at once). A client that hangs up gives up its place. No priorities in v1.

## Lease inputs

- **Folder:** `cryo lease --folder ./myrepo` → the bay makes an APFS clone (`cp -c`) into
  `leases/<id>/folder/`, so the agent's edits never touch the original. No flag → empty folder.
  Refused over the network listener.
- **Cache:** `--cache app` attaches a clone of `caches/app.asif` as `/Volumes/Cache`. Read-only by
  default: `--save-cache` on release replaces `caches/app.asif` with the lease's copy (atomic
  rename). No automatic promotion in v1.

## Config

One file, `~/.cryo/config.toml` (`cryo bay config` prints the effective values). Flat `key =
value`, `#` comments; a missing file or key keeps the default, an unknown key is an error.

| Key | Type | Default | Meaning |
|---|---|---|---|
| `image` | quoted string | none | Digest of the image the capsules run; set by `cryo image use` (or the first `cryo image build`) |
| `idle_timeout_s` | integer > 0 | 3600 | Idle timeout of a lease that doesn't send `idle_s` |
| `max_lease_s` | integer > 0 | 86400 | Maximum lease length (capped at 86400) |
| `wait_default_s` | integer > 0 | 600 | Queue wait of a request that doesn't send `wait_s` |
| `capsules` | integer 1–2 | 2 | Capsules on this Mac (Apple's limit is 2) |
| `ignore_doctor` | `true`/`false` | `false` | Thaw even when checks that block thawing fail (a dev Mac) |

Everything else is fixed by [capsule.md](capsule.md).
