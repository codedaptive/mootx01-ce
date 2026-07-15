# Blast Radius Report — SUBSTRATE-ML-CONFLICT-CUE-UNICODE

**Baseline:** swift test pass count at mission start: 485
**Rust baseline:** cargo test --lib pass count at mission start: 297
**Mission:** Fix ConflictCue Swift/Rust tokenizer divergence for non-ASCII input (U+0130 İ)
**Symbols being changed:**

## Symbol 1: ConflictCue.tokenize(_:) — Swift

**Change class:** semantic (behavior change for non-ASCII input; signature unchanged)
**Scope:** internal

**Problem:** Swift iterates `s.lowercased()` over `Character` (grapheme clusters).
For U+0130 İ, `lowercased()` yields "i\u{0307}" — a single grapheme cluster that
passes the `ch >= "a" && ch <= "z"` Character comparison, so the combining mark
is swallowed into the ASCII token. Rust iterates `s.to_lowercase().chars()` over
Unicode scalars — '\u{0307}' (U+0307, combining dot above) fails `is_ascii_lowercase()`
and acts as a token separator.

**Fix:** Change Swift tokenizer to iterate `s.lowercased().unicodeScalars`, test
`scalar.value` against ASCII ranges (same semantics as Rust's `is_ascii_lowercase()`
and `is_ascii_digit()`). No public API change. Tokenizer contract comment in file
header is already accurate ("ASCII-safe lowercasing").

### Call sites

| File | Line | Source | Classification | Justification |
|---|---|---|---|---|
| Sources/SubstrateML/ConflictCue.swift | 123–124 | direct | MUST_UPDATE | The buggy lines — change to unicodeScalars iteration |
| Tests/SubstrateMLTests/ConflictCueTests.swift | 20–24 | grep | MUST_UPDATE | Add İ regression test (tokenizer_contract) |
| rust/src/conflict_cue.rs | 223–227 | grep | MUST_UPDATE | Add mirrored İ regression test (tokenizer_contract) |

No callers of `ConflictCue.tokenize` exist outside SubstrateML (confirmed via
`rg -n "ConflictCue\.tokenize"` — only test file in Tests/). No docs/canon
references to ConflictCue found.

### Summary
- MUST_UPDATE: 3 sites
- INTENTIONALLY_LEFT: 0
- RESCOPE_REQUIRED: 0

The change is purely within the SubstrateML package. Public API (`evaluate(_:_:)`)
signature is unchanged. The behavioral fix corrects divergence for non-ASCII input
that lowercases to a combining-mark sequence; all ASCII-only input (which covers all
existing test vectors) produces identical output before and after the fix.
