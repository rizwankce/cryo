# Cryo

> Instructions for coding agents working in this repo. `AGENTS.md` is a symlink to this file, so
> edit `CLAUDE.md` only.

Cryo turns Macs into a pool of clean, isolated macOS VMs (capsules) for coding agents and CI. Each
capsule waits as saved machine state and is restored on lease; on release it is thrown away and a
fresh one is thawed. One Swift package builds one binary, `cryo`: the bay, the CLI, the MCP server
and the deck. GitHub Actions support lives in [rizwankce/cryo-ci](https://github.com/rizwankce/cryo-ci),
which depends on this package's libraries.

## Words

bay = Cryo on one Mac (`cryo bay`), the only process that touches VMs · capsule = one VM position
(max 2 per Mac) · deck = several bays behind one `/v1` endpoint · lease = one client's use of a
capsule (`L81`, deck leases `D<n>`). Full list: [docs/glossary.md](docs/glossary.md). Use these
words in code, comments and docs.

## Layout

- `Sources/CryoAPI`: the `/v1` types and JSON. `CryoHTTP`: HTTP server/client, sockets.
- `Sources/CryoServer`: the `/v1` server and service protocol, shared by the bay and the deck.
- `Sources/CryoBay`: the bay (Virtualization.framework, images, freeze/thaw, install, doctor).
  **macOS only**; `Package.swift` drops it on Linux.
- `Sources/CryoDeck`: `cryo deck`. `CryoClient`: talks to a bay or deck. `CryoMCP`: `cryo mcp`.
- `Sources/CryoCLI` + `Sources/cryo`: the command line. `FakeBay`: in-process bay for tests
  (cryo-ci uses it too).
- `docs/`: architecture and specs ([docs/README.md](docs/README.md)). `skills/cryo/SKILL.md`:
  the agent skill. `scripts/`: build, install, soak and fence checks.

## Build, test, lint

```sh
swift build
swift test
swift format lint --strict --recursive Sources Tests Package.swift
shellcheck scripts/*.sh
scripts/build-bay.sh      # release build, signed with the virtualization entitlement, to ~/.cryo/bin
```

CI runs lint (swift-format, shellcheck, actionlint), `swift test` on Linux, a static Linux build,
and `swift test` plus a signed release build on macOS 27. Run all of the above before a PR.

## Rules

- macOS 27 only (host and guest) and the newest Virtualization APIs; Apple first-party mechanisms
  only. No support for macOS 26 or earlier.
- Everything except `CryoBay` must keep building and testing on Linux: no Apple-only imports
  outside `CryoBay` (guard with `#if canImport`/`#if os` when unavoidable).
- Swift 6 language mode, strict concurrency. Tabs, 160-column lines (`.swift-format`).
- Tests use Swift Testing (`import Testing`), not XCTest. Prefer `FakeBay` over real VMs; tests
  must not need a VM, sudo or network access.
- The bay binary must be signed with `scripts/cryo.entitlements` and run from `~/.cryo/bin`:
  vmnet refuses binaries under `~/Documents`. Replace installed binaries (copy then `mv`), never
  overwrite in place, or the next launch is killed.
- Never touch the host's real bay, capsules or `~/.cryo` from tests or scripts without being asked.
  Anything needing sudo (`cryo bay install`, pf rules): ask the user to run it.
- Changing behaviour, commands, API or config means updating the matching doc in `docs/spec/`,
  the README, and `skills/cryo/SKILL.md` if agents see the change. Keep the API backward compatible
  for cryo-ci, or change both repos together.

## Git

- Branch off an up-to-date `main`: `fix/`, `feature/` or `other/` plus kebab-case.
- Commit messages: plain description of why, subject under ~72 chars, no emojis.
- PR titles complete "If applied, this PR will …": no `fix:`/`feat:` prefixes. Bodies: a short
  summary, a bulleted list of changes, and a **Test plan** when behaviour changes.
- Merge only when CI is green.
