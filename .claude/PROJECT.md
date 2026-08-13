---
tier: project
repo: mootx01-ce
toolchains: [swift, rust]
status: active
created: 2026-08-13
updated: 2026-08-13
---

# PROJECT: mootx01-ce

Tier 3. Repo-specific lookup for coding agents. Read after your fleet
definition and your toolchain file.

- Tier 1 `shared/agents_source/<agent>.md` -- who you are, portable
- Tier 2 `shared/toolchains/swift.md` -- what the commands mean
- Tier 3 this file -- where things are and who owns them here

Nothing in this file applies to any other repo.

## Toolchains

Dual-port Swift/Rust. Swift is the base language, Rust the parallel
port. Both must pass.

| Task | Command |
| :--- | :--- |
| Build both ports | `make build` |
| Test both ports | `make test` |
| Swift only | `make test-swift` |
| Rust only | `make test-rust` |
| Single test | `make test-one` |
| Changed only | `make test-changed` |
| Validation suite | `make test-validation` |

`make help` lists the full target set.

Per the Swift toolchain file, run `swift test` from inside the relevant
`Kit/` before every commit. The `make` targets are the aggregate gate;
the per-kit run is the working loop.

## Surfaces and ownership

| Surface | Path | Reach for |
| :--- | :--- | :--- |
| Substrate math | `packages/libs/SubstrateLib` | `newton` |
| Substrate types/kernel/ML | `packages/libs/Substrate{Types,Kernel,ML}` | `newton` for the math, `bilby` otherwise |
| Kits | `packages/kits/` | `bilby`; `newton` when the math is the hard part |
| MCP server | `apps/aria-mcp-server` | `bilby` |
| Benchmarks | `benchmark/`, `benchmark-ee/` | `bilby`; `scorandum` for perf claims |
| SQLite schema, persistence | `packages/kits/PersistenceKit` | `perkins` for security review |

Kits present: AriaMcpKit, CognitionKit, ConvergenceKit, CorpusKit,
GeniusLocusKit, LocusKit, NeuronKit, PersistenceKit, QueueKit, VaultKit,
VectorKit, WorkPacketKit.

There is no RagKit. If a doc references one, the doc is stale.

## Math surfaces

Bitmap columns, Filter algebra, the bitmap evaluator, and the
GeniusLocus matrix layer are the math-heavy areas. Reference material is
in `docs/engineering/substrate_reference`. Read it before writing
algorithm code.

Swift/Rust conformance is four-way: both ports must agree on behavior
and on test coverage.

## Security review triggers

Reach for `perkins` on SQLite schema changes, entity
privacy/sensitivity fields, encryption boundaries, and anything that
moves data off the device.

## Editions

Community edition. `EDITION_BOUNDARY.md` governs what may cross between
editions. EE-only code must not land here.

## Estate

Wings `mootx01` and `mootx01-ce` carry prior blast radius reports and
prior work on target symbols. Query before starting.
