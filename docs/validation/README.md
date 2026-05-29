# Validation

The evidence layer. Claims made elsewhere in `docs/` are not
authoritative until they are recorded here as testable
propositions and matched against measured evidence.

This directory exists so that "the substrate is correct" is not a
slogan but a position the project can defend on demand.

## Top-level documents

**[`CLAIMS_LEDGER.md`](CLAIMS_LEDGER.md)** — the ledger of every
load-bearing claim made about MOOTx01. Each row names the claim,
its source document, the evidence type required (theorem,
benchmark, audit, conformance test), and its current status
(asserted / measured / passed / failed). Reading this answers:
"what do we say is true, and which of those have we proven?"

**[`DESIGN_CONSTRAINTS.md`](DESIGN_CONSTRAINTS.md)** — the
constraints the substrate must satisfy by design (the C-series:
C-1 model independence, C-2 audit completeness, etc.). Constraints
are propositions that cannot be empirically tested; they are
guaranteed by the architecture or they are not.

**[`VALIDATION_PLAN.md`](VALIDATION_PLAN.md)** — how the project
moves a claim from "asserted" to "proven." The procedural
counterpart to the claims ledger: who runs what, when, and what
counts as evidence.

## Subdirectories

**[`audits/`](audits/)** — recorded audit reports. Each audit is
a moment-in-time investigation that produces a finding. The
naming pattern is `AUDIT_<topic>_<date>.md`. Audits cite the
ledger row they update and the commit they were run against.

**[`substrate_math_performance/`](substrate_math_performance/)** —
the substrate mathematics performance corpus. Reference
implementations, accelerator architecture notes, benchmark
narratives, and the index of measured primitives. Has its own
README. This is where the "measured" status in the claims ledger
finds its evidence.

## How this directory relates to the others

- [`../reference/`](../reference/) defines what the substrate must
  do. Validation tests whether it does.
- [`../decisions/`](../decisions/) explains why each choice was
  made. Validation tests whether the choice held up.
- [`../engineering/`](../engineering/) cookbooks tell the
  implementer how to build the substrate. Validation closes the
  loop by checking what was built.

A claim that lives only in `reference/` or `decisions/` and never
makes it into the claims ledger is, by convention, not yet a
validated claim. The point of the ledger is to make that gap
visible.

## Conventions

The three top-level documents do not carry version stamps; they
are evergreen and updated in place as claims are added or
resolved. The audit reports and the performance corpus documents
carry date stamps because they record specific investigations or
measurements.

A failed claim does not disappear from the ledger — it is marked
failed and stays there as a record. The system the project is
building is one where falsified claims remain visible.
