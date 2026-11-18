# Releasing

1. Bump `cryoVersion` in `Sources/CryoAPI/Version.swift` in a PR and merge it.
2. Tag the merge commit on `main` and push the tag:

   ```sh
   git checkout main && git pull
   git tag vX.Y.Z
   git push origin vX.Y.Z
   ```

3. The `release` workflow checks that the tag matches `cryoVersion`, builds and tests, then
   publishes the release with the source tarball (`cryo-X.Y.Z.tar.gz`), its `.sha256` and a build
   provenance attestation. Notes are generated from merged PRs, grouped by label
   (see `.github/release.yml`).
4. Publish the Homebrew formula and bottle by running `scripts/bump.sh` in the
   [homebrew-tap](https://github.com/rizwankce/homebrew-tap) repo.

Verify a download with `gh attestation verify cryo-X.Y.Z.tar.gz --repo rizwankce/cryo`.
