# Release version tooling

Cutting a CE release stamps the product version in ~16 sites across three
hand-maintained groups. They drifted once — v1.0.31 shipped with the binary and
the embedded installer copies still reading 1.0.30 while the plugin manifests
read 1.0.31 — because the bump was done by hand and the *embedded* copies (which
are generated-looking and easy to forget) were missed. These two scripts make
that class of mistake impossible to ship.

## The three scripts

- **`bump_version.py <version> [--date YYYY-MM-DD]`** — bumps every stamp in one
  shot, preserving each file's exact byte format. Refuses to run unless the tree
  is already consistent at the current version (so it can't compound an existing
  drift), and runs the verifier afterwards.
- **`verify_version.py [version]`** — the gate. Trusts no single site: asserts
  every stamp agrees, the two embedded copies are byte-identical, and
  `install-bundle.json` is valid JSON. Exits non-zero on any disagreement. Run it
  in CI (it is wired into `release.yml` as a fail-closed gate keyed to the tag)
  and immediately before tagging.
- **`sync-plugin-version.py`** — forces the plugin version to equal the CE
  product version, tolerant of whatever version the plugin arrived with. Run it
  after every EE→CE plugin publish (see "Plugin version sync" below).

## Plugin version sync

External tools reject a plugin whose version disagrees with the binary that
installs it, so the plugin version must ALWAYS equal the CE product version. The
plugin (the `distribution/plugin/` manifests and the embedded installer bundle)
is produced by the private EE generator and published into CE wholesale — but
that generator is deliberately **decoupled** from CE versioning: it stamps a
sentinel (`0.0.0`) and never needs to know the CE version.

CE owns the version. The invariant holds by three mechanisms, no manual tracking:

1. **Publish → `sync-plugin-version.py`.** After dropping a fresh regen into CE,
   run it. It reads the CE product version (the binary's own `[package]` version
   in `Cargo.toml`) and rewrites every plugin/embedded version token to match —
   from the `0.0.0` sentinel or any stale value. The tree is then consistent at
   the current version, so `bump_version.py`'s guard keeps working.
2. **Release → `bump_version.py`.** The common case is a version-only release
   (the plugin rarely changes): bump moves plugin manifests + embedded copies to
   the new version alongside the binary stamps, so the plugin tracks CE for free.
3. **Gate → `verify_version.py`.** In `release.yml`, before any asset is
   published, it asserts plugin == embedded == binary == the release tag. A
   divergent plugin version cannot ship — the release aborts.

The embedded bundle carries all 10 host plugins as one EE-generated artifact; CE
cannot regenerate its *content* (only the `claude-code` host has source in
`distribution/plugin/`). These scripts stamp the *version* in place — content
freshness is the publish step's responsibility.

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
