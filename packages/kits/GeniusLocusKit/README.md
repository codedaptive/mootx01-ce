# GeniusLocusKit

**Status:** ✅ Built — Mission 8 (GLK-01..08) complete; review gate pending  
**Standalone:** Yes — the full substrate; use when you need multiple estates or the full Brain layer

The unified personal knowledge substrate. GeniusLocusKit composes LocusKit + VectorKit + CorpusKit and adds the ability to coordinate N estates — cross-estate queries, federation, and the Brain layer running across the composition. If LocusKit gives you one estate, GeniusLocusKit gives you a fleet of them working together.

## Standalone value

Use GeniusLocusKit to build:
- **Multi-estate coordination** — open and query N estates simultaneously, federate across them, mediate cross-estate operations
- **Spatial memory + RAG + knowledge graph in one** — all three storage tiers unified behind a single surface
- **A living substrate** — Brain layer runs autonomically: standing-signal daemons, matrix layer, training pipeline, provenance discipline

## The key distinction from LocusKit

| | LocusKit | GeniusLocusKit |
|-|----------|----------------|
| Estates | One | One to N |
| Storage tiers | Structured + KG only | Structured + KG + Vectors + RAG |
| Brain layer | No | Yes — signals, daemons, matrix |
| Federation | No | Yes |

## What this kit provides

GeniusLocusKit composes LocusKit + VectorKit + CorpusKit and adds:

- **One canonical content object** — LocusKit owns each GLK Drawer; CorpusKit builds BM25/provider-derived state over that same Drawer and never stores a copied chunk/document body in GLK mode
- **Optional historical migrations** — the current runtime is history-free; applications declare their oldest supported estate-format floor and compile only the required migration capsules

- **N-estate coordination** — open, manage, and query multiple estates; mediate cross-estate operations (spec invariant I-13)
- **Unified nine-verb surface** — `capture`, `recall`, `withdraw`, `mutate`, `expunge`, `reanchor`, `learn`, `propose`, `associate` — across all three storage tiers
- **Brain layer:**
  - Standing-signals daemon ecology — six default signals running autonomically (spec § 11)
  - Matrix layer — M·M.T similarity matrix, asymmetry profile (spec § 11.6)
  - Training daemon — gated by estate size threshold Q34
  - Provenance discipline — confirmation propagation, audit-trail recovery (spec § 9.4, § 6.8)
- **Eight noun shapes** — Drawer, Tunnel, KGFact, Vector, DiaryEntry, Proposal, Association, LearnedReference
- **All eight theorems demonstrable** — Theorems 4, 6, 7, 8 are GeniusLocusKit's responsibility

## What this kit does NOT provide

- Single-estate only → use **LocusKit** standalone
- Raw vector search only → use **VectorKit** standalone
- Raw RAG only → use **CorpusKit** standalone
- AI reasoning functions → **NeuronKit**
- Behaviour recipes → **CognitionKit**
- MCP server → **ARIA_MCP**

## Platform

- **Swift** — Apple Silicon, macOS 15+, iOS 18+
- **Rust** — PC/Linux x86_64, Linux aarch64 (built in parallel; conformance-gated against shared test vectors)
- Imports LocusKit, VectorKit, CorpusKit
- Swift 6 strict concurrency

## Build order

```
Phase 1 (parallel):  LocusKit ←→ VectorKit
Phase 2:                          VectorKit → CorpusKit
Phase 3:   LocusKit + VectorKit + CorpusKit → GeniusLocusKit  ← here
Phase 4:                                   GeniusLocusKit → ARIA_MCP
```

## Done-definition (v1.0)

Per `docs/reference/GENIUSLOCUSKIT_SPEC.md`:
- All nine verbs across all three storage tiers
- N-estate coordination operational
- Brain layer: six default signals, matrix layer, training daemon
- All eight noun shapes demonstrable
- Theorems 4, 6, 7, 8 demonstrated

## Key specs

- `docs/reference/GENIUSLOCUS_ARCHITECTURE_SPEC.md` — full spec; §§ 4, 11, 13, 15
- `docs/reference/GENIUSLOCUSKIT_SPEC.md` — kit spec
- `docs/engineering/GENIUSLOCUS_ENGINEERING_COOKBOOK.md`

## Scope

**Belongs here** if it touches: N-estate coordination, cross-estate operations, composition of the three substrate kits, Brain layer, federation, the eight noun shapes, theorem demonstrations.

**Does not belong here** if it: operates on a single estate only → LocusKit · belongs in one storage kit → that kit · implements AI reasoning → NeuronKit · sequences behaviour recipes → CognitionKit · exposes MCP → ARIA_MCP.
