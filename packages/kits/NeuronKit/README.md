# NeuronKit

**Status:** 🔲 Not yet built — spec defined at `docs/specs/NEURONKIT_SPEC_v0.1.md`  
**Standalone:** No — operates on top of GeniusLocusKit; never stores directly

The AI algorithms layer. NeuronKit provides the reasoning functions and autonomic daemons that make a GeniusLocusKit estate intelligent over time. If GeniusLocusKit is the database, NeuronKit is the engine that thinks about what's in it.

## Standalone value

Use NeuronKit to add to any GeniusLocusKit application:
- **Reasoning on demand** — diversity ranking, hybrid recall, context synthesis, branch derivation, tournament scoring, scenario elicitation; called explicitly when the application needs them
- **Autonomic background intelligence** — dreaming daemon, maintenance daemon, standing-signals scheduler, SolverBandit, anomaly detection; run continuously without application code driving them
- **Algorithm implementations** — every algorithm in the substrate reference cookbook (§§ 3–15) lives here; NeuronKit is the production implementation of the math

## What this kit provides

**Autonomic functions** (fire without being asked — like breathing):
- Dreaming daemon — scheduled estate maintenance: decay, NMF, calibration, compaction, federation, Bradley-Terry, action-outcome, bundle export
- Maintenance daemon — audit chain monitor, standing-signals scheduler
- SolverBandit — learned algorithm selection via kernel dispatch
- Anomaly detection — drift and outlier monitoring
- Synchronisation daemon — external stream integration

**Reasoning functions** (called explicitly by the application or CognitionKit):
- MMR diversity ranking
- BM25+RRF hybrid recall
- ContextSynthesizer
- Branch derivation
- Tournament scoring (Bradley-Terry)
- Scenario elicitation
- Eigenvalue centrality, community detection, random walks
- Fingerprint and SimHash computation
- Lattice and composite distance

**NeuronKit never stores.** Every read and write goes through the GeniusLocusKit estate handle verb API. NeuronKit never touches a database directly.

## What this kit does NOT provide

- Storage of any kind → **LocusKit / VectorKit / CorpusKit / GeniusLocusKit**
- Behaviour recipes (sequencing of NeuronKit calls) → **CognitionKit**
- MCP server → **ARIA_MCP**

## The three-question placement test

1. Is it storing or retrieving data? → substrate kit
2. Is it an algorithm or an involuntary process? → **NeuronKit** ✓
3. Is it sequencing existing capabilities toward a goal? → CognitionKit

## Platform

- **Swift** — Apple Silicon, macOS 15+, iOS 18+
- **Rust** — PC/Linux x86_64, Linux aarch64 (built in parallel; conformance-gated against shared test vectors)
- Accelerate framework for BLAS/LAPACK
- Metal compute for heavy matrix operations
- Swift 6 strict concurrency

## Key specs

- `docs/specs/NEURONKIT_SPEC_v0.1.md` — full spec
- `docs/specs/GENIUSLOCUS_ARCHITECTURE_SPEC_v0.35.md` — §§ 6–8, 11, 13, 14, 15
- `docs/engineering/GENIUSLOCUS_ENGINEERING_COOKBOOK.md` — every algorithm NeuronKit implements is specified here
- `docs/decisions/DECISION_ACCELERATOR_ROUTING_2026-05-16.md` — mandatory before any kernel mission

## Scope

**Belongs here** if it: implements a named algorithm from the Cookbook (§§ 3–15), implements an autonomic daemon, implements reasoning functions called by CognitionKit, implements the PortableKernel / accelerator backend.

**Does not belong here** if it: stores data → substrate kit · sequences algorithm calls into a workflow → CognitionKit · exposes MCP → ARIA_MCP.
