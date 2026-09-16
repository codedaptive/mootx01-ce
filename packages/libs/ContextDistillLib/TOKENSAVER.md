# Complete Distiller, orderReducer and Skim

Authoritative contracts: [Specification](../../../docs/reference/CONTEXTDISTILLLIB_SPEC.md)
and [Swift/Rust interface](../../../docs/reference/CONTEXTDISTILLLIB_INTERFACE.md).
This file is a quick invocation guide, not a separate contract.

All three operations are native Swift and Rust library functions. No Python,
model, network call or database is involved. The Python lab is the test oracle.

## Complete distillation (normal rendering)

`completeFormV6` / `CompleteFormV6` replaces normal read-time rendering. It
compacts eligible clocks, JSON structures, duplicate declarations, repeated
lines and timestamp prefixes while retaining the complete source representation.
It does not select a subset of passages. Every applied stage must save space
according to the supplied counter, including its legend.

```swift
let output = ContextDistiller().distill(
    DistillationInput(original: body), converter: .completeFormV6)
let text = output.aiText
// Exact tokenizer accounting is available on the pure reducer:
let reduced = try CompleteContentReducer.distill(body, count: countTokens)
```

```rust
use context_distill_lib::{converter::ContextDistillConverter,
    distiller::ContextDistiller, input::DistillationInput};
let output = ContextDistiller::new().distill(
    &DistillationInput::new(body, ""), ContextDistillConverter::CompleteFormV6);
// complete_content::CompleteContentReducer::distill(body, count_tokens)
// exposes an exact counter callback when the caller has a tokenizer.
```

The standard dispatch uses the existing advisory token estimator; it does not
claim a particular external tokenizer's savings. Identity is
`complete-form@complete-form-visible-v6`. The v22 selectable recipe is removed.
The explicit v23.2 recipe and its shared selection primitives remain unchanged.
Invalid reserved representation syntax fails unchanged at the standard dispatch
and records `fallback_unchanged` in selection details; the pure reducer returns
an error. An explicitly supplied enrichment trailer remains complete.

## Bounded attributed recall

ARIA's `RecallDistillation` helpers use the v23.2 attributed recipe for both
`distilled` reads and the distilled field of `full` reads. Before classification,
they admit at most 32,768 UTF-8 bytes. The product setting
`recall_distillation.max_source_bytes` can lower this ceiling, not raise it.
Invalid values use the default; nonpositive integers clamp to one byte.

Recall enables `boundedSelection: true` in Swift and
`distill_with_selection_budget(input, converter, true)` in Rust. The selector
admits at most 256 atoms and charges at most 100,000 deterministic work units.
On any budget exhaustion the helper returns the **complete original**, not a
prefix or a partially selected result. Savings may be zero. Authorization,
full-depth fields, CompleteFormV6 hydration and explicit Skim do not change.

The ordinary offline `distill` invocation retains its frozen selection behavior;
the bounded option does not replace the recall helper's pre-classification byte
check. New request-facing consumers must use that admission check too.

## Prototype orderReducer and Skim

Both operate on **already distilled text**; neither calls the Distiller again.

```swift
let ordered = PassageViews.orderReducer(body: text, query: question)
let preview = try PassageViews.skim(body: text, query: question, budget: 512)
// preview.text + preview.continuation == preview.fullText
```

```rust
use context_distill_lib::passage_views::{order_reducer, skim};
let ordered = order_reducer(&output.ai_text, question);
let preview = skim(&output.ai_text, question, 512, true)?;
// preview.text + &preview.continuation == preview.full_text
```

`dependency-groups-utf8-v1` scores whole groups by lexical query overlap, with
stable source-order ties. Empty queries preserve source order. Headings, labels,
lists and fences retain their dependencies. Ambiguous structures conservatively
stay together. Skim uses a positive **UTF-8 byte** budget and never skips a group
to fit. An oversized first group is returned whole with `budgetHonored=false`
(`budget_honored` in Rust). Source spans use Unicode scalar/code-point offsets.

The result carries both complete text and literal remainder for library callers.
A future wire API must choose which text to send; it must not send preview and
full text together. The remainder is not an authorized continuation token.
No new ARIA skim option or hidden query ordering is activated by this port.

## Retirement and responsibilities

GeniusLocusKit's existing shared hydration renderer selects the complete converter.
Consolidation uses that renderer on its complete combined source and independently
retains the existing structural fingerprint calculation. SubstrateML's old
core-first/tail text assembly is removed; its text-producing compatibility path
delegates to this library. Fingerprint-only callers disable rendering entirely.
NeuronKit retains its confidence, success and injection-depth contract, with the
new complete rendering replacing the old core-first text.

Skim is a separate capability, never the normal consolidation/lens result.
Ordering is a prototype, not a semantic ranker. Model-assisted rewriting remains
outside these APIs.

## Boundaries and verification

Unsupported JSON numeric/ambiguous forms are kept unchanged rather than
normalized through lossy floating-point conversions. Deep JSON inputs have a
bounded parser. Complete representations can contain decoding legends; mechanical
reconstruction is not by itself proof of AI comprehension. Ordering can legitimately
make no change; useful skim selectivity still needs the blinded lab evaluation.

Focused native tests include frozen synthetic Python outputs for complete-form
stages and passage views, invalid reserved syntax, full-source dispatch, Unicode
boundaries, explicit oversized groups, and fingerprint equality with rendering
enabled/disabled. Existing v23.2 golden tests remain. Historical v22 fixtures are
retained only for shared classifier/selection coverage, not an active v22 recipe.

Run `swift test --package-path packages/libs/ContextDistillLib` or
`cargo test --manifest-path packages/libs/ContextDistillLib/rust/Cargo.toml`
with an explicit task-owned build directory. The separate TokenSaver lab
implementation guide gives the qualification workflow for real semantic tests;
synthetic native parity is not semantic qualification.
