# SubstrateLib — the substrate orchestration layer

The fourth package of the four-package substrate split, and the one that
composes the other three into a *writable* substrate. SubstrateLib owns
the control surface: the nine-verb mechanics, the row-state automaton,
and the AuditGate write gate. It depends on `SubstrateTypes` (values),
`SubstrateKernel` (hot-path kernels), and `SubstrateML` (cold-path
algorithms), and — as of the 2026-05-29 addendum — **no longer
re-exports them** (the transitional `@_exported` shim was removed).

> Not deprecated. The earlier "three-package atomic swap that deletes
> SubstrateLib" plan was reversed by the 2026-05-29 addendum: the verb
> mechanics + row-state automaton fit none of Types/Kernel/ML, so
> SubstrateLib is **retained** as the orchestration package.

## What lives here

| Symbol | Role |
|---|---|
| `Verbs` | The nine-verb substrate mechanics (capture, reanchor, mutate, withdraw, expunge, recall, propose, associate, learn) |
| `RowStateAutomaton` | The row-state finite-state machine — legal transitions + I-22 forbidden combinations |
| `AuditGate` | The single write gate (below) |

(The Rust leg also carries the cookbook scalar-oracle reference impls for
higher layers — `working_set`, `sqlite_tail`, `cognition_kit`,
`cognition_bundle`, `actuator`, `dreaming` — until those kits get their
own Rust crates. They are reference scaffolding, not substrate atomics.)

## AuditGate — the only legitimate path to a mutation

Every write — including capture (I-26) — passes through `AuditGate.admit`.
The `prior == nil` branch is capture; `prior != nil` branches are the four
mutators. The gate runs `ForbiddenCombinations.check` over the merged
basis (I-22), validates the transition via `RowStateAutomaton.validate`
(why AuditGate lives here, not in SubstrateKernel — it depends on the
orchestration FSM), seals the event per custody mode (I-27, using
`SubstrateKernel`'s `SHA256`), and emits one `AuditEvent`. The bitmap
field reads it performs go through `SubstrateKernel`'s `BitField`.

```swift
let event = try AuditGate.admit(
    verb: .capture, prior: nil,
    writes: fieldWrites, actor: actor, hlc: hlc.tick()
)
```

```rust
let event = AuditGate::admit(
    Verb::Capture, None, &field_writes, &actor, hlc.tick()
)?;
```

Do not bypass the gate. Storage layers (PersistenceKit) ENFORCE the
gate's contract on receive — they refuse a write missing a required HLC
or seal — but do not author HLCs or seals (cookbook §5.11). The gate is
the only authoring point; that is what makes corruption unrepresentable.

## Who depends on SubstrateLib

Only the **verb-drivers** depend on SubstrateLib directly — the kits that
drive the substrate verbs / row-state machine. Today that is **LocusKit**
(it uses `RowStateAutomaton` + `AuditGate`). Every other kit depends on
the precise sub-package(s) it uses (`SubstrateTypes` / `SubstrateKernel` /
`SubstrateML`), not on SubstrateLib.

```swift
.package(path: "../../libs/SubstrateLib"),       // verb-drivers only
// targets: dependencies: ["SubstrateLib"]
```

```toml
substrate-lib = { path = "../../libs/SubstrateLib/rust" }   # verb-drivers only
```

If you only need a value type, a kernel, or an ML primitive — depend on
`SubstrateTypes` / `SubstrateKernel` / `SubstrateML` directly. See each
successor's `AGENTS.md`.

## Conformance

The cross-language-pinned conformance vectors pass four-way across the
split. See
`../../../docs/engineering/HARNESS_REFERENCE.md` for the
canonical index and verification commands, and cookbook v1.0 §20 + the
2026-05-29 addendum for the split rationale.

## License

MIT OR Apache-2.0.
