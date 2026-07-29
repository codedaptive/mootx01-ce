// token_compaction_conformance.rs
//
// Cross-language conformance gate for the §7.6 token-compaction transform
// and the §6 token-count estimator (SPEC_DISTILLATION_STORAGE §13.9).
// These are the GOLDEN VECTORS: fixed inputs → fixed byte-exact outputs,
// produced at build time from the canonical v1 ("p1") implementation and
// pinned here AND in Swift TokenCompactionConformanceTests.swift. Any
// divergence between the two suites is a parity failure.
//
// Inputs and expected values MUST NOT be changed to make tests pass.
// If a value doesn't match, fix the algorithm, not the vector. Changing
// the transform tables legitimately (a pipeline-version bump beyond "p1")
// regenerates BOTH suites together.

use substrate_ml::token_compaction::{compact, estimate_token_count};

// Vector sources: the SPEC §5.4 example inputs (illustrative sources; the
// pinned outputs are the v1 transform's canonical renderings, which the
// spec explicitly distinguishes from its illustrative renderings).

const V1_SOURCE: &str = "The quarterly planning meeting has been moved from Tuesday, \
March 3rd to Thursday, March 5th because the conference room on the 4th floor is \
being renovated. Sarah will send out the updated calendar invites by end of day on \
Monday. Please make sure to update your travel plans if you were planning to fly in \
for this meeting.";

const V1_DISTILLED: &str = "Quarterly planning meeting moved from Tuesday, March 3rd \
to Thursday, March 5th because conference room on 4th floor being renovated. Sarah \
will send out updated calendar invites by end of day on Monday. Update your travel \
plans if you were planning to fly in for this meeting.";

const V2_SOURCE: &str = "I have thought about it some more, and I really don\u{2019}t \
want the deluxe package after all \u{2014} the standard one is fine for what I need.";

const V2_DISTILLED: &str = "I have thought about it some more, and I don't want \
deluxe package after all - standard one fine for what I need.";

const V3_SOURCE: &str = "My favorite color is blue.";
const V3_DISTILLED: &str = "My favorite color blue.";

#[test]
fn golden_v1_meeting_moved_renders_byte_exact() {
    assert_eq!(compact(V1_SOURCE), V1_DISTILLED);
    assert_eq!(estimate_token_count(V1_DISTILLED), 66);
    // The rendering is strictly denser than the source (§13.4 payload
    // contract feeds off this property).
    assert!(estimate_token_count(V1_DISTILLED) < estimate_token_count(V1_SOURCE));
}

#[test]
fn golden_v2_negation_survives_byte_exact() {
    // Rule 1 over rule 2: the filler drops, the negation NEVER does, and
    // the typographic apostrophe/em-dash normalize to ASCII (rule 4).
    assert_eq!(compact(V2_SOURCE), V2_DISTILLED);
    assert_eq!(estimate_token_count(V2_DISTILLED), 29);
    assert!(V2_DISTILLED.contains("don't want"));
}

#[test]
fn golden_v3_short_item_byte_exact() {
    assert_eq!(compact(V3_SOURCE), V3_DISTILLED);
    assert_eq!(estimate_token_count(V3_DISTILLED), 6);
}

#[test]
fn transform_is_idempotent_on_its_own_output() {
    // Re-compacting a rendering is a no-op modulo already-applied rules —
    // the hydration variants (§10.1) may compact distilled text at read.
    assert_eq!(compact(V1_DISTILLED), V1_DISTILLED);
    assert_eq!(compact(V2_DISTILLED), V2_DISTILLED);
    assert_eq!(compact(V3_DISTILLED), V3_DISTILLED);
}
