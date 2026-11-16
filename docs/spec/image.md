# Images

> How a golden image is built, named and put into service on one Mac. Guest contract:
> [capsule.md](capsule.md).

## Build

```
cryo image build [--xcode | --xcode-xip <path>] [--runtime iOS|none] [--run ./setup.sh] [--tag name]
                 [--ipsw <file>] [--disk-gb 80] [--subnet 9] [--print-scripts]
```

1. Download the latest macOS IPSW (Apple's public catalog) into `~/.cryo/ipsw/` once, or take
   `--ipsw`; install onto an ASIF disk (`--disk-gb`, ~4 min).
2. Provision with macOS guest provisioning: user `cryo`, SSH with the image's own key, passwordless
   sudo, auto-login, no sleep, no updates, Spotlight off. No guest daemon. The build VM is on
   vmnet subnet 9 (`--subnet`) and found by its MAC in bootpd's lease file.
3. Xcode (optional): the host's selected Xcode (`--xcode`) or one expanded from a .xip on the host
   (`--xcode-xip`), copied into the VM with tar over SSH; accept the licence, `-runFirstLaunch`;
   download a Simulator runtime with `xcodebuild -downloadPlatform` (`--runtime`, default iOS with
   Xcode; `none` skips it), which needs no Apple ID. `--print-scripts` prints the guest
   scripts without building.
4. `--run ./setup.sh`: the user's own script, run in the guest as `cryo` before the image is sealed.
5. Shut down, hash the base disk (SHA-256, ~1 min), write `images/<digest>/` with `image.json`
   (digest, tag, macOS and Xcode versions, vCPU/RAM). Sets `image` in config.toml only if none is
   set. About 15 minutes with Xcode.

Stop the bay before a build: its 2 VMs plus the build VM exceed Apple's limit.

## Xcode source

| Situation | What happens |
|---|---|
| Xcode on the host and `--xcode` | The selected Xcode (or `/Applications/Xcode.app`), copied with tar over SSH |
| `--xcode-xip <path>` | Expanded on the host, then copied the same way (pick a specific version) |
| `--xcode` but no Xcode on the host | Stops with instructions: install from the App Store, or download the .xip from developer.apple.com (Apple ID) and pass `--xcode-xip` |
| No flag | Plain macOS image |

Cryo never asks for or stores an Apple ID.

## Identity and use

- **Digest** = SHA-256 of the finished base disk; leases always refer to it.
  **Tag** (e.g. `xcode-27.2`) is for people, stored in `image.json`.
- `cryo image use <image> [--warm-up [ios,macos] | --no-warm-up] [--settle 45] [--verify-tries 4]`:
  freeze every capsule on the image with the verify step, then set `image` in config.toml.
  `<image>` is a digest, a unique digest prefix or a tag. About 4 minutes for two Xcode
  capsules.
- `cryo image ls` / `cryo image rm <image>` (refuses the configured image and any image a
  capsule is still frozen on).

**`use` runs with the bay stopped**. The bay holds both capsules' VMs and
Apple allows 2 per Mac, so a freeze can't run beside it: stopping the bay is the drain (it ends
every lease, as any restart does, [bay.md](bay.md)) and starting it again is the undrain. `use`
refuses while `bay.sock` answers or `bay.lock` is held. Each capsule keeps its number and subnet
(the guest IP is pinned in the saved state) and is frozen into `capsules/.tmp-use-N.<pid>`; only
when every freeze has verified are they swapped in (the old ones via `.tmp-old-N`) and the config
written, so a failure leaves the old image serving. The next `use`, freeze or bay start deletes
staging whose process is gone and puts back a half-done swap. New freezes have no vsock device. Warm-up: iOS for an Xcode image, or
`--warm-up` / `--no-warm-up`. A live switch, one capsule at a time
(`POST /v1/image`), is not built yet.
