# Recorded Audits

This directory contains dated, bounded investigations and review records.
Each report names its evidence window, source revisions, conclusions, and
limits so later work can distinguish a historical result from current state.

## Records

- [Continuous Security Review Record — June 25 to July 22, 2026](AUDIT_CONTINUOUS_SECURITY_REVIEW_2026-07-22.md)
- [Security Finding Remediation Ledger — 537 issue-to-commit records](SECURITY_FINDING_REMEDIATION_LEDGER_2026-07-22.md)
- [CE 1.0.35 Security Remediation Record — July 24 to 25, 2026](AUDIT_CE_1_0_35_SECURITY_REMEDIATION_2026-07-25.md) (wave in flight, unmerged)

## Conventions

- Name reports `AUDIT_<topic>_<date>.md`.
- Record the exact branch, commit, artifact identity, or measurement window.
- Keep rejected, accepted, deferred, and false-positive dispositions separate
  from verified fixes.
- Preserve failed or superseded conclusions as history rather than deleting
  them.
- Do not publish exploit material or private report links in this public
  directory.
