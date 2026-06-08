# Reference

Specifications. One document per kit or cross-cutting protocol.
This is the contract surface: what each package publishes and what
it promises to consumers. Conceptual framing lives in
[`../concepts/`](../concepts/); the rationale behind each contract
lives in [`../decisions/`](../decisions/); this directory is the
authoritative "what does it do, signed in writing" layer.

## Per-kit specifications

**[`COGNITIONKIT_SPEC_v0.85.md`](COGNITIONKIT_SPEC_v0.85.md)** — the
behaviour recipe layer. Sequences NeuronKit reasoning calls into
named workflows. Contains no algorithms of its own.

**[`NEURONKIT_SPEC_v0.8.md`](NEURONKIT_SPEC_v0.8.md)** — the
algorithm layer. Autonomic processes (daemons, signals,
schedulers) plus reasoning functions (hybrid recall, scoring,
synthesis). Distinguished from CognitionKit by call pattern, not
capability type.

**[`QUEUEKIT_SPEC_v0.8.md`](QUEUEKIT_SPEC_v0.8.md)** — the queue
library. FilesystemBackend and PersistenceKitBackend implementations,
four public methods (`send`, `drain`, `watch`, `reply`), and the
conformance contract every backend must satisfy.

## Cross-cutting protocol and architecture specs

**[`GENIUSLOCUS_ARCHITECTURE_SPEC_v0.8.md`](GENIUSLOCUS_ARCHITECTURE_SPEC_v0.8.md)** —
the substrate's working specification. Data model, verb surface,
bitmap layouts, audit trail, standing signals, conformance rules.
The contract every conforming implementation must satisfy.

**[`ARIA_MCP_SPEC_v0.2.md`](ARIA_MCP_SPEC_v0.2.md)** — the
external access surface, framed as a projection of the ARIA
language onto MCP primitives. Tools, resources, prompts, sampling,
elicitation, and the release plan that phases delivery.

**[`ARIA_MCP_SPEC_v0.1.md`](ARIA_MCP_SPEC_v0.1.md)** — the prior
ARIA_MCP spec. v0.2 partially supersedes it (the three-call-mode
framing and the all-modes-required conformance rule). The
transactional tool schemas and the error model in v0.1 carry
forward and remain active reference.

## Encoder spec

**[`FDC_ENCODER_CANONICAL_v1.0.md`](FDC_ENCODER_CANONICAL_v1.0.md)** —
the deterministic linguistic pipeline that maps text to a Free
Decimal Correspondence (FDC) code. No learned model, no network call at
runtime. The filing backbone for federated data exchange, and the
classifier the substrate adopted as its v1.0 scheme.

The former MOOT Decimal Classification Codes (MDCC) taxonomy and its
annex system were removed in the MDCC→FDC migration (A2). The
superseded MDCC specs are kept in [`../archive/`](../archive/) for
history only; a community-contribution/annex layer over FDC is a
future redesign, not current.

## Conventions

Every spec carries a `_vX.Y.md` version suffix. Material changes
produce a new versioned file rather than in-place edits; the prior
version is either retained (when both remain active reference, as
with the two ARIA_MCP specs) or moved to [`../archive/`](../archive/).

Each spec opens with a frontmatter block (`status`, `authors`,
`date`, `version`, `relates_to`) and then a `purpose` section.
Code comments that implement a contract reference the spec by
filename; renaming a spec means updating those code citations.

Reference documents define what is required; decision records
explain why; engineering documents describe how. When in doubt,
add the contract here and the reasoning to
[`../decisions/`](../decisions/).
