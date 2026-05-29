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
#[path = "glref-rust-working_set.rs"]
pub mod working_set;
#[path = "glref-rust-sqlite_tail.rs"]
pub mod sqlite_tail;

// === §8 Algorithms — the audit write-gate (consumes substrate-kernel
// bit_field/sha256 and substrate-types hlc) ===
#[path = "glref-rust-audit_gate.rs"]
pub mod audit_gate;

// === §9 Row-state automaton + §10 Verbs (the orchestration surface) ===
#[path = "glref-rust-row_state.rs"]
pub mod row_state;
#[path = "glref-rust-verbs.rs"]
pub mod verbs;

// === §11 CognitionKit ===
#[path = "glref-rust-cognition_kit.rs"]
pub mod cognition_kit;

// === §13 Cognition Bundle ===
#[path = "glref-rust-cognition_bundle.rs"]
pub mod cognition_bundle;

// === §14 ActuatorKit ===
#[path = "glref-rust-actuator.rs"]
pub mod actuator;

// === §15 Dreaming daemon ===
#[path = "glref-rust-dreaming.rs"]
pub mod dreaming;
