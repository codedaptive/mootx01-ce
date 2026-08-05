---
status: recorded
created: 2026-08-04
review_window: 2026-08-03 through 2026-08-04
base_revision: ebd4f3087 (develop/1.1.x)
findings_closed: 38
---

# CE 1.1.0-beta Security Remediation Record — August 3 to 4, 2026

Findings closed by the security remediation work, prepared on `develop/1.1.x` at
`ebd4f3087`. Reported-in names the commit that introduced the condition.

Commits below are Community Edition revisions. Entries reading a bare date
reached CE before commit-level port provenance was recorded; entries reading
"not published" name work that is maintainer-only by the edition boundary and
has no CE commit. Commit-level detail for every entry lives in the Enterprise
Edition record.

12 further finding(s) closed in this window are not listed: their fixes
landed only in maintainer-only tooling that CE does not ship. They are recorded in
the Enterprise Edition ledger.

## Closed

| # | Severity | Issue | Reported in | Fix commits |
|---:|---|---|---|---|
| 1 | High | Break-glass confirmation not bound to recovery intent | `07e086298` | `f870cb3bf`, `942c1ae6a` |
| 2 | High | CloudKit SecretSync head accepted without policy validation | `e7fdad224` | `051bc1380`, `f6242f531` |
| 3 | High | Dense lens rows leak restricted memory subjects | `98d54b111` | `64da61cf0`, `602ad8842`, `dd51b2327`, `64091727b` |
| 4 | High | HTTP client wiring enables loopback daemon impersonation | 2026-07-01 | 2026-07-02, not published, 2026-08-03 |
| 5 | High | Meeting decisions lose source sensitivity on filing | `9ff6f91b0` | `e21c3448b`, `ea8f69031`, `62d4e694b`, `7357879e3`, `b55f9fa4a` +3 |
| 6 | High | Plugin permission backfill bypasses user denies | 2026-07-04 | `a2e007b34`, `4d555729c`, `3673f8ae6` |
| 7 | High | Subject summaries bypass per-row encryption | `41332bcdb` | `bcda04715`, `ed71cfa42`, `db4320066` |
| 8 | High | Typed conflict reports bypass KG fact sensitivity | `d6f22240a` | `e7d4f1ba6`, `6d159826c`, `f157db219` |
| 9 | High | macOS current-version upgrade skips KG fact backfill | `0d1967c81` | `e9f783770` |
| 10 | High | near: pivot bypasses provenance sensitivity redaction | `57b661bce` | `0f04c5ec5`, `3e178b967` |
| 11 | Medium | Forged custody checkpoint can delete Secure Enclave handles | `6290e17b8` | `f4a6cba74`, `01930c488` |
| 12 | Medium | Sensitive-row existence oracle in memory tools | 2026-07-05 | `aa4140660`, `ea255297c` |
| 13 | Medium | DST edge can extend restricted grants past local midnight | 2026-07-05 | `bbdbb84aa`, `c5df92996` |
| 14 | Medium | HTTP concurrency gate can deadlock under queued load | 2026-06-28 | `878904a87`, `9107416e1` |
| 16 | Medium | Expunge sibling scrub bypasses accepted-row gate | 2026-06-28 | `45a117c90`, `5b5c9423e`, `ebd4f3087`, `5ed5c1d11`, `5b5c9423e` +1 |
| 17 | Medium | Incremental sync drops backend update/delete events | 2026-06-12 | `dc77a0487`, `3a554b1b2`, `243284284` |
| 19 | Medium | MemPalace importer allows unbounded file/DB DoS | 2026-06-10 | `b9dc79278`, `f6d892420`, `b3722df8f`, `9e1c078c0` |
| 20 | Medium | Path-based moot_id guard allows same-path hijack | 2026-06-28 | `f8cb58dd6`, `5397ffee7`, `23da296df`, not published |
| 21 | Medium | Plaintext bypass in Rust SQLite encrypted upsert | 2026-06-13 | `c763707c1`, `2f21c94ec`, `209aab6f5`, `67047d3f1`, `2f21c94ec` +1 |
| 22 | Medium | Plugin manifests trust unauthenticated loopback MCP | not published | not published, 2026-08-03 |
| 23 | Medium | Row crypto skips non-drawers content tables | `bcda04715` | `398283c78`, `70a44525e`, `07a75d016` |
| 24 | Medium | Seconds clocks backdate Rust audit events after ms migration | 2026-07-02 | `113202317`, `431fcc4e0`, `e32e09d02` |
| 25 | Medium | Silent partial expunge leaves accepted lineage content readable | `45a117c90` | `ebd4f3087`, `2fe1e8b7c`, not published |
| 26 | Medium | Subject producers survive estate close | `7da00f617` | `439a52e35`, `7436eed6a`, `449d80702` |
| 27 | Medium | Typed conflict proposals bypass sensitivity filtering | `6f42c8d95` | `25ded8f25`, `02bdf1e24`, `b3d9ef5c8` |
| 28 | Medium | Unauthenticated URL scheme can mutate memory state | 2026-06-13 | `90b9a3d10`, `fab0cc77a`, `fb0e926e7`, `65342021c`, `fab0cc77a` +1 |
| 29 | Medium | Unbounded estate-open fingerprint backfill can DoS startup | 2026-06-12 | `1bcbaa5cf`, `3e849d1f1` |
| 30 | Medium | VaultKit docs falsely claim plaintext exports are encrypted | 2026-06-06 | `a061c13cc`, not published, `39095a86f` |
| 31 | Medium | setSubject silently rewrites memory metadata | `dd258f98b` | `9417dd290`, `0a4026904`, `b46e26021`, `ebd4f3087`, `9417dd290` +1 |
| 32 | Low | Estate status leaks hidden subject metadata | `baa38aa95` | `c6329823a`, `692203d59` |
| 33 | Low | Forged AppIntent memory entities from text parsing | 2026-06-13 | `57b661bce` |
| 35 | Low | Malformed JSON desynchronizes moot-fork backends | 2026-06-10 | `2882c4970`, `25dabed04`, `6f08e42ed`, `b59926a9b`, `25dabed04` +1 |
| 36 | Low | Published reports leak judge command fingerprints | not published | not published, 2026-08-04 |
| 37 | Low | Unchecked DCP numeric normalizers allow denial of service | `7eedf4a5a` | `38e5336ff`, `3f6ffe1de` |
| 42 | Informational | Judge hydration depth is not persisted in reports | not published | not published, 2026-08-03 |
| 43 | Informational | KG fact columns added without schema migration | `e21c3448b` | `0d1967c81`, `833d98314`, not published, `eaa9a0953` |
| 46 | Informational | Rust residue scan follows symlinks during teardown | not published | not published, 2026-08-03 |
| 50 | Informational | Verdict parser accepts negated CORRECT replies | not published | not published, 2026-08-03 |

## Suite counts

| Suite | Count |
|---|---:|
| `MootIntentKit` Swift | 49 |
| `LocusKit` Swift | 934 |
| `LocusKit` Rust | 947 |
| `AriaMcpKit` Rust | 550 |
| `VaultKit` Swift | 206 |
| `VaultKit` Rust | 182 |

Counts are Community Edition totals, measured on this revision. Suites absent from
CE (maintainer-only tooling) are not listed.
