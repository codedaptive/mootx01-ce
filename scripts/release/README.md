# Release version tooling

Cutting a release stamps the product version in multiple sites across
the tree. These scripts keep every stamp in agreement so a release
cannot ship with drifted versions.

## The three scripts

- `bump_version.py <version> [--date YYYY-MM-DD]` — bumps every stamp
  in one shot, preserving each file's byte format. Refuses to run
  unless the tree is already consistent at the current version, and
  runs the verifier afterwards.
- `verify_version.py [version]` — the gate. Asserts every stamp
  agrees and exits non-zero on any disagreement. Wired into
  `release.yml` as a fail-closed check keyed to the tag.
- `sync-plugin-version.py` — sets the plugin manifest versions equal
  to the CE product version. Run after a plugin refresh lands.

## Release runbook

1. `python3 scripts/release/bump_version.py <version>` on
   `develop/1.0.x`.
2. Add the root `CHANGELOG.md` release-notes entry.
3. Build both legs; `mootx01 --version` should print
   `<version> (<date>)`.
4. Commit; flow `develop → candidate → stable`.
5. `python3 scripts/release/verify_version.py <version>` against the
   stable HEAD.
6. Tag last, on the stable HEAD:
   `git tag -a v<version> <stable-HEAD>`.

Tagging last is a rule, not a preference. The version bump and the
branch flow come first; the tag is the final, single, irreversible
step.
