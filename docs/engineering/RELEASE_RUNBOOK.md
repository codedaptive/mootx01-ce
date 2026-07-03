# Release Runbook

Per-release checklist for MOOTx01 CE. Steps marked **[EE]** happen in the
EE repo before the sync; everything else is in CE.

## 1 · Before the sync

- [ ] **[EE]** Bump plugin/package version: `tools/moot-packager/Data/canonical/capability.json` → `version` matches the release
- [ ] **[EE]** Regenerate packager outputs:
  ```bash
  cd tools/moot-packager
  swift run moot-packager --canonical Data/canonical --out .out
  python3 embed-bundle.py .out \
    ../../apps/mootx01/Sources/MootInstallerCore/Generated/EmbeddedArtifacts.swift \
    ../../apps/mootx01/rust/src/embedded/install-bundle.json
  swift run moot-packager --canonical Data/canonical \
    --plugin-repo "$(git rev-parse --show-toplevel)/distribution/plugin"
  ```
- [ ] **[EE]** Commit + push; run the EE→CE sync (its verify step asserts the
      bundle and plugin surface — a stale or reverted tree fails the sync)

## 2 · Tag and build

- [ ] Promote to `stable/1.0.x`, tag `vX.Y.Z`; `release.yml` builds, signs,
      notarizes, and attaches all assets
- [ ] Verify assets present: pkg (arm64/x86_64), setup.exe (arm64/x86_64),
      tarballs, zips, `checksums.txt` + `.minisig`

## 3 · Publish channels (run immediately after assets attach)

- [ ] **Homebrew:** in `homebrew-mootx01-ce`, run `scripts/update-formula.sh vX.Y.Z`
- [ ] **Plugin:** `./distribution/publish-plugin.sh` — validates, mirrors
      `distribution/plugin/` to `codedaptive/mootx01-plugin`, tags `vX.Y.Z`
- [ ] **Winget:** follow `distribution/windows/WINGET.md`
- [ ] **SDK venues:** run the library publisher so `moot-core`,
      `moot-system`, `moot-memory`, `moot-semantics` tag the release; update
      the version snippets in `README.md` and `SDK.MD` if they pin a version

## 4 · Verify

- [ ] `brew upgrade` / fresh `brew install` resolves the new version
- [ ] `winget install Codedaptive.MOOTx01` resolves (first release only:
      confirm community-repo acceptance)
- [ ] Marketplace smoke test on a machine with the public binary:
      `claude plugin marketplace add codedaptive/mootx01-plugin` →
      `claude plugin install mootx01@mootx01` → skill listed, `/mootx01-start`
      present, hooks fire, MCP tools respond

## Invariants

- `distribution/plugin/` and the embedded bundle files are **generated** —
  never hand-edit; fix EE canonical and regenerate (`ce-backport.sh` refuses
  patches to them)
- The plugin version always equals the product version
- Marketplace *submissions* are one-time per marketplace; publishing the
  plugin repo happens every release
