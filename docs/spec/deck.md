# Deck

> `cryo deck`: several Macs' bays behind one `/v1` endpoint, on your own network. Clients lease
> from the whole pool as if it were one bay. API: [api.md](api.md). One bay: [bay.md](bay.md).

## What it is

A deck is one process that knows your bays. It speaks the same `/v1` API as a bay, so the CLI, MCP
server and `cryo-ci` work against it unchanged. It runs on macOS or Linux, from the same `cryo`
binary. It holds no VMs itself.

```
  clients (Mac, Linux, CI, agents)       CRYO_URL=http://deck.lan:7400  CRYO_TOKEN=<deck token>
        │  /v1 API, same as one bay
        ▼
  cryo deck    queue · D-ids · round-robin · health poll · ssh relay
        │  HTTP + each bay's token
        ├──▶ mini-1   cryo bay --listen :7477    capsule 0, capsule 1
        ├──▶ mini-2   cryo bay --listen :7477    capsule 0, capsule 1
        └──▶ studio   cryo bay --listen :7477    capsule 0, capsule 1
```

## Setup

```
each Mac:       cryo bay install --listen :7477
                cryo bay token                                    prints the bay's token
deck machine:   cryo deck add mini-1 http://mini-1.lan:7477 <bay token>    (once per Mac)
                cryo deck token                                   prints the clients' token
                cryo deck start                                   or: cryo deck install --listen :7400
clients:        export CRYO_URL=http://deck.lan:7400 CRYO_TOKEN=<deck token>
                cryo lease                                        → D7 ready: ssh cryo-D7
```

`cryo deck add` asks the bay for `GET /v1/status` with that token and saves it only if it answers.
The deck machine can be one of the Macs, or any other Mac or Linux machine that reaches them.

## Commands

| Command | Does |
|---|---|
| `cryo deck add <name> <url> <token>` | Add a bay (checked first). Names use `a-z`, `0-9` and `-` |
| `cryo deck rm <name>` | Remove a bay |
| `cryo deck ls [--json]` | Bays: name, state, capsules (thawed / leased / other), image (first 12 characters), url. Asks each bay directly, so it works without a running deck |
| `cryo deck token [--rotate]` | Print the clients' token; created on first use, `--rotate` makes a new one |
| `cryo deck start [--listen :7400]` | Run the deck in this terminal (Ctrl-C stops it). It prints where it serves and points to `cryo deck token`; it never prints the token |
| `cryo deck install [--listen :7400]` | Run `cryo deck start` at login: LaunchAgent `dev.rizwan.cryo.deck` on macOS, systemd user unit `~/.config/systemd/user/cryo-deck.service` on Linux. `--listen` is saved as `listen` in `deck.toml`, so the service takes no arguments |
| `cryo deck uninstall` | Remove it; `~/.cryo` (`deck.toml`, `deck-token`) is kept |
| `cryo deck help` | Usage |

`cryo deck add` and `rm` edit `deck.toml`; a running deck reads it only at start, so restart it
after changing bays or rotating the token. When a deck answers on `deck.sock`, `add`, `rm` and
`token --rotate` print a reminder to restart it. Clients use the ordinary commands (`cryo lease`,
`cryo ls`, `cryo status`, `cryo doctor`). There is no `cryo deck doctor`: `cryo doctor` pointed at the
deck runs its checks (below).

## Files

Under `$CRYO_HOME`, else `~/.cryo`.

| File | Holds |
|---|---|
| `deck.toml` | Bays and the listen address. Mode 0600, because it holds the bays' tokens |
| `deck-token` | The clients' token (mode 0600) |
| `deck-next-lease` | Counter for lease ids |
| `deck.sock` | Unix socket for clients on the deck machine (no token) |
| `deck.log` | Output of the installed deck |

```toml
listen = ":7400"                       # optional; --listen wins, then this, then :7400

[bay.mini-1]
url = "http://mini-1.lan:7477"
token = "…"

[bay.mini-2]
url = "http://mini-2.lan:7477"
token = "…"
```

Only `key = "string"`, `[bay.<name>]` tables and `#` comments are read. An unknown key is an error.

## Behaviour

- **Lease ids:** the deck issues `D<n>` and remembers which bay and bay lease it belongs to. The
  lease it returns has `id`, `ssh.host` (`cryo-D7`) and the `ssh.config` rewritten for `D7`,
  including the `ProxyCommand cryo ssh D7`. The key and host key pass through unchanged.
- **Pick:** round-robin over the online bays whose last status shows a thawed capsule. The deck
  asks that bay for a lease without waiting; if it answers `no_capacity`, the deck tries the next
  bay. The request's `cache`, `name` and `idle_s` go along.
- **Queue:** when no bay has a capsule, the request waits in the deck's own first-come,
  first-served queue for up to `wait_s` (default 600), and is tried again each time a status poll
  shows a free capsule (see Health). A client that hangs up gives up its place. Bay queues stay
  empty.
- **Health:** the deck polls every bay's `/v1/status` every 5 s, or every 1 s while requests wait
  in its queue. Two failures in a row mark a bay offline: no new leases go to it, and its leases
  are dropped at once (they answer `410 lease_lost`). The next answer marks the bay online again.
- **Connect:** `cryo ssh D7` opens `/v1/leases/D7/connect` on the deck, which opens the
  bay's connect for the lease and relays bytes both ways. It closes when either side closes or the
  lease ends. Clients change nothing.
- **Folder:** `--folder` is refused (`400 bad_request`). Put code in with `git clone` or
  `copy_in`.
- **Status:** `GET /v1/status` merges every bay's capsules, renumbered across bays (a lease's
  `capsule` matches), and adds a `bays` list whose `capsules` use each bay's own numbers. `image` is
  `-` when no bay is online, the digest when the online bays agree, `mixed` otherwise. The deck is
  `doctor: "ok"` while any bay is online. `GET /v1/doctor` has one check per bay (`bay <name> online`),
  and one failing check, `a bay is configured`, when `deck.toml` lists none.
- **Errors from a bay:** a bay's own error passes through. A transport error (bay unreachable)
  is `503 bay_unreachable`, and for `connect` `503 capsule_unreachable`. A bay's `404` or `410` for
  a lease the deck mapped becomes `410 lease_lost`.
- **A bay goes offline or restarts:** its leases are gone (a bay restart ends every lease). Asking
  for one answers `410 lease_lost`, and so does any lease of a bay the deck sees as offline.
- **`cryo deck rm`:** the bay's leases are not touched; the deck forgets them, so they answer
  `410 lease_lost` and the bay expires them by idle timeout.
- **A deck restart** forgets all its leases for the same reason. New leases get new ids.
- **Releasing a lost lease:** `DELETE` of an id the deck does not know, or has lost, answers
  `410 lease_lost`. `cryo release` reports that and keeps its local key files; the next `cryo ls`
  removes the ones whose lease the deck no longer lists.

## Limits

- LAN or VPN only. Plain HTTP with bearer tokens, no TLS: tokens travel in clear text.
- No drain: to take a Mac out, `cryo deck rm` it or stop its bay.
- No placement by cache or image. Every Mac should run the same image; the deck only checks that
  a bay is up.
- No accounts: one token for all clients.
- Two VMs per Mac (Apple's limit), so three Macs make six capsules.
