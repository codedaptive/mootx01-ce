# MOOTx01 Documentation

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

**You want to know why something was built the way it was.**
[`decisions/`](decisions/) holds the Architecture Decision Records.
Every load-bearing choice is captured with the question asked,
candidates considered, evidence gathered, and disposition. Code
comments cite decision records by filename.

**You are implementing against the substrate.**
[`engineering/`](engineering/) holds implementation-grade material:
cookbooks that translate spec into code, the engineering reference
suite, methodology notes, and narrative records of major engineering
phases.

**You want evidence behind the claims.**
[`validation/`](validation/) holds the claims ledger, design
constraints, validation plan, and recorded audits. This is what
turns architectural assertions into testable propositions.

**You are looking for history.**
[`archive/`](archive/) holds superseded specs, historical math
notes, and legacy product names. Preserved for traceability; not
authoritative.

## Conventions

Documents use UPPER_SNAKE_CASE naming. Versioned documents carry a
`_vX.Y` suffix; dated artifacts carry a `_YYYY-MM-DD` suffix.

Each subdirectory has its own README explaining its conventions in
more detail.
