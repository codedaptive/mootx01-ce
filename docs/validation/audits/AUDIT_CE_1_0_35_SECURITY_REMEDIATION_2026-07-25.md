---
status: recorded
created: 2026-07-25
review_window: 2026-07-24 through 2026-07-25
base_revision: c9f4945d (develop/1.0.x)
merge_state: pre-merge
finding_records_addressed: 4
---

# CE 1.0.35 Security Remediation Record — July 24 to 25, 2026

This record covers the four security finding records addressed by the CE 1.0.35
work. Commits are cited from the wave prepared on top of `develop/1.0.x` at
`c9f4945d`. The record is written before merge, so a scan of the published
repository does not yet observe these changes.

Findings are identified by title and by the commit that introduced the reported
condition. Report links are omitted because this directory is public.

## Verified fixes

| Severity | Finding | Reported in | Fix commits |
|---|---|---|---|
| High | Release OIDC environment trusted by manual Windows jobs | `cc79b547` | `c6c868d1`, `5a9b067b` |
| Medium | Parall configs ignore direct-stdio no-daemon mode | `53ad6c43` | `cd24de66`, `0d0fdc2e` |
| Low | PyPI publish job reachable from manual runs | not externally reported | `11e334d0` |

### Release OIDC environment

Both Windows signing jobs in `.github/workflows/release.yml` now require
`startsWith(github.ref, 'refs/tags/') && github.event_name == 'push'`. The jobs
are unreachable from `workflow_dispatch` and from branch runs, so the signing
credential is reachable only from a release tag push. The event type is the
trust boundary, not the ref string.

`distribution/windows/SIGNING.md` section 2 Option A records the operating
requirements for the signing path.

### Parall configs

`InstallCommand.swift` forwards the direct-stdio and vault-off posture at the
Parall sandboxed-instance call site, so a Parall clone receives the same
transport and vault configuration as the native client config. Two regression
tests cover the written entry shape and the call site itself.

### PyPI publish job

Found while auditing the release workflow for other jobs holding a publish
credential. `publish-pypi` now carries the same tag-push-only condition as the
Windows signing jobs. Verified by parsing the workflow and asserting that every
job holding `id-token: write` requires the event type check. Three jobs qualify
and all three pass. Build jobs are unchanged because they hold no credential.

## Partially addressed, remains open

| Severity | Finding | Reported in | State |
|---|---|---|---|
| Medium | SECURITY.md overstates SQLite at-rest encryption | `b13cfbd6` | Open |

The code half is addressed for newly created estates. The Swift estate openers
now apply an at-rest encryption configuration, and new estates are created
whole-database encrypted unless the operator opts out at install time. Commits
`195bcfb2`, `4a3ba1b9`, `9a36c6f5`, `72b7e458`, `81488665`, `e31d69c2`,
`5abf892b`, `3714d29f`, `38961256`, `17eb6571`.

Estates created before this release are unchanged, and the document wording is
unchanged. This finding stays open until the migration path and the document
revision both land.

## Resolved outside this wave, verified

| Severity | Finding | Reported in | State |
|---|---|---|---|
| Informational | Plugin artifacts left at 1.0.18 after binary bump | `fb576161` | Resolved |

Verified on `develop/1.0.x` at `c9f4945d`. The embedded install bundle, the
generated embedded artifacts source, and the binary version constant all read
`1.0.34`, so binary and plugin metadata are in lockstep. No commit in this wave
addressed it. Later release version bumps closed it.

## Limits of this record

This record is accurate as of the wave prepared on `c9f4945d` and describes
changes that are not yet merged. One of the four findings above remains open and
depends on work that is not complete. No claim here describes the published
repository until the wave is merged.

Test evidence is recorded with the individual changes rather than duplicated
here. Suite counts at the end of the wave are 279 in `apps/mootx01`, 515 in
`AriaMcpKit` Swift, 454 in `AriaMcpKit` Rust, 818 in `LocusKit` Swift, 885 in
`LocusKit` Rust, and 225 in the `mootx01` Rust crate. The Rust counts are
unchanged from the wave baseline and serve as the cross-language parity check,
because no Rust source file was modified.
