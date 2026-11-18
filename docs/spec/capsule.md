# Capsules

> What one capsule is: states, numbering, network, files on disk, what a lease adds, and the guest
> contract.

## States

```
 frozen ──▶ refilling ──▶ thawed ──lease──▶ leased ──release──▶ stopping ──▶ refilling ──▶ …
              │   ▲         │
   3 failures ▼   │ retry   └── after a cold-boot fallback, idle ──▶ refreezing ──▶ refilling
            broken ┘            (backoff, as long as the bay runs)
```

| State | Meaning |
|---|---|
| frozen | Saved state on disk, no VM in memory (also between refill retries, and while the doctor gate is closed) |
| refilling | Restore (or cold boot) → readiness → rekey to the next lease id → lease key → 3 warm-up logins → pause |
| thawed | Restored and paused in RAM, ready to lease (counts against Apple's 2-VM limit) |
| leased | Resumed and handed to one lease |
| stopping | Released: host `stop()`, USB detached, lease files being deleted |
| refreezing | Frozen again in the background after a cold-boot fallback (manifest mismatch, failed restore, or a restored guest that didn't answer SSH twice in a row), keeping its identity and subnet |
| broken | Its last 3 refills failed (e.g. a taken vmnet subnet); the bay keeps retrying with backoff, and `doctor` shows "capsule N usable" failing |

A cold-boot fallback still serves leases; the refreeze runs one capsule at a time, only while the
capsule is idle and nobody waits, at most 3 tries.

## Shape

| Item | Spec |
|---|---|
| Per Mac | 2 capsules, numbered 0 and 1, both on the same image digest |
| Network | Capsule N: vmnet `10.77.N.0/24`, NAT66 off, guest IP pinned at `10.77.N.2` by the freeze, no port forward, pf anchor fences it off the host and LAN (IPv4; all IPv6 from vmnet bridges `bridge100`–`bridge199` is dropped) |
| Size | Set by the image: Xcode image 4 vCPU / 8 GB, plain image 4 vCPU / 4 GB |
| Identity | Own machine ID, MAC and aux storage per capsule; never shared or changed |

## Files

All data under `~/.cryo` (outside `~/Documents`, which vmnet refuses). The bay marks it
`.metadata_never_index`.

```
~/.cryo/                 ($CRYO_HOME when set)
  config.toml            bay config (bay.md)
  bay.sock               API socket (0600)        bay.lock     held by the running bay
  bay.log                the installed bay's output (cryo logs; one old copy in bay.log.1)
  bay-restarting         alert left by a bay that exited to restart
  next-lease             lease id counter         token        network listener token
  run/<pid>              locked by each cryo bay process that runs VMs (start-up cleanup)
  bin/cryo               the binary (scripts/build-bay.sh)
  ipsw/                  downloaded macOS restore images (cryo image build)
  empty-share/           the placeholder share while a capsule isn't leased
  images/<digest>/       base.asif (read-only golden base), hardware-model.bin, aux.img
                         (aux template), image.json, id_ed25519 (the bay's key for the cryo user)
  images/.build-<pid>/   a build in progress
  capsules/<N>/          aux.img, machine-id.bin, mac.txt, freeze.asif, state.vzstate, manifest.json
  capsules/.tmp-<kind>-N.<pid>/  a freeze, refreeze or use in progress; .tmp-old-N during the swap
  leases/<id>/           aux.img, overlay.asif, folder/ (the lease folder), cache.asif (if requested)
  caches/<name>.asif     per-project cache disks (APFS volume "Cache")
  .metadata_never_index  keeps Spotlight out
Client side (any machine running the CLI or MCP):
  ssh_config, ssh_config.lock   one Host block per lease (cryo setup includes it)
  keys/<id>, known_hosts/<id>   the lease's key and pinned host key
  lease-bays/<id>               which bay (CRYO_URL) the lease came from
CI (cryo ci): ci-state.json, ci.log, runner/ (actions/runner tarballs)
```

`manifest.json` records what the state was frozen with (image, CPUs, memory, MAC, network,
`vsock`, `inputs`, host fingerprint, file stamps) and is checked before every restore.
A capsule frozen with a vsock device (`vsock: true`) keeps it, since a saved state only restores
onto the same devices; new freezes have none.

## What a lease adds, and release

- **Overlay:** a fresh copy-on-write disk over base + freeze layer.
- **Lease folder:** swapped into the virtiofs share once, before the agent gets the lease; never
  changed while leased.
- **Cache disk (optional):** an APFS clone of `caches/<name>.asif`, hot-plugged as USB.
- **Release:** host `stop()` (never a guest shutdown), detach USB, delete `leases/<id>/`, refill.

## Guest contract (what every image provides)

| Item | Spec |
|---|---|
| User | `cryo`, SSH with key only, passwordless sudo (the VM is thrown away after each lease) |
| Bay access | The bay's own key for `cryo` (`images/<digest>/id_ed25519`); readiness, clock set and rekey all run over SSH. No guest daemon |
| Settings | Auto-login, no sleep, no automatic updates, Spotlight off |
| Freeze rule | Never freeze with a Simulator or other Metal-heavy app running |
| Lease folder | `/Volumes/My Shared Files` (macOS automount, nothing to configure) |
| Cache disk | `/Volumes/Cache` |
