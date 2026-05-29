# Contributing to EideticLib

Thanks for considering a contribution. EideticLib aims to be a small, deterministic, conformance-gated text-to-anchor primitive; that frame shapes what contributions fit naturally and what don't.

## Where contributions land easily

**Gazetteer term improvements.** Adding terms (single or multi-word) to existing UDC codes in `Sources/EideticLib/Resources/UDCSchedule.json`, especially terms that catch real-world morphological variants. Open a PR with the terms added; the conformance tests will tell you if anything broke.

**UDC depth-3 expansion.** The v0.1 schedule has 198 depth-3 codes; the full UDC Summary has roughly 1000. Filling in coverage for high-traffic subdivisions is welcome. Each new code needs a label, description, parent reference, and gazetteer terms. The CC-BY-SA boundary covers schedule additions automatically.

**Wikidata subset refinement.** The Section A entries (UDC anchors) are the highest-leverage targets: each one is the canonical Wikidata concept for a UDC code, and getting them right makes the resolver's output more authoritative. If you find a Section A entry that's anchored to a wrong or obscure Q-ID, open a PR with the corrected Q-ID and a short justification.

**Cross-language conformance vectors.** New entries in `Tests/SharedVectors/lookup_vectors.json` that cover edge cases or morphology patterns are welcome. Add the vector, run both ports, paste the expected outputs.

**Documentation.** README clarifications, API doc improvements (rustdoc and docc), and worked examples are easy to land.

## Where contributions need discussion first

**Algorithmic changes** to the tokenizer, normalizer, stemmer, gazetteer matcher, classifier, or resolver. These have stated specifications in the source (each module's leading comment), and changes need a conformance regression check. Open an issue first and we'll talk through the spec change before you write code.

**New public API surface.** EideticLib's public surface is intentionally small (essentially `lookup`, the data types, and the resolver components). Adding to it expands the maintenance burden. Open an issue describing the use case; often there's a way to support what you need without growing the API.

**New runtime dependencies.** Neither port pulls in unused crates or modules. New dependencies need justification; we prefer adding 20 lines of hand-written code to pulling in a 200KB transitive tree.

## What doesn't fit

**Phase 2 cache features** belong in the planned `gnomon-kit-cache` companion crate, not in the base kit. The base kit's deterministic-snapshot guarantee is load-bearing.

**LLM-based resolution** of any kind. EideticLib is the offline-deterministic path by design; calls that need richer language understanding should run against a different layer.

**Locale-specific behavior.** v0.1 is English-only. If you need other languages, open an issue describing the scope; multi-language support is a Phase 3 conversation, not a single PR.

## Development setup

Clone the repo. You'll need:

- **Swift 5.9 or later** (Xcode 15 or higher, or the Swift toolchain on Linux)
- **Rust stable** (1.70 or later)
- **Python 3.10 or later** for the data assembly scripts in `tools/`

The two ports are independent and can be built separately:

```bash
# Swift
swift build
swift test

# Rust
cd rust
cargo build
cargo test
```

The cross-language conformance test runs in both:

```bash
# Swift
swift test --filter SharedVectorConformanceTests

# Rust
cd rust
cargo test shared_vector_conformance
```

## Pull request checklist

Before opening a PR:

1. Both ports build cleanly (`swift build` and `cargo build` from the right directories).
2. Both test suites pass (`swift test` and `cargo test`).
3. The cross-language conformance test passes in both languages.
4. New code follows the existing style: leading doc comments that describe what the module does and why, not just what the functions are.
5. No em-dashes in prose. The repo uses standard hyphens, parenthetical commas, or sentence breaks instead. This is a style choice across the project; please match it.

## Voice

Documentation and comments are factual rather than promotional. The kit does what it does; we describe it that way. No "blazingly fast," no "elegant," no marketing adjectives. If a thing is genuinely surprising or hard-won, the comment can say so plainly; that's different from selling.

## License and copyright

By contributing, you agree that your contributions are licensed under the same terms as the rest of the project: MIT or Apache 2.0 for code (your choice; we keep both options open for downstream), CC-BY-SA 3.0 for additions to `Sources/EideticLib/Resources/UDCSchedule.json`, and CC0 for additions to `Sources/EideticLib/Resources/WikidataSubset.json`. Don't add data to the wrong file; the license boundary depends on the file path.

If your contribution is substantial and you'd like to be acknowledged in a separate AUTHORS file, mention it in your PR.

## Reporting issues

Issues are welcome. For bug reports, include:

- The input that triggered the unexpected behavior (the exact string).
- The expected output and the actual output.
- The Swift / Rust version and the OS.
- Whether the issue reproduces in both ports or only one.

For feature requests, describe the use case before the proposed feature. The use case is the load-bearing part; the feature is often a different shape than the requester originally imagined.
