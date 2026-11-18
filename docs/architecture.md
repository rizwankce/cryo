# Architecture

> How the bay, CLI, MCP server and capsules fit together on one Mac, and one lease end to end.
> Words: [glossary.md](glossary.md).

## One Mac

```
 ┌──────────────────────────────── Mac (macOS 27 host) ─────────────────────────────────┐
 │                                                                                      │
 │  Agent (any MCP client)                You / scripts / CI                            │
 │      │  MCP: lease, renew, release       │  cryo lease / release / ls / status       │
 │      ▼                                   ▼                                           │
 │  ┌──────────────┐                 ┌──────────────┐                                   │
 │  │  cryo mcp    │                 │   cryo CLI   │   same `cryo` binary, no VM logic │
 │  └──────┬───────┘                 └──────┬───────┘                                   │
 │         └──────────────┬─────────────────┘                                           │
 │                        │  local API (unix socket, or HTTP with --listen)             │
 │                        ▼                                                             │
 │  ┌──────────────────────────────── cryo bay (launchd) ────────────────────────────┐  │
 │  │  lease queue + renewals · capsule manager · refill · doctor gate               │  │
 │  │  cold-boot fallback · cleanup after crash   (root helper loads pf at boot)     │  │
 │  └──────┬─────────────────────────────────────────────┬───────────────────────────┘  │
 │         │ Virtualization.framework (max 2 VMs)        │                              │
 │         ▼                                             ▼                              │
 │  ┌───────── capsule 0 ──────────┐             ┌───────── capsule 1 ──────────┐       │
 │  │ macOS VM, thawed (paused)    │             │ macOS VM, thawed (paused)    │       │
 │  │ net 10.77.0.0/24, guest .2   │             │ net 10.77.1.0/24, guest .2   │       │
 │  │ SSH ──── readiness + clock   │             │ SSH                          │       │
 │  │ share ── lease folder        │             │ share                        │       │
 │  │ USB  ─── cache disk          │             │ USB                          │       │
 │  └──────────────────────────────┘             └──────────────────────────────┘       │
 │                                                                                      │
 │  Disk, per image:                                                                    │
 │   golden base (read-only, ~56 GB with Xcode, shared by all capsules of an image)     │
 │     ├─ capsule 0: freeze layer + saved state ── lease overlay (deleted on release)   │
 │     └─ capsule 1: freeze layer + saved state ── lease overlay (deleted on release)   │
 │   caches/<name>.asif ── cloned per lease ── USB disk                                 │
 └──────────────────────────────────────────────────────────────────────────────────────┘
          ▲
          │  ssh cryo-L81 → ProxyCommand `cryo ssh L81` → /v1/leases/L81/connect → capsule sshd
          │  (per-lease key; the agent never sees the capsule's IP)
```

## Several Macs

```
 clients ── CRYO_URL=http://deck.lan:7400 ──▶ cryo deck ──┬──▶ bay on mini-1 (2 capsules)
 (CLI, MCP, CI)                               (any Mac or   ├──▶ bay on mini-2 (2 capsules)
                                               Linux box)   └──▶ bay on studio (2 capsules)
```

The deck serves the same `/v1` API, picks a bay with a free capsule (queuing when none is free),
and relays `ssh`. Its leases are `D<n>` and live in its memory only. Each bay works as above. [spec/deck.md](spec/deck.md).

## One lease

```
 agent           cryo mcp/CLI        bay                            capsule 0
   │  lease()        │                  │                                │
   │────────────────▶│ POST /v1/leases  │                                │
   │                 │─────────────────▶│  pick a thawed capsule (or queue)
   │                 │                  │  resume ──────────────────────▶│ (refilled, paused)
   │                 │                  │◀── SSH login: ready + clock ───│
   │                 │                  │  swap share → lease folder     │
   │                 │                  │  hot-plug cache USB disk       │
   │                 │◀─ {id, ssh: key, │                                │   well under a second
   │◀────────────────│  host_key,config}│                                │
   │                                                                     │
   │ ssh / xcodebuild / simulator ──────────────────────────────────────▶│ (renewed while alive)
   │                                                                     │
   │  release(id) ──▶ bay:  stop VM · detach USB · delete the lease files
   │                        refill: restore → resume → rekey + next lease key → warm-up → pause
   │                        (off the lease clock; capsule thawed again)
```

## Who does what

- **Agent:** asks for a Mac through MCP or the CLI, gets a lease id, a per-lease key and an
  `ssh_config` entry (`ssh cryo-<id>`), works over SSH through the bay. Never sees the capsule's
  IP, never touches the host.
- **CLI / MCP:** translate calls to the bay's socket; keep only the lease keys and `ssh_config`
  in `~/.cryo`. `CRYO_URL` picks the bay.
- **Bay:** the only process that touches VMs. Keeps two capsules thawed, leases, renews, releases,
  refills; refuses to thaw until `cryo doctor` passes.
- **Capsules:** own identity, saved state and network over the shared golden base; lease writes
  go to an overlay that's deleted on release; one lease folder per lease; caches on USB.
