# MOOTx01 Documentation

> **Channel:** this documentation is from `develop/1.1.x`, currently
> `1.1.0-beta-04`. Stable installers and the public plugin continue to track the
> supported 1.0 line. Pin the beta version and commit when evaluating behavior.

This directory holds every public-facing document for the MOOTx01
substrate. The layout is organized by reader intent, not author
intent: each top-level directory answers a different question a
reader might arrive with.

## How to find what you want

**You are new and want to understand what this is.**
Start in [`start-here/`](start-here/). Three guides at three depths:
`SUBSTRATE_FOR_USERS.md` (plain language), `SUBSTRATE_FOR_DEVELOPERS.md`
(building on top), `SUBSTRATE_FOR_MAINTAINERS.md` (porting and operating).

**You want to know what the system is, conceptually.**
[`concepts/`](concepts/) holds the canonical definitions: topology,
the MOOTx01 + ARIA canon, the kit interface map, case studies that
exercise the architecture against real scenarios, and the published
paper draft. Read here when you need durable definitions.

**You need the public API surface of a specific package.**
[`reference/`](reference/) holds one specification per kit/lib plus
the cross-cutting protocol and encoder specs. This is the contract
surface — what each package exposes and what it promises.

**You want the standalone open-source SDK repositories.**
[`../SDK.MD`](../SDK.MD) maps all 17 Apache-2.0 packages to
[`moot-memory`](https://github.com/codedaptive/moot-memory),
[`moot-semantics`](https://github.com/codedaptive/moot-semantics),
[`moot-system`](https://github.com/codedaptive/moot-system), and
[`moot-core`](https://github.com/codedaptive/moot-core). Each repository has
its own documentation index, concrete Swift and Rust install names, package
overviews, implementation details, AI maps, and source provenance.

**You are developing the 1.1 Apple app or retrieval engine.**
[`Mootx01-App`](../apps/Mootx01-App/README.md) documents the native
macOS/iOS application, its Apple surfaces, host modes, sync, LAN server,
federation, privacy boundaries, build steps, and current limitations.
[`CorpusKit`](../packages/kits/CorpusKit/README.md) documents the 1.1
standalone/attached content engine, canonical identity, provider ensemble,
queue and restart behavior, migration, and Swift/Rust test commands.

**You want to know why something was built the way it was.**
[`decisions/`](decisions/) holds the Architecture Decision Records.
Every load-bearing choice is captured with the question asked, candidates
considered, evidence gathered, and disposition. Code comments cite decision
records by filename.

**You are implementing against the substrate.**
[`engineering/`](engineering/) holds implementation-grade material:
cookbooks that translate spec into code, the engineering reference
suite, methodology notes, and narrative records of major engineering
phases.

**You want evidence behind the claims.**
[`validation/`](validation/) holds the claims ledger, design
constraints, validation plan, and recorded audits. This is what
turns architectural assertions into testable propositions.

**You operate, bridge, or benchmark the product.**
The operator-facing application guides live with their source:
[`MOOTx01-App`](../apps/Mootx01-App/README.md) documents the native Apple
presentation and local-host app;
[`moot-mgr`](../apps/moot-mgr/README.md) documents the dashboard, read API,
control plane, configuration, and troubleshooting;
[`moot-bridge`](../apps/moot-bridge/README.md) documents the optional
two-backend MCP multiplexer and its failure model; and
[`moot-math-benchmark`](../apps/moot-math-benchmark/README.md) documents the
benchmark protocol and tracked evidence. The
[`Obsidian vault guide`](start-here/OBSIDIAN_VAULT.md) covers user-facing
export, import, drift detection, and resync.

**You want the lessons behind the product work.**
[`articles/`](articles/) holds the reviewed learning series. Choose the
**You want the lessons behind the product work.**
[`articles/`](articles/) holds the reviewed repository editions of an ongoing
series published on LinkedIn and Off-Axis Labs on Substack. As each article
pair is written, reviewed, and released, it is added here. Choose the
[`business/`](articles/business/) editions for product decisions, operating
consequences, and team lessons. Choose the
[`technical/`](articles/technical/) editions for implementation evidence,
source trails, and diagrams. The article index keeps each business and
technical edition together as a pair.

**You are looking for history.**
Use the Git history and dated validation records. Superseded material is not
published as an authoritative `docs/archive/` tree on this branch.

## Conventions

Documents use UPPER_SNAKE_CASE naming. Versioned documents carry a
`_vX.Y` suffix; dated artifacts carry a `_YYYY-MM-DD` suffix.

Each subdirectory has its own README explaining its conventions in
more detail.
