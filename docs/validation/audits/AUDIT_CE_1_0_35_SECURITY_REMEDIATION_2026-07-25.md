---
status: recorded
created: 2026-07-25
review_window: 2026-07-24 through 2026-07-25
base_revision: c9f4945d (develop/1.0.x)
merge_state: unmerged
finding_records_addressed: 4
---

# CE 1.0.35 Security Remediation Record — July 24 to 25, 2026

This record covers the CE 1.0.35 mission wave and the four external security
finding records it touched. It is a point-in-time record of a wave that is
**not yet merged**. Every commit cited below is on a local stream branch cut
from `develop/1.0.x` at `c9f4945d`. Nothing has been pushed to the remote and
nothing has been merged to `develop/1.0.x`, so a scan of the published
repository will not yet observe these fixes.

Findings are identified by title and by the commit that introduced the reported
condition. Report URLs are omitted because this directory is public.

## Verified fixes, pending merge

| Severity | Finding | Reported in | Fix commits | Stream branch |
|---|---|---|---|---|
| High | Release OIDC environment trusted by manual Windows jobs | `cc79b547` | `c6c868d1`, `5a9b067b` | `stream/ci-windows-signing-tag-push` |
| Medium | Parall configs ignore direct-stdio no-daemon mode | `53ad6c43` | `cd24de66`, `0d0fdc2e` | `stream/pa-parall-stdio-vault-off` |

### Release OIDC environment

Both Windows signing jobs in `.github/workflows/release.yml` now carry the
condition `startsWith(github.ref, 'refs/tags/') && github.event_name == 'push'`.
The jobs are therefore unreachable from `workflow_dispatch` and from branch
runs, so no manual run can enter the `release` environment and mint an
Azure-trusted token. `environment: release` and `id-token: write` are retained
because the environment subject is what the Azure federated credential matches.

The finding offered two alternative mitigations. The first is to make the jobs
unreachable outside a tag push. The second is to restrict the GitHub
environment. This wave implemented the first. See the accepted-risk section
below for the disposition of the second.

`distribution/windows/SIGNING.md` section 2 Option A now states the
requirement that signing jobs stay restricted to tag push events, that
`workflow_dispatch` and branch runs must not enter the `release` environment,
and that the environment must carry deployment protections appropriate for
published release tags before the Azure Environment credential is relied on.

### Parall configs

`InstallCommand.swift` now forwards `directStdio: noDaemon` and
`vaultOff: vaultOff` at the Parall sandboxed-instance call site, so a Parall
clone receives the same transport and vault posture as the native config.
Two regression tests were added. One asserts the written entry is a
command/args stdio entry carrying `MOOTX01_HTTP_PORT` cleared and
`MOOTX01_VAULT=0`, and that it is not an http/url entry. The second reads the
call site and requires both argument labels, because both parameters are
defaulted and dropping them is a silent compiling regression that the
behavioral test alone does not catch. The behavioral test was confirmed to pass
against the unfixed call site before the second test was added.

## Partially addressed, remains open

| Severity | Finding | Reported in | State |
|---|---|---|---|
| Medium | SECURITY.md overstates SQLite at-rest encryption | `b13cfbd6` | Open |

The finding has three parts and one is closed.

The macOS Swift `serve` path opening plaintext is fixed for **new** estates.
`ServeCommand`, `DrainCommand`, and `DreamCommand` now resolve an at-rest
posture and pass an `encryptionConfig`, where before the string
`encryptionConfig` appeared nowhere in `apps/mootx01`. New estates on every
platform are created whole-database encrypted unless the operator passes
`--no-encrypt`. Commits `195bcfb2`, `4a3ba1b9`, `9a36c6f5`, `72b7e458`,
`81488665`, `e31d69c2`, `5abf892b`, `3714d29f`, `38961256`, `17eb6571`.

Estates created before this release remain plaintext. The migration vehicle is
`mootx01 upgrade` and it is not built. That work is CE-1.0.35-08 and it is not
started.

The document wording is unchanged. `SECURITY.md` has not been edited in this
wave. That work is CE-1.0.35-09, which is sequenced last so the document
describes what shipped, and it is not started.

This finding should stay open until both of those land.

## Resolved outside this wave, verified

| Severity | Finding | Reported in | State |
|---|---|---|---|
| Informational | Plugin artifacts left at 1.0.18 after binary bump | `fb576161` | Resolved |

Verified on `develop/1.0.x` at `c9f4945d`. The embedded install bundle carries
twenty occurrences of `1.0.34`, the generated embedded artifacts source carries
`1.0.34`, and the binary version constant is `1.0.34`. Binary and plugin
metadata are in lockstep, so the reported skew is gone. No commit in this wave
addressed it. Later release version bumps closed it incidentally.

## Accepted risk, owner decision

The `release` GitHub environment exists and carries the Azure Environment
federated credential, and it has no protection rules and no deployment branch
or tag policy. Adding a `v*` deployment tag rule was proposed as
defense-in-depth against future workflow drift. The owner declined it on
2026-07-25.

Recorded as accepted rather than outstanding. The two controls that bound this
risk are both in place. OIDC is isolated in cargo-free jobs that download
already-built binaries and run no build code, so a compromised build dependency
cannot reach the signing credential. The signing jobs are gated to tag push
events, so no manual run can enter the environment. The environment rule would
guard only against a future incorrect edit to those conditions.

## Correction to an earlier report

The CE-1.0.35-01 completion report stated that the release environment
protection was outstanding and that the operator had to verify it by hand. That
framing was wrong. The environment and its Azure Environment federated
credential already existed. Only the deployment tag rule was absent. The
mission drawer asked for a one line verification note and the report inflated it
into an open remediation item. The error was asserting provisioning state from
runbook prose instead of querying it.

## Identified during this wave, not recorded here

Two conditions were found while working and are held out of this public record
until they are fixed, per this directory's rule against publishing exploit
material. One is a workflow job that holds an OIDC write permission under a
condition that omits an event type check. One is a source comment that repeats
the same overstated key custody claim this wave corrects in prose, in a file
outside the reporting finding's file list. Both are recorded privately with
enough detail to act on. Neither is reachable without repository write access.

## Limits of this record

This record describes a wave in flight. It is accurate as of `17eb6571` on
`stream/ei-encrypt-by-default`, the chain tip. Two of the nine missions in the
wave are not started, and one of the four findings above depends on both of
them. No claim here should be read as describing the published repository until
the wave is merged.

Test evidence for the wave is recorded in the mission completion records rather
than duplicated here. The suites and their counts at the chain tip are 279 in
`apps/mootx01`, 515 in `AriaMcpKit` Swift, 454 in `AriaMcpKit` Rust, 818 in
`LocusKit` Swift, 885 in `LocusKit` Rust, and 225 in the `mootx01` Rust crate.
The Rust counts are unchanged from the wave baseline and serve as the parity
regression check, because no Rust source file was modified in this wave.
