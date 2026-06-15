---
title: Standard Code Authoring Practice
version: 1.0.0
status: implementation-grade specification
author: "MOOTx01 maintainers"
date: 2026-06-14
description: The authoring rhythm for MOOTx01 substrate code — Swift-first, test-driven, both Swift and Rust versions co-authored per file/interface, conformance-gated bit-for-bit on shared vectors.
relates_to:
  - VERSIONING.md
---

# STANDARD_CODE_AUTHORING_PRACTICE

This is the authoritative authoring practice for MOOTx01 substrate code. It
takes precedence over any contrary habit or convenience.

---

## The Law

Every unit of work is authored **Swift-first, test-driven, both legs, while the
design is fresh.** No deferral. No "Rust later." No "Swift later." Each unit
ships both legs before the next unit begins.

The order is fixed:

1. **Swift test** — write the test first. It defines the behavior. (TDD: the
   test exists before the code it tests.)
2. **Swift code** — write the implementation that satisfies the Swift test.
3. **Rust test** — write the Rust test, mirroring the Swift test's behavior.
   Author it independently from the Swift test's *intent*, not by reading Rust
   code into existence.
4. **Rust code** — write the implementation that satisfies the Rust test.

Swift leads because Swift's `Sources/` and `Tests/` are peer folders: the test
structure mirrors the source structure one-to-one, so a missing test is a
visible structural gap. Rust follows immediately, in the same unit, while the
Swift design is still in working memory.

---

## Iterate at the Interface / file level — never the package level

The unit of iteration is **one interface surface or one source file**, not a
whole package.

- Author Swift test → Swift code → Rust test → Rust code for **one file / one
  interface**, verify both legs, then move to the next file.
- Do **not** write all Swift for a package, then all Rust. That is the failure
  mode that produces parity gaps and divergent legs.
- Do **not** write all tests for a package, then all code. The cycle is
  per-file, tight, and complete before advancing.

Correct rhythm: `FileA.swift test → FileA.swift → file_a.rs test → file_a.rs →
[verify both] → FileB ...`

Wrong rhythm: `[all Swift] → [all Rust]` or `[all tests] → [all code]`.

---

## Swift and Rust are co-authored VERSIONS, not ports

Swift and Rust are two **versions** of the same contract, co-authored in
parallel as a cross-language validation gate. They are not a port of one
another. The design pressure comes from **both legs agreeing** on the best
implementation — if the Rust version reveals a better approach, improve the
Swift version too. Each leg informs and corrects the other.

Other languages (Python, Go, etc.) are **ports**. Only Swift↔Rust are versions.

Never write "Swift port" or "Rust port." Write "Swift version" / "Rust version."

---

## Testing framework

Swift tests use **swift-testing** (`import Testing`, `@Test`, `#expect`,
`#require`) — https://developer.apple.com/xcode/swift-testing/. Not XCTest.
This is the design premise for the Swift test suite.

Rust tests use inline `#[cfg(test)]` / `#[test]` modules in the source file.

---

## Conformance

For shared deterministic operations, the Swift and Rust versions must produce
**bit-identical** output on shared test vectors. This is a behavioral contract
(state it in specs as such) — it is the reason both legs are co-authored.

A validation/conformance harness that proves an *algorithm* is mathematically
correct is **not** a substitute for a library test that proves the *shipped
type* works. Author library tests at the package level regardless of harness
coverage.

---

## Hard prohibitions

- **No deferral.** "Defer the Rust," "TODO: Rust version," "Swift-only for now"
  are prohibited. If a real platform constraint prevents a Rust version (e.g.
  Apple-specific accelerator), that is a *behavioral fact* about the version —
  state it plainly, never as a justification for skipping a leg.
- **No circular tests.** Never write a test whose only purpose is to confirm
  the code that already exists. The test defines the behavior; the code
  satisfies the test — in that order.
- **No package-level batching.** Iterate per file/interface.
- **No editing released production source to make a test pass.** If a test
  reveals a real bug, STOP and report — do not silently change the code under
  test.
- **No implementation/process language in specs.** Specs describe behavior,
  types, invariants, errors, conformance requirements — never "how we built
  it," never which language led, never port status.

---

## The self-check before any commit

- Did the test come before the code? (both legs)
- Are both legs present for this unit? (Swift + Rust, this file/interface)
- Is the Swift suite in swift-testing, peer to its source file?
- Do the two versions agree bit-for-bit on shared vectors?
- Did I iterate per file, not per package?
- Did I touch only what this unit requires, leaving released source intact?

If any answer is no, the unit is not done.
