---
status: recorded
created: 2026-07-22
last_updated: 2026-07-21
review_window: 2026-06-25 through 2026-07-21
claims_ledger: none; process and remediation record
---

# Continuous Security Review Record — June 25 to July 21, 2026

MOOTx01 closed **537 security finding records** during this review period.
The work began in Enterprise Edition on June 25, moved through the shared
Community Edition delivery path, and continued after the Codex Security
review state was reset.

| Review record | High | Medium | Low | Informational | Total |
|---|---:|---:|---:|---:|---:|
| Pre-reset EE campaign | 3 | 123 | 66 | 89 | 281 |
| Post-reset fixed archive | 39 | 124 | 49 | 44 | 256 |
| **Combined remediation record** | **42** | **247** | **115** | **133** | **537** |

The complete [finding remediation ledger](SECURITY_FINDING_REMEDIATION_LEDGER_2026-07-22.md)
lists every issue by name with its EE fix or workstream-closing commit and its
public CE delivery or release commit. A finding fixed in both Swift and Rust,
or fixed in EE and backported to CE, is counted once.

## Git record

The pre-reset campaign audited EE commit `bb895c747` and closed on
`1943e8962`. Its retained report, assignments, and verification evidence were
recorded in EE commit `c79e9431`.

| Boundary strengthened | EE fix/closing commits | Public CE delivery |
|---|---|---|
| Injection and command execution | `3a1dfdd57` | [`39c274fe`](https://github.com/codedaptive/mootx01-ce/commit/39c274febec7ff28739b16ef5446f3db6d069a74) |
| Destruction, transactions, vault lifecycle, and snapshot integrity | `b3e3c6878`, `d303193b0`, `3a1dfdd57`, `f777bf565`, `c53f0c77e` | [`39c274fe`](https://github.com/codedaptive/mootx01-ce/commit/39c274febec7ff28739b16ef5446f3db6d069a74) |
| Sensitive-data leakage | `5781ac680`, `84734debe`, `58d71fef3` | [`d22c42bd`](https://github.com/codedaptive/mootx01-ce/commit/d22c42bd94d5f84f6c2561519ccc57c4bece0d25) |
| Origin and transport authorization | `964f80738`, `84734debe` | [`295f1789`](https://github.com/codedaptive/mootx01-ce/commit/295f1789d9393fb79243215d417d503e9cb22b99) |
| Path containment | `3a1dfdd57`, `84734debe`, `6dd3deaa7` | [`e533daf9`](https://github.com/codedaptive/mootx01-ce/commit/e533daf9584dc9c55241372a770912a96b5e6e52) |
| Resource bounds | `5781ac680`, `964f80738`, `84734debe`, `a2fe65ad2`, `8278c4a4f`, `f4e58e9c6` | [`e2034ce9`](https://github.com/codedaptive/mootx01-ce/commit/e2034ce9fcca734d9fb4d69371a5d466b7cfae7d) |
| Panic and fail-closed decoding | `58d71fef3`, `a2fe65ad2` | [`39c274fe`](https://github.com/codedaptive/mootx01-ce/commit/39c274febec7ff28739b16ef5446f3db6d069a74) |
| Concurrency and transaction isolation | `d303193b0`, `964f80738`, `84734debe`, `c53f0c77e` | [`39c274fe`](https://github.com/codedaptive/mootx01-ce/commit/39c274febec7ff28739b16ef5446f3db6d069a74) |
| Input validation and untrusted decoding | `3a1dfdd57`, `ab3d64d04`, `1943e8962` | [`7cb9e178`](https://github.com/codedaptive/mootx01-ce/commit/7cb9e178d0f1a2fa2ffd143ea5e3b318c3385504) |
| Supply, installer, and upgrade integrity | `ab3d64d04`, `316cdb3af` | [`d22c42bd`](https://github.com/codedaptive/mootx01-ce/commit/d22c42bd94d5f84f6c2561519ccc57c4bece0d25) |
| Security-adjacent correctness | `ab3d64d04`, `a2fe65ad2`, `58d71fef3` | [`39c274fe`](https://github.com/codedaptive/mootx01-ce/commit/39c274febec7ff28739b16ef5446f3db6d069a74) |

The post-reset archive records 256 fixed findings across `mootx01-ce`,
`moot-core`, `moot-memory`, `moot-semantics`, and `moot-system`. The public
history carries those fixes through the CE security batches and release
commits shown row by row in the ledger.

## Review loop

1. Fix the repository, branch, and commit under review.
2. Review independent threat surfaces against that exact head.
3. Revalidate candidates in the live code.
4. Repair the owning boundary and add regression coverage.
5. Apply the same rule to Swift and Rust where both ports expose it.
6. Run the owning kit and affected cross-kit suites.
7. Integrate in EE, deliver shared behavior to CE and the public SDK venues,
   and review the new head again.

This loop caught remediation regressions before release, including a vault
reconcile identity regression and a governor double-fire race. Both were
corrected before the campaign closed.

## Retained source record

The post-reset source is
`codex-security-archived-findings-2026-07-22T23-37-17.415Z.csv`, SHA-256
`904cad3b92ad186f22e24a1e34651d09b3e6932b72477a1d8863d6f97051d71e`.
It contains 261 records: 256 fixed, four accepted dispositions, and one false
positive. Only its 256 fixed records are included in the combined total.

Only the tip of `stable/1.0.x` is supported. See the
[Security Policy](../../../SECURITY.md) for the current threat boundary and
private reporting channel.
