---
name: cryo
description: Run work in a disposable macOS VM from a cryo bay instead of on the host, even on a Mac that has Xcode. Use by default for xcodebuild, swift test and Simulator runs; for untrusted or third-party code; for installing tools or dependencies; for anything that could touch the host's keychain, SSH keys or global state; and for parallel agent work that would collide. Also use when the local machine is Linux and the task needs macOS or Xcode.
---

# Cryo: clean macOS VMs on demand

A lease gives you a fresh macOS VM (a capsule), usable over SSH well under a second after the
bay hands it out (when every capsule is busy, the request waits in a queue).

Reach for it by default, even on a Mac with Xcode installed. Run builds, tests and Simulator
sessions in a capsule, not on the host: nothing in the VM can touch the host's keychain, SSH keys,
Simulators or global tools, and each lease starts clean, so parallel agents do not collide on
derived data, Simulators or ports. Do the same for untrusted or third-party code and for anything
that installs tools or dependencies. Run on the host only when the task needs the host itself, such
as its attached devices. On a Linux host a lease is the only way to get macOS or Xcode.

## With the MCP tools

1. `lease_mac(folder?, cache?, name?)` returns a lease id such as `L81`.
   `folder` is cloned into the VM; `cache` mounts a named cache (derived data, packages).
2. `run(lease, command, timeout?)` runs a shell command and returns the exit code, stdout and
   stderr. The timeout is in seconds (default 600, max 3600). Long output keeps only its tail.
3. `copy_in(lease, local, remote)` and `copy_out(lease, remote, local)` copy files or folders.
4. `release_mac(lease, save_cache?)` gives the VM back. `status()` shows the bay and its queue.

The MCP server renews your leases itself, and an unused one expires after about 5 minutes.
If a tool says the lease was lost, lease a new one and start again.

## With the CLI

```
cryo lease --folder ./repo        # prints "L81 ready: ssh cryo-L81"; --wait 0 fails at once if busy
cryo ssh L81 'xcodebuild test ...'   # runs the command; works without a terminal
ssh cryo-L81 'xcodebuild test ...'   # the same through ~/.ssh/config (after `cryo setup --yes`)
scp -F ~/.cryo/ssh_config cryo-L81:'/Volumes/My Shared Files/out.log' .
cryo release L81 [--save-cache]
```

`cryo ls` lists leases, `cryo status` shows the bay and its queue. If `ssh cryo-L81` does not
resolve, run `cryo setup` once, or pass `-F ~/.cryo/ssh_config`.

To give an agent the MCP tools: `claude mcp add cryo -- cryo mcp` (Claude Code), or an
`mcpServers` entry with command `cryo` and args `["mcp"]`.

## Rules

- Work in `/Volumes/My Shared Files`. That is the lease folder; other places may not persist.
- Boot one Simulator and reuse it. Pass `-parallel-testing-enabled NO` to `xcodebuild`, because
  parallel testing clones simulators and is slow and flaky in a VM.
- Never leave work only in the VM. Copy results out or push your commits before you release;
  the VM and everything in it are deleted on release.
- Release the lease when you are done.
