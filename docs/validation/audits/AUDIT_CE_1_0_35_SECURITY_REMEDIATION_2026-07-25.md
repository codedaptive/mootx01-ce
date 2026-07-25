---
status: recorded
created: 2026-07-25
review_window: 2026-07-24 through 2026-07-25
base_revision: c9f4945d (develop/1.0.x)
findings_closed: 4
---

# CE 1.0.35 Security Remediation Record — July 24 to 25, 2026

This record covers the security findings closed by the CE 1.0.35 work, prepared
on top of `develop/1.0.x` at `c9f4945d`. Findings are identified by title and by
the commit that introduced the reported condition. Report links are omitted
because this directory is public.

## Closed

| Severity | Finding | Reported in | Fix commits |
|---|---|---|---|
| High | Release OIDC environment trusted by manual Windows jobs | `cc79b547` | `c6c868d1`, `5a9b067b` |
| Medium | Parall configs ignore direct-stdio no-daemon mode | `53ad6c43` | `cd24de66`, `0d0fdc2e` |
| Low | PyPI publish job reachable from manual runs | not externally reported | `11e334d0` |
| Informational | Plugin artifacts left at 1.0.18 after binary bump | `fb576161` | closed by later version bumps |

## Release OIDC environment

Both Windows signing jobs in `.github/workflows/release.yml` now require
`startsWith(github.ref, 'refs/tags/') && github.event_name == 'push'`. The jobs
are unreachable from `workflow_dispatch` and from branch runs, so the code
signing credential is reachable only from a release tag push. A job that carries
a signing environment together with `id-token: write` can mint a token from any
step in that job, so gating the login step alone is insufficient. The event type
is the trust boundary, not the ref string.

`distribution/windows/SIGNING.md` section 2 Option A records the operating
requirements for the signing path.

## Parall configs

`InstallCommand.swift` forwards the direct-stdio and vault-off posture at the
Parall sandboxed-instance call site, so a Parall clone receives the same
transport and vault configuration as the native client config. Previously an
install that requested direct stdio still wrote a loopback HTTP endpoint into
each Parall clone, which bypassed both postures. Two regression tests cover the
written entry shape and the call site itself.

## PyPI publish job

Found while auditing the release workflow for other jobs holding a publish
credential. The `publish-pypi` job now carries the same tag-push-only condition
as the Windows signing jobs, so a manual run cannot enter the publishing
environment and upload `moot-memory` under the project's name.

Verified by parsing the workflow and asserting that every job declaring
`id-token: write` also requires the event type check. Three jobs qualify and all
three pass. Build jobs are unchanged because they hold no credential.

## Plugin artifacts

Verified on `develop/1.0.x` at `c9f4945d`. The embedded install bundle, the
generated embedded artifacts source, and the binary version constant all read
`1.0.34`, so binary and plugin metadata are in lockstep and the reported skew is
gone. Closed by later release version bumps rather than by a change in this work.

## Test evidence

Suite counts after this work are 279 in `apps/mootx01`, 515 in `AriaMcpKit`
Swift, 454 in `AriaMcpKit` Rust, 818 in `LocusKit` Swift, 885 in `LocusKit`
Rust, and 225 in the `mootx01` Rust crate. The Rust counts are unchanged from
the baseline and serve as the cross-language parity check, because no Rust
source file was modified.
