# Glossary

> Cryo's words, so every doc means the same thing.

| Word | Meaning |
|---|---|
| **bay** | Cryo on one Mac (`cryo bay`). The only process that touches VMs |
| **capsule** | One VM position on a bay (max 2 per Mac, Apple's limit). Own identity, network, saved state |
| **frozen** | A capsule saved to disk as machine state (`capsules/<N>/state.vzstate`) |
| **thawed** | Restored from saved state and paused in RAM, ready to lease |
| **leased** | Resumed and handed to one client until release or its lease ends |
| **freeze** | Cold boot → settle → warm-up logins → pause → save state |
| **thaw** | Restore saved state (a few seconds, off the lease path). A lease from a capsule thawed ahead of time is usable over SSH in well under a second |
| **refill** | After release: restore the capsule again, rekey it to the next lease id, install that lease's key, warm-up logins, pause |
| **golden image** | A prepared macOS install (Xcode, tools, settings) that every capsule thaws from; named by its digest |
| **golden base** | The image's read-only disk, shared by all capsules of an image |
| **freeze layer** | Per-capsule disk changes made during its freeze, over the golden base |
| **overlay** | Per-lease copy-on-write disk layer, deleted on release |
| **lease folder** | Per-lease host folder swapped into the capsule's virtiofs share once per lease |
| **cache disk** | Per-project APFS disk image, cloned per lease, hot-plugged as USB storage |
| **refreeze** | Freeze a capsule again in the background after a cold-boot fallback (state `refreezing`) |
| **root helper** | LaunchDaemon `dev.cryo.pf` that loads the pf anchor at boot; the only part running as root |
| **manifest** | `capsules/<N>/manifest.json` written at freeze; checked before restore, mismatch → cold boot |
| **doctor** | Host health checks (`cryo doctor`); the bay won't thaw until the ones that block thawing pass |
| **broken** | A capsule whose last 3 refills failed; the bay keeps retrying it with backoff |
| **lease** | One client's exclusive use of a capsule, by id (`L81`); reached over SSH through `cryo ssh <id>`, never by IP |
