# LocusKit

**Status:** ✅ Built — v0.35, 333 tests passing  
**Standalone:** Yes — use independently, no other kits required

A Swift library for building a single personal knowledge estate. LocusKit gives any application everything needed to create and operate one estate — spatial memory system, knowledge graph, typed bitmaps, nine verbs, audit trail — stored in a single local SQLite file with zero cloud dependency.

## Standalone value

Use LocusKit to build:
- **One estate** — open or create a single `Estate`, capture content, recall by intent, withdraw, mutate, audit
- **A spatial memory system** — wings, rooms, drawers, typed tunnels, knowledge graph facts
- **A private typed knowledge store** — bitmap-indexed content with provenance, trust, sensitivity, and full mutation history

LocusKit is the right kit when you need exactly one estate. For coordinating multiple estates, composing with vector search and RAG, or running the Brain layer across estates, use GeniusLocusKit.

## What this kit provides

- **Five storage nouns:** `Drawer`, `Tunnel`, `KGFact`, `DiaryEntry`, `Manifest`
- **Three bitmap columns per noun:** adjective (epistemic state), operational (capture mechanics), provenance (content origin)
- **One Estate actor:** `Estate.open`, `Estate.create`, `capture`, `recall`, `withdraw`, `mutate`, `expunge`, `reanchor`, `learn`, `propose`, `associate`
- **Filter algebra:** recall by state cluster, trust, sensitivity, content, room, lineage — named intent only, no raw bitmaps at the call site
- **Bitmap evaluator:** compiles Filter chains to operator primitives; default filter insertion; historical XOR reconstruction
- **Audit enforcement:** `bitmap_audit` table, atomic mutation methods, write-protect triggers
- **State and combination validation:** 14 legal transitions, forbidden combination enforcement

## What this kit does NOT provide

- Multiple estates or cross-estate coordination → **GeniusLocusKit**
- Embedding generation or vector search → **VectorKit**
- Content-plus-vector RAG bundles → **CorpusKit**
- Brain layer (standing signals, daemons, matrix layer) → **GeniusLocusKit**
- AI reasoning algorithms → **NeuronKit**
- Behaviour recipes → **CognitionKit**
- MCP server → **ARIA_MCP**

## Platform

- **Swift** — Apple Silicon, macOS 15+, iOS 18+
- **Rust** — PC/Linux x86_64, Linux aarch64 (built in parallel; conformance-gated against shared test vectors)
- Zero external Swift package dependencies
- System SQLite3 framework only
- Swift 6 strict concurrency

## Key specs

- `docs/specs/GENIUSLOCUS_ARCHITECTURE_SPEC_v0.35.md` — §§ 5–8
- `docs/specs/Q1_DECISION_PROVENANCE_BITMAP.md`
- `docs/specs/Q1_DECISION_MANIFEST_SCHEMA.md`
- `.claude/skills/bitmap-patterns/SKILL.md` — mandatory before any bitmap mission
- `.claude/skills/substrate-engineering/SKILL.md` — mandatory before any algorithm mission

## Scope

**Belongs here** if it touches: storage nouns, bitmap columns, DrawerStore, the single Estate actor and its verbs, Filter algebra, bitmap evaluator, audit enforcement, state/combination validation.

**Does not belong here** if it: coordinates multiple estates → GeniusLocusKit · generates embeddings → VectorKit · bundles content+vector → CorpusKit · implements algorithms → NeuronKit · sequences workflows → CognitionKit · exposes MCP → ARIA_MCP.
