// lib.rs — substrate-lib crate root (orchestration layer).
//
// After the four-package split (DECISION_SUBSTRATELIB_PRESHIP_REFACTOR
// addendum 2026-05-29), substrate-lib is the narrow orchestration layer
// over substrate-types / substrate-kernel / substrate-ml. It owns the
// verb mechanics, the row-state automaton, the audit write-gate, and the
// higher-layer reference implementations (CognitionKit, ActuatorKit,
// dreaming, working-set, sqlite tail) that compose the three sub-crates.
//
// Pure types live in substrate-types, hot-path kernels in
// substrate-kernel, cold-path / ML algorithms in substrate-ml. Consumers
// depend on those crates directly; substrate-lib no longer re-exports
// them (the pub-use bridges were removed when the symbol tail relocated).
//
// The reference implementations here are the scalar oracle every shipping
// implementation must match bit-for-bit. See README.md and INDEX.md for
// the mapping back to cookbook sections.

#![allow(dead_code)]
#![allow(clippy::needless_return)]
#![allow(clippy::too_many_arguments)]

// === §4 Runtime layout ===
pub mod working_set;
pub mod sqlite_tail;

// === §8 Algorithms — the audit write-gate (consumes substrate-kernel
// bit_field/sha256 and substrate-types hlc) ===
pub mod audit_gate;

// === §9 Row-state automaton + §10 Verbs (the orchestration surface) ===
pub mod row_state;
pub mod verbs;

// === §11 CognitionKit ===
pub mod cognition_kit;

// === §13 Cognition Bundle ===
pub mod cognition_bundle;

// === §14 ActuatorKit ===
pub mod actuator;

// === §15 Dreaming daemon ===
pub mod dreaming;
