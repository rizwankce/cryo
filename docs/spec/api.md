# Bay API v1

> How the CLI and MCP talk to a bay.
> Bay behaviour: [bay.md](bay.md). Capsules: [capsule.md](capsule.md).

## Transport and auth

- HTTP/1.1 + JSON, every path under `/v1`.
- **Unix socket** `~/.cryo/bay.sock` (mode 0600, only the bay's user): always on, no token.
- **Network listener** (optional, off by default): `cryo bay start --listen :7477` (also `7477` or
  `host:port`; no host means all interfaces); every request needs `Authorization: Bearer <token>`,
  printed by `cryo bay token` (stored in `~/.cryo/token`; `--rotate` makes a new one). The
  installed LaunchAgent runs `cryo bay start` without `--listen`. For other machines (e.g. Linux)
  on your network. Plain HTTP, no TLS in v1: the token travels in clear text, so use it only on a
  trusted LAN or VPN.
- Every response carries `Cryo-Api-Version: 1`. Errors are always
  `{"error": {"code": "…", "message": "…"}}`:

| Status | Code | When |
|---|---|---|
| 400 | `bad_request` | Unparsable HTTP or body, `folder` over the network listener, `connect` without the upgrade headers |
| 401 | `unauthorized` | Network listener: missing or wrong bearer token |
| 403 | `unauthorized` | An admin endpoint over the network listener |
| 404 | `not_found` | Unknown path or lease id; releasing a lease that is already gone |
| 405 | `bad_request` | Wrong method; `Allow` lists the right ones |
| 410 | `lease_lost` | `GET`, `renew` or `connect` of a lease that ended (idle, maximum length, restart; last ~100 ids) |
| 426 | `upgrade_required` | Client API version below the bay's minimum (none set in v1) |
| 500 | `internal` | Anything unexpected |
| 501 | `not_implemented` | Admin endpoints, unix socket |
| 503 | `no_capacity` | No capsule within `wait_s`, or the doctor gate is closed |
| 503 | `capsule_unreachable` | `connect`: the capsule's sshd doesn't answer within 3 s |

## Endpoints

| Method | Path | Body / query | Returns |
|---|---|---|---|
| POST | `/v1/leases` | `{folder?, cache?, wait_s?, name?, idle_s?}` | `201` lease (blocks in the queue up to `wait_s`, default the config's `wait_default_s`, 600) · `400` · `503 no_capacity` |
| GET | `/v1/leases` | | `[lease]` |
| GET | `/v1/leases/{id}` | | lease · `410 lease_lost` |
| POST | `/v1/leases/{id}/renew` | | `{renew_by}` · `410 lease_lost` |
| DELETE | `/v1/leases/{id}` | `?save_cache=true` | `204` (stop, delete, refill) · `404 not_found` if already released |
| POST | `/v1/leases/{id}/connect` | `Connection: Upgrade`, `Upgrade: cryo-ssh` | `101`, then a raw byte stream to the capsule's sshd (used by `cryo ssh`; closed when the lease ends) · `410 lease_lost` · `503 capsule_unreachable` |
| GET | `/v1/status` | | `{bay: {version, image, doctor, blocked_by?, alert?}, capsules: [{n, state, lease}], queue, health}` |
| GET | `/v1/doctor` | | `[{check, ok, fix?}]` |

Admin, unix socket only: `POST /v1/image {digest}` (drain, switch, refreeze both),
`POST /v1/capsules/{n}/refreeze`, `POST /v1/drain`, `POST /v1/undrain`. Not built yet (they answer
`501`): `cryo image use` runs with the bay stopped instead ([image.md](image.md)).

`idle_s` is the lease's idle timeout ([cli.md](cli.md)): default the config's `idle_timeout_s`
(3600), capped at `max_lease_s` and never above 86400; MCP sends 300. A client hanging up while
its request waits or starts gives the capsule back.

In `/v1/status`, `doctor` is `"ok"` or `"failing"` (clients treat any other value as not ok),
`lease` is a lease id or null, and `queue` is the number waiting.
`bay.blocked_by` (optional) lists the failing checks that keep the capsules
frozen ([setup.md](setup.md) "Which checks block thawing"); it is absent once the bay may thaw.
While it is set, `POST /v1/leases` fails at once with `503 no_capacity` naming them.
`bay.alert` (optional) is a problem only a person can fix, with the command to
run, e.g. capsules stuck on taken vmnet subnets; `cryo status` prints it as `ALERT:`.

## Health

`health` in `/v1/status` (optional: older bays omit it). Host readings at the time of the call
plus counters since the bay started.

```json
"health": {
  "uptime_s": 7200, "host_uptime_s": 259200, "disk_free_bytes": 120000000000, "thermal": "nominal",
  "leases_served": 12, "leases_failed": 0, "leases_expired": 1, "refills": 14, "refills_failed": 0,
  "last_lease_ms": 180, "last_refill_ms": 8100
}
```

`disk_free_bytes` is the volume holding `~/.cryo` (null if unreadable); `thermal` is `nominal`,
`fair`, `serious` or `critical`; `leases_expired` counts idle-timeout and maximum-length ends
only; refills count every attempt; `last_*_ms` are null until one happened.

`folder` is a path on the bay's Mac (cloned with `cp -c`); over the network listener it is
refused (`400`), since a remote client could name any folder the bay's user can read.

## Lease object

```json
{
  "id": "L81", "name": "fix-login", "capsule": 0, "state": "leased",
  "created_at": "2026-11-05T21:10:00Z", "renew_by": "2026-11-05T22:10:00Z",
  "expires_at": "2026-11-06T21:10:00Z", "cache": "app", "idle_s": 3600,
  "ssh": {
    "user": "cryo", "host": "cryo-L81",
    "key": "-----BEGIN OPENSSH PRIVATE KEY-----…",
    "config": "Host cryo-L81\n  User cryo\n  ProxyCommand cryo ssh L81\n  IdentityFile ~/.cryo/keys/L81\n  HostKeyAlias cryo-L81\n  UserKnownHostsFile ~/.cryo/known_hosts/L81\n  GlobalKnownHostsFile /dev/null\n  StrictHostKeyChecking yes",
    "host_key": "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI…"
  }
}
```

## SSH

- **Fresh key per lease:** the bay creates an Ed25519 key pair for the next lease id during the
  refill and appends the public key to the guest's `authorized_keys` over SSH; it's useless after
  release (the capsule is thrown away).
- **Pinned host key:** the refill rekey prints the guest's new Ed25519 host key and the lease
  returns it as `ssh.host_key`. Clients write it to `~/.cryo/known_hosts/<id>`, the only
  known_hosts file the lease's `config` reads (`StrictHostKeyChecking yes`, nothing is learned), so
  `~/.ssh/known_hosts` is never touched and a new capsule never shows a host-key mismatch.
- **Agents never see capsule IPs:** `cryo ssh <id>` opens `/v1/leases/{id}/connect` and pipes stdin/
  stdout, so `ssh`, `scp` and `rsync` all work through the ProxyCommand.
- **No exec or copy endpoints in v1:** run commands and copy files over SSH.
