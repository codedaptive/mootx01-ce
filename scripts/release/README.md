# Release version tooling

Cutting a CE release stamps the product version in ~16 sites across three
hand-maintained groups. They drifted once — v1.0.31 shipped with the binary and
the embedded installer copies still reading 1.0.30 while the plugin manifests
read 1.0.31 — because the bump was done by hand and the *embedded* copies (which
are generated-looking and easy to forget) were missed. These two scripts make
that class of mistake impossible to ship.

## The two scripts

- **`bump_version.py <version> [--date YYYY-MM-DD]`** — bumps every stamp in one
  shot, preserving each file's exact byte format. Refuses to run unless the tree
  is already consistent at the current version (so it can't compound an existing
  drift), and runs the verifier afterwards.
- **`verify_version.py [version]`** — the gate. Trusts no single site: asserts
  every stamp agrees, the two embedded copies are byte-identical, and
  `install-bundle.json` is valid JSON. Exits non-zero on any disagreement. Run it
  in CI and immediately before tagging.

## The 16 stamp sites (what the scripts own)

1. **Binary** — `MootMain.swift` (`currentVersion`, `releaseDate`), `lib.rs`
   (`RELEASE_DATE`; `CURRENT_VERSION` derives from `CARGO_PKG_VERSION`),
   `Cargo.toml` + `Cargo.lock` (mootx01-cli package version).
2. **Plugin manifests** — `distribution/plugin/` : 6 `*/plugin.json` +
   `gemini-extension.json` version fields, `README.md` version line,
   `CHANGELOG.md` current heading.
3. **Embedded installer copies** — `apps/mootx01/rust/src/embedded/install-bundle.json`
   and `apps/mootx01/Sources/MootInstallerCore/Generated/EmbeddedArtifacts.swift`
   (each ~20 current-version tokens; the Swift copy must unescape byte-equal to
   the JSON).

Not owned: `distribution/windows/winget/*` (CI regenerates on tag) and the root
`CHANGELOG.md` (human-authored release notes — add these yourself).

## Release runbook

1. `python3 scripts/release/bump_version.py <version>` on `develop/1.0.x`.
2. Add the root `CHANGELOG.md` release-notes entry.
3. Build both legs; `mootx01 --version` should print `<version> (<date>)`.
4. Commit; flow `develop → candidate → stable`.
5. `python3 scripts/release/verify_version.py <version>` against the stable HEAD.
6. **Tag LAST**, on the stable HEAD: `git tag -a v<version> <stable-HEAD> …`.

Tagging last is not optional. v1.0.31 was tagged before the bump, so the tag had
to be force-moved twice, and each move re-fired the winget CI automation onto
`develop` (non-fast-forward → `pull --rebase` before every later push). Bump and
flow first; the tag is the final, single, irreversible step.

## Long-term (planned)

Groups 2 and 3 are produced by the EE `tools/moot-packager`; the durable fix is
for the packager to stamp the version and regenerate the embedded copies, with
CE re-syncing — so those files are never hand-edited. When that lands,
`bump_version.py` narrows to the binary stamps + orchestration, and
`verify_version.py` stays exactly as-is: the invariant gate over all groups,
whoever produced them.
