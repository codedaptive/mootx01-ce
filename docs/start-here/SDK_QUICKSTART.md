---
title: "MOOTx01 SDK Quickstart"
subtitle: "Build on the substrate: open an estate, capture a memory, recall it"
author: "MOOTx01 maintainers"
date: "2026-06-15"
---

# SDK Quickstart

> **Looking for the standalone Apache-2.0 SDKs?** Start with
> [`moot-memory`](https://github.com/codedaptive/moot-memory),
> [`moot-semantics`](https://github.com/codedaptive/moot-semantics),
> [`moot-system`](https://github.com/codedaptive/moot-system), or
> [`moot-core`](https://github.com/codedaptive/moot-core). The complete public
> package map is [`SDK.MD`](../../SDK.MD). This guide uses the MOOTx01 product
> source tree and its `GeniusLocusKit` composition layer.

This is the developer "build on top of MOOTx01" path. If you just want to *use* MOOTx01 with
your AI client, see [`INSTALL_SURFACE.md`](INSTALL_SURFACE.md) instead. Here you'll add the
substrate to a project, open a memory estate, **capture** a memory, and **recall** it — the
core write→read loop.

## It's modular

MOOTx01 is not one monolith. The product tree is modular. Seventeen libs and
kits are also published through the four standalone Apache-2.0 SDK repos.
Product-only composition packages such as `GeniusLocusKit` remain in the
MOOTx01 source tree. You depend only on the modules your integration needs.

**GeniusLocusKit (GLK) is the composition layer**, not a mandatory gate. It unifies the kits
into one estate and exposes the ARIA verbs (capture, recall, …) with audit, grants, recall
composition, and federation. From `packages/SDK.md`:

> GLK is not the universal access gate; it is the composition layer for apps that opt into
> estate semantics. Direct kit and storage use is valid outside GLK estate mode, but those
> operations do not receive GLK-level audit, grants, federation, or composed recall guarantees
> unless explicitly routed through GLK.

So: **estate mode (GLK)** is the front door and what this quickstart uses. If you only need one
narrow capability, you can depend on a single kit directly (see *Going lighter* below).

## Add the dependency

**Swift (macOS/iOS) — `Package.swift`:**

```swift
dependencies: [
    .package(path: "../packages/kits/GeniusLocusKit"),
    .package(path: "../packages/kits/LocusKit"),         // estate verbs (capture/recall) + frames
    .package(path: "../packages/kits/PersistenceKit"),   // storage backends
],
targets: [
    .target(name: "YourApp", dependencies: [
        "GeniusLocusKit",
        .product(name: "LocusKit", package: "LocusKit"),
        .product(name: "PersistenceKitInMemory", package: "PersistenceKit"),
    ]),
]
```

`PersistenceKit` ships `PersistenceKitInMemory` (ephemeral, great for trying it out) and
`PersistenceKitSQLite` (the local-first on-disk backend). Swap the product to switch.

**Rust (Linux/Windows) — `Cargo.toml`:**

```toml
[dependencies]
genius-locus-kit = { path = "../packages/kits/GeniusLocusKit/rust" }
locus-kit        = { path = "../packages/kits/LocusKit/rust" }       # estate verbs + frames
persistence-kit  = { path = "../packages/kits/PersistenceKit/rust" }
```

## Hello, estate (Swift)

Open an estate, capture a memory, recall it. (This is lifted from the kit test suite, so it
compiles as-is.)

```swift
import Foundation
import GeniusLocusKit
import LocusKit
import PersistenceKit
import PersistenceKitInMemory

// 1. A storage backend for the estate (in-memory here; use PersistenceKitSQLite to persist).
let config = EstateConfiguration(estateID: UUID(), backend: .inMemory)
let storage = InMemoryStorage(configuration: config)

// 2. Open the estate through GLK (the composition front door).
let kit = GeniusLocusKit()
let owner = OwnerCredentials(ownerIdentifier: "my-app")
_ = try await LocusKit.Estate.create(storage: storage, owner: owner)
let handle = try await kit.open(storage: storage, owner: owner)
let estate = try await kit.estate(for: handle)

// 3. Capture a memory. A CaptureFrame is the content plus where it lives and how it's anchored.
let frame = CaptureFrame(
    content: "We decided to use SQLite for local storage.",
    channel: .typed,
    room: "decisions",
    latticeAnchor: .udc("decision"),   // a coarse subject anchor; .udc(<code>) is the easy form
    addedBy: "my-app",
    embeddingModelID: "default")
let drawer = try await estate.capture(frame)

// 4. Recall it. The filter chain selects what to return.
//    NOTE: a freshly captured drawer is `.unconfirmed`; recall prepends a default
//    `.userConfirmed` filter for named filters, so include `.unconfirmed` to see new captures.
let recall = RecallFrame(
    filterChain: [.inRoom("decisions"), .currentlyBelieve, .unconfirmed],
    hydrationLevel: .full)          // .full loads the content blob; .structured omits it
let stream = await estate.recall(recall)
var rows: [Drawer] = []
for await page in stream { rows.append(contentsOf: page.rows) }

print(rows.first?.content ?? "nothing recalled")   // → "We decided to use SQLite for local storage."
```

That's the whole loop: `capture(CaptureFrame) -> Drawer`, then `recall(RecallFrame) -> RecallStream`
(an async, paged sequence of `RecallPage`, each with `.rows: [Drawer]`).

## The same in Rust

The same write→read loop. The idioms differ: it's synchronous, you pass `now` (epoch seconds)
explicitly for determinism, recall returns a `Vec<Drawer>` directly (no async stream), and the
frame fields are snake_case. (Also lifted from the kit tests.)

```rust
use std::sync::Arc;
use genius_locus_kit::{EstateCoordinator, EstateHandle};
use locus_kit::drawer_store::DrawerStore;
use locus_kit::drawer_store_inmemory::InMemoryDrawerStore;
use locus_kit::drawer_operational::CaptureChannel;
use locus_kit::estate_types::{LatticeAnchor, OwnerCredentials};
use locus_kit::filter::{Filter, RecallFrame};
use locus_kit::frames::CaptureFrame;

const NOW: i64 = 1_700_000_000; // epoch seconds (locus_kit stores dates as ISO8601 text)

// 1. Open the estate. The coordinator is the Rust front door; `open` takes an
//    in-memory drawer store and a zoom window (low, high).
let mut coord = EstateCoordinator::new();
let store: Arc<dyn DrawerStore> = Arc::new(InMemoryDrawerStore::new(NOW, None).unwrap());
let handle = coord.open(store, OwnerCredentials::new("my-app"), 0, 100).expect("open");

// 2. Capture a memory.
let frame = CaptureFrame::new(
    "We decided to use SQLite for local storage.",
    CaptureChannel::Typed,
    "decisions",                    // room
    LatticeAnchor::udc("decision"), // coarse subject anchor
    "my-app",                       // added_by
    "default",                      // embedding_model_id
);
let drawer = coord.capture(&handle, frame, NOW).expect("capture");

// 3. Recall it. Include Filter::Unconfirmed so the fresh capture isn't hidden by the default.
let rows = coord
    .recall(&handle, RecallFrame::new(vec![Filter::Unconfirmed]), NOW)
    .expect("recall");
println!("recalled {} row(s); captured id = {}", rows.len(), drawer.id);
```

## Where your data lives

The estate is **local-first**: storage is a `PersistenceKit` backend you inject. Use
`PersistenceKitInMemory` to experiment, `PersistenceKitSQLite` to persist to a local SQLite
file (dates stored as ISO8601 text). No cloud is required; sync is a separate, optional concern
(`ConvergenceKit`).

## Going lighter (direct kit)

If you don't need estate semantics, you can depend on a single kit and use it directly — e.g.
`VectorKit` for nearest-neighbour search, or `LocusKit` for a single estate's drawers — without
GLK. You give up GLK's audit, grants, federation, and composed recall, but the modules are
designed to stand alone. That's the "modular" promise: take only what you need.

## Next steps

- **Per-kit contracts** — `docs/reference/<KIT>_INTERFACE.md` (the exact API surface for each
  kit, Swift and Rust).
- **The substrate, conceptually** — [`SUBSTRATE_FOR_DEVELOPERS.md`](SUBSTRATE_FOR_DEVELOPERS.md)
  (thirteen layers, two minutes each).
- **Worked examples** — the runnable apps `examples/MootNotepad`, `examples/MootTodo`, and
  `examples/MootCalendarIngest`, plus the kit `Tests/` (the most precise, always-compiling
  reference — every snippet above is lifted from there). *(`examples/SDK/*` are aspirational
  stubs, not yet built — skip them for now.)*
- **The grammar** — `docs/concepts/ARIA_LEXICON.md` (one noun, nine verbs, four adjectives).
