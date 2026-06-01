// lib.rs — substrate-lib crate root (orchestration layer).
//
// After the four-package split (DECISION_SUBSTRATELIB_PRESHIP_REFACTOR
// addendum 2026-05-29), substrate-lib is the narrow orchestration layer
// over substrate-types / substrate-kernel / substrate-ml: the verb
// mechanics, the row-state automaton, and the audit write-gate.
//
// Pure types live in substrate-types, hot-path kernels in
// substrate-kernel, cold-path / ML algorithms in substrate-ml. Consumers
// depend on those crates directly; substrate-lib no longer re-exports
// them (the pub-use bridges were removed when the symbol tail relocated).

#![allow(clippy::needless_return)]
#![allow(clippy::too_many_arguments)]

// === §8 Algorithms — the audit write-gate (consumes substrate-kernel
// bit_field/sha256 and substrate-types hlc) ===
pub mod audit_gate;

// === §9 Row-state automaton + §10 Verbs (the orchestration surface) ===
pub mod row_state;
pub mod verbs;
