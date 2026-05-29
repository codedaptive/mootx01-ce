# CognitionKit

**Status:** 🔲 Not yet built — spec defined at `docs/specs/COGNITIONKIT_SPEC_v0.1.md`  
**Standalone:** No — sequences NeuronKit calls; never implements algorithms itself

The behaviour layer. CognitionKit defines named, reusable workflows built from NeuronKit reasoning calls. If NeuronKit is the engine, CognitionKit is the mission planner — it tells the engine what to do and in what order to achieve a goal, without implementing any capability itself.

## Standalone value

Use CognitionKit to add to any GeniusLocusKit + NeuronKit application:
- **Named behaviours** — `FulcrumDailyFraming`, `MigrationBenchmark`, `ScenarioSkill` — pre-built workflows a user or AI agent can invoke by name
- **Composable recipes** — build new behaviours by combining existing NeuronKit calls; no algorithm implementation required
- **Webhook-confirmed async workflows** — trigger a behaviour, get a webhook confirmation when it completes; CognitionKit handles the async coordination

**A recipe is a sequence of NeuronKit calls, not an implementation.** If a recipe step needs a new capability, that capability belongs in NeuronKit first. A recipe that implements an algorithm has leaked across its boundary.

## What this kit provides

- **The `Recipe` protocol** — the conformance contract all v1 recipes implement
- **v1 recipes:** `FulcrumDailyFraming`, `MigrationBenchmark`, `ScenarioSkill`
- **Recipe composition primitives** — build new recipes from existing NeuronKit calls
- **Webhook registration and confirmation** — async trigger → webhook delivery back through ARIA_MCP

**CognitionKit has no direct substrate access.** Every read or write passes through NeuronKit or a GeniusLocusKit estate handle. It never executes SQL, never touches LocusKit, VectorKit, or CorpusKit directly.

## What this kit does NOT provide

- Algorithms of any kind → **NeuronKit**
- Storage → **LocusKit / VectorKit / CorpusKit / GeniusLocusKit**
- Estate verb definitions → **GeniusLocusKit**
- MCP server → **ARIA_MCP**

## The three-question recipe design check

1. Does this step need an algorithm? → implement it in **NeuronKit** first
2. Does this step need to store something? → it goes through **GeniusLocusKit** verbs
3. Is this step sequencing calls that already exist? → **CognitionKit** ✓

## Platform

- **Swift** — Apple Silicon, macOS 15+, iOS 18+
- **Rust** — PC/Linux x86_64, Linux aarch64 (built in parallel; conformance-gated against shared test vectors)
- No direct database dependencies
- Swift 6 strict concurrency

## Key specs

- `docs/specs/COGNITIONKIT_SPEC_v0.1.md` — full spec
- `docs/specs/NEURONKIT_SPEC_v0.1.md` — every capability CognitionKit can call into
- `docs/validation/substrate_math_performance/glref-swift-CognitionKit.swift` — reference implementation of the 18 retrieval primitives (§11)

## Mission placement rules

**Belongs here** if it: defines or modifies a `Recipe` conformance, sequences NeuronKit calls into a named workflow, handles webhook registration or confirmation.

**Does not belong here** if it: implements an algorithm → NeuronKit · changes storage → substrate kit · exposes MCP tools → ARIA_MCP.
