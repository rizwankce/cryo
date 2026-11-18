# CLI and MCP

> The `cryo` commands, the MCP tools, the agent skill, and how they reach a bay.
> API: [api.md](api.md). Bay: [bay.md](bay.md).

## Builds

One Swift codebase shared with the bay (API types shared).

| Build | Contains |
|---|---|
| macOS | CLI, `cryo bay`, `cryo image`, `cryo doctor`, `cryo logs`, `cryo ci`, `cryo mcp` |
| Linux | CLI, `cryo mcp` (static binary from Swift's static Linux SDK; keep to a minimal Foundation subset to stay small) |

## Commands

```
cryo lease [--folder PATH] [--cache NAME] [--name NAME] [--wait SECONDS] [--idle 60m] [--json]
     → "L81 ready: ssh cryo-L81"       (writes ~/.cryo/keys/L81, ~/.cryo/known_hosts/L81 and its entry in ~/.cryo/ssh_config)
cryo release <id> [--save-cache]
cryo ls [--json]                        leases on this bay
cryo status [--json]                    bay, health, capsules, queue
cryo ssh <id> [command...]              run a command, open a shell, or act as the ProxyCommand
cryo setup [--yes]                      adds `Include ~/.cryo/ssh_config` to ~/.ssh/config (asks first)
cryo mcp                                MCP server over stdio
cryo version                            also --version
cryo help [command]                     also `cryo <command> --help`

macOS bay only:
cryo doctor [--fix]                     host checks (host only when no bay runs)
cryo logs [-n N] [-f]                   end of the bay's log (default 50 lines; -f follows)
cryo bay start [--listen :7477]         run the bay in this terminal (Ctrl-C stops it)
cryo bay install | uninstall            LaunchAgent dev.rizwan.cryo.bay + pf root helper (one sudo)
cryo bay token [--rotate]               the network listener's bearer token
cryo bay help                           every bay subcommand, including the debug ones below
cryo image build|ls|use|rm              golden images (image.md)
cryo ci …                               runs cryo-ci, a separate program: GitHub Actions jobs on capsules (github.com/rizwankce/cryo-ci)
```

- **`lease`:** `--wait` and `--idle` are sent only when given, so the bay's `wait_default_s` and
  `idle_timeout_s` apply otherwise ([bay.md](bay.md) "Config"). `--idle` takes `90s`, `60m`, `2h`
  or bare minutes. If the key can't be saved locally, the lease is released again.
- **`ssh`:** with a command, always runs it over `ssh -F ~/.cryo/ssh_config` (agents' shells have
  no terminal either). Without one: a shell when stdin is a terminal, otherwise the ProxyCommand
  (stdin/stdout piped to the capsule's sshd through `/v1/leases/{id}/connect`).
- **`ls`:** forgets local keys, known_hosts and ssh_config blocks only for leases of the bay it
  listed (`~/.cryo/lease-bays/<id>` records each lease's bay) that the bay no longer has.
- **`status --json`:** when no bay answers but one left a restart note
  (`~/.cryo/bay-restarting`), prints `{"bay": {"state": "restarting", "alert": "…"}}` and exits 1.
- **`logs`:** prints `$CRYO_HOME/bay.log`, else `~/.cryo/bay.log`: what the installed bay writes. A
  foreground `cryo bay start` prints to its terminal instead. The unified log (subsystem
  `dev.rizwan.cryo.bay`) has the rest: `log show --last 1h --predicate 'subsystem == "dev.rizwan.cryo.bay"'`.
- **`doctor --fix`:** see [setup.md](setup.md). Refuses with `CRYO_URL` set to a remote bay.
- **Stopping the installed bay:** there is no `cryo bay stop`. `launchctl bootout
  gui/$(id -u)/dev.rizwan.cryo.bay` stops it, `launchctl kickstart -k gui/$(id -u)/dev.rizwan.cryo.bay`
  restarts it, `cryo bay install` loads it again. Either ends every lease.

**Debug subcommands** (`cryo bay help`): `paths`, `config` (effective config), `images`,
`capsules` (saved state still matches?), `freeze --capsule N --subnet S [--settle 45] [--warm-up
[ios,macos]] [--image D] [--no-verify] [--verify-tries 4]`, `thaw-test --capsule N [--runs 3]
[--image D]`, `lease-test [--folder DIR] [--cache NAME] [--runs 2] [--queue]`; `image-build`,
`image-use`, `image-rm` are what `cryo image` runs. `freeze` refuses while a bay runs.

## Environment

| Variable | Read by | Meaning |
|---|---|---|
| `CRYO_URL` | every client command | Bay to talk to: `unix:///path`, `unix://~/path` or `http://host[:7477]` (default `unix://~/.cryo/bay.sock`; `https://` refused, no TLS in v1) |
| `CRYO_TOKEN` | every client command | Bearer token for a network listener |
| `CRYO_HOME` | `cryo bay …`, `cryo image …`, `cryo logs`, `doctor` | Bay root instead of `~/.cryo` (tests, side-by-side bays; the LaunchAgent sets it) |
| `GITHUB_TOKEN` | `cryo-ci github` | Wins over the Keychain token (cryo-ci) |
| `CRYO_FORCE_FALLBACK` | `cryo bay start` | Debug: skip every restore and cold boot |
| `CRYO_VERIFY_MS` | `cryo bay freeze`, `cryo image use` | Debug: the freeze verify's first-SSH limit (default 1000 ms) |

## Keeping a lease alive

Activity keeps a lease alive: a renew call **or** an open `cryo ssh` connection. Each lease has an
idle timeout: 5 min for MCP, 60 min by default for the CLI (`--idle`), always capped at 24 h. An
open SSH session never expires mid-work. (Refines the renewal rule in [bay.md](bay.md).)

## MCP tools

| Tool | Does |
|---|---|
| `lease_mac(folder?, cache?, name?)` | Lease a capsule; returns id and SSH host |
| `run(lease, command, timeout?)` | Run a command over SSH (timeout default 600 s, max 3600); returns exit code and output (each stream's tail, ~100 KB) |
| `copy_in(lease, local, remote)` / `copy_out(lease, remote, local)` | Copy files or folders over SSH |
| `release_mac(lease, save_cache?)` | Release |
| `status()` | Bay, capsules, queue |

The MCP server renews its own leases every minute and releases them when it exits.
`lease_mac` waits at most 30 s for a free capsule, then fails with a "call again" message:
clients give up on a call after about a minute, so a longer wait would win a lease the agent no
longer knows about. Requests are handled one at a time, but a tool call runs on its own thread, so
`ping` is answered meanwhile and a stop signal or EOF on stdin interrupts it. A `run` that times
out also kills the command's process group in the capsule. Protocol versions 2025-11-25,
2025-06-18 and 2025-03-26; a client asking for another (or none) gets 2025-11-25.

Register it with an agent: Claude Code `claude mcp add cryo -- cryo mcp`; other clients

```json
{ "mcpServers": { "cryo": { "command": "cryo", "args": ["mcp"] } } }
```

## Agent skill

[skills/cryo/SKILL.md](../../skills/cryo/SKILL.md) lives in the repo; copy it into the
agent's skills folder. It tells an agent to use a capsule by default, even on a Mac with Xcode,
for builds, tests, untrusted code, installs and parallel work. `cryo mcp` sends a short version as its
`initialize` instructions. Rules: work in `/Volumes/My Shared Files`; reuse one booted Simulator
and pass `-parallel-testing-enabled NO`; never leave work only in the capsule; release when done.
