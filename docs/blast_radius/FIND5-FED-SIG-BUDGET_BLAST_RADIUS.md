# Blast Radius Report — FIND5-FED-SIG-BUDGET

**Baseline:** Rust cargo test pass count at mission start: 423
**Mission:** Fix federated_recall grant-signature verification parity — canonicalize budget at 1.0 in Rust to match Swift
**Finding:** Confirmed Low #5 (Swift/Rust parity — availability denial after first recall)

## Symbols being changed

## Symbol 1: `coordinator.rs` — federated_recall step 4.5 signing payload reconstruction

**Change class:** semantic — the value passed for `inference_remaining_budget`
when reconstructing the verification payload changes from the grant's
current (post-debit) value to the canonical initial value (1.0). No
function signature, type, or public API changes. No symbol renamed or removed.

**Scope:** internal implementation detail inside `EstateCoordinator::federated_recall`

### Call sites

| File | Line | Source | Classification | Justification |
|---|---|---|---|---|
| `rust/src/coordinator.rs` | 5158 | direct read | MUST_UPDATE | The one line that calls `authorizing_grant.signing_payload()` — replace with `Grant::canonical_payload(..., 1.0, ...)` |
| `rust/tests/fed_sig01_grant_signature_tests.rs` | new | additive | MUST_UPDATE | New test `fed_sig01d` covering the two-sequential-recall regression |
| `rust/tests/fed_sig01_grant_signature_tests.rs` | 187 | existing | INTENTIONALLY_LEFT | `fed_sig01b` signs with `unsigned.signing_payload()` where unsigned has budget 1.0 — after fix, verification also uses 1.0; byte-identical, test still passes |

### Summary
- MUST_UPDATE: 2 sites (coordinator.rs line 5158 change + new test)
- INTENTIONALLY_LEFT: 1 (existing fed_sig01b — already budget-1.0-compatible)
- RESCOPE_REQUIRED: 0

## Swift parity

The Swift leg at `CrossEstateFederation.swift:238` already uses
`Grant.canonicalPayload(... inferenceRemainingBudget: 1.0 ...)` with a
comment explaining the reasoning. The Rust fix mirrors that precisely.

No Swift files are changed — this is a Rust-only divergence fix.

## Why "canonicalize at 1.0" rather than "drop budget from payload"

The low-risk, high-fidelity option is to match shipped Swift behavior.
Dropping the budget field from both legs' signing payloads would be equally
correct in theory, but would break existing signature test vectors in both
legs (existing grants signed over payloads that include the budget field at
1.0 would fail verification against a payload that omits the field entirely).
Canonicalizing at 1.0 is backward-compatible with all existing signed grants.
