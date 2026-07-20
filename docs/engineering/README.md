# Engineering Documentation

This directory is the stable engineering authority for MOOTx01. It states the
rules an implementation must obey now. Design deliberation, rejected
alternatives, approval dates, and migration history are historical evidence;
they are not dependencies of source code or of the current documentation.

## Authority order

When two sources disagree, use this order:

1. shipped source and conformance tests;
2. current reference specifications and interfaces in `docs/reference/`;
3. the engineering masters in this directory;
4. archived design records, only to explain how an older design arose.

A proposal is not made normative merely because it was written down. A rule
from a proposal enters this directory only when current source, tests, or an
accepted specification confirms it. The system's present non-contracts are
recorded explicitly so an old proposal cannot be mistaken for shipped behavior.

## Master documents

| Concern | Stable authority |
|---|---|
| Cross-cutting architecture, data, persistence, recall, federation, Vault, runtime, and security | `SYSTEM_ENGINEERING_REFERENCE.md` |
| Substrate data model, algorithms, state machine, matrix tier, audit fold, and mathematical invariants | `GENIUSLOCUS_ENGINEERING_COOKBOOK.md` |
| FDC encoder pipeline, artifacts, ownership, and conformance | `FDC_ENCODER_COOKBOOK.md` |
| Cross-language primitive catalog and conformance workflow | `HARNESS_REFERENCE.md` |
| Performance measurements and backend-selection gates | `SUBSTRATE_PERFORMANCE_GATE.md` |
| Package authoring, Swift/Rust parity, dependency, test, and comment rules | `STANDARD_CODE_AUTHORING_PRACTICE.md` |
| CE/EE publication and release flow | `RELEASE_RUNBOOK.md` |

Reference specifications remain the detailed API contracts. These engineering
masters connect those contracts and preserve the cross-cutting invariants that
do not belong to one interface file.

## Documentation and comment rule

Source comments explain the behavior, invariant, precondition, or ownership
boundary that is true at the commented code. They do not cite design-record
filenames or rely on a historical document to complete their meaning. A comment
that exists only to point at a design record is deleted; a useful explanation is
kept and written in present tense.

Stable documentation links to the owning engineering section or current
reference specification. Historical records may refer to other historical
records inside the private archive, but live code and documentation do not.

## Design-record lifecycle

During active design, a branch may carry a decision record while a question is
being settled. Before that branch becomes a stable release:

1. integrate every adopted rule and constraint into its stable engineering or
   reference owner;
2. record proposed-but-unshipped ideas as non-contracts when their absence is
   important;
3. archive the original deliberation privately;
4. remove live links and code citations to the record.

This keeps the implementation answerable to current contracts rather than to a
growing chain of historical filenames.
