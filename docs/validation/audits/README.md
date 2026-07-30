# Recorded Audits

This directory contains dated, bounded investigations and review records.
Each report names its evidence window, source revisions, conclusions, and
limits so later work can distinguish a historical result from current state.

## Records

- [Security Finding Remediation Ledger — June 25 to July 21, 2026](SECURITY_FINDING_REMEDIATION_LEDGER_2026-07-21.md)
- [Security Finding Remediation Ledger — 537 issue-to-commit records](SECURITY_FINDING_REMEDIATION_LEDGER_2026-07-22.md)
- [Security Finding Remediation Ledger — July 24 to 25, 2026](SECURITY_FINDING_REMEDIATION_LEDGER_2026-07-25.md)
- [Security Finding Remediation Ledger — substrate findings, July 30, 2026](SECURITY_FINDING_REMEDIATION_LEDGER_2026-07-30.md)

## Conventions

- Record only work that is fixed and landed. This is a public record, not a
  work tracker. Pending, open, deferred, and in-flight items do not appear
  here, not even as a row marked open. Write the record after the work merges.
- Do not describe what is unhardened, unfinished, or awaiting a decision. A
  public list of what is not yet defended is an attacker's work list. Track
  those privately.
- Name reports `SECURITY_FINDING_REMEDIATION_LEDGER_<date>.md`. No topic and no
  version number in the filename; the date is the only distinguisher.
- Record the exact branch, commit, artifact identity, or measurement window.
- Keep rejected and false-positive dispositions separate from verified fixes.
- Preserve failed or superseded conclusions as history rather than deleting
  them.
- Do not publish exploit material or private report links in this public
  directory.
