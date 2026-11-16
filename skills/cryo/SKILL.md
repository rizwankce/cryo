---
name: cryo
description: Build and test Apple-platform code (Xcode, xcodebuild, Swift, Simulator) on a clean, isolated macOS VM from a cryo bay, through the cryo MCP tools or the cryo CLI. Use when a task needs macOS or Xcode and the local machine is Linux or must stay clean.
---

# Cryo: clean macOS VMs on demand

A lease gives you a fresh macOS VM (a capsule), usable over SSH well under a second after the
bay hands it out (when every capsule is busy, the request waits in a queue).

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
