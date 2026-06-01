---
title: Queue Protocol Specification
version: 1.0
status: canon
created: 2026-05-17
updated: 2026-05-17
accepted_by: bob
accepted_at: 2026-05-17
authors: Bob Pankratz (via/ claude)
audience: engineers (human and agent) implementing or extending Forge daemons
relates_to:
  - docs/concepts/FORGE_OVERVIEW.md
  - docs/doctrine/DAEMON_PARITY.md
  - docs/concepts/charters/CONTROL_PLANE_CHARTER.md
  - docs/concepts/DISPATCH_STATE_MACHINE.md
review_mode: canon
implementations: swift+rust+bit-identity (with Python behavior-conformance)
---

# Queue Protocol Specification

## What this document is

The queue protocol is the public contract between Forge GUI, the
daemons that run the factory, and any third-party tool that
wishes to write jobs into or read state out of a Forge factory.

The reference implementation of the protocol is **QueueKit**, a
Swift package that implements a mailq-pattern (POSIX maildir-style)
queue with atomic-rename state transitions. QueueKit is the
authoritative source for the protocol's on-disk layout, atomic
transition mechanics, job-file schema, signal-file schema, and
API surface. This document does not restate QueueKit's design;
it points at QueueKit and specifies only the cross-cutting
protocol concerns that belong in canon regardless of the
implementing kit.

The QueueKit design particulars live in the MemPalace today
(design rationale, mailq trade-offs, atomic-rename mechanics,
the comparison against alternatives the user walked through).
When QueueKit is implemented as a Swift package per Pass 4 work,
its formal specification will land at
`Packages/QueueKit/docs/QUEUEKIT_SPEC_v1.1.md` (or the equivalent
canonical path agreed at implementation time). This document
will cross-reference that spec when it lands.

Until then, this document specifies the protocol-level concerns
that the three daemon implementations (Swift, Rust, Python) must
agree on independently of QueueKit's library API. Those concerns
are: protocol versioning, the extension mechanism, the conformance
test profiles, the relationship to ddfactory, and the harness-
portability rationale.

## Why the protocol is public

Two reasons.

**Harness portability per Inviolable P7.** The queue protocol
must outlive Claude Code. A filesystem-native protocol is the
most durable form of public contract available; any future
harness that can read and write files can participate.

**Language-agnostic three-implementation parity.** The three-
implementation daemon doctrine (`docs/doctrine/DAEMON_PARITY.md`)
requires that Swift, Rust, and Python implementations all
conform to the same protocol. A protocol specified in terms of
any one language's types would not serve the doctrine. The
filesystem-native shape is the language-agnostic shape.

The reference implementation in Swift (QueueKit) defines what
"conforming" means in concrete terms; the Rust version mirrors it
with bit-identity; the Python port matches the behavioral
shape.

## QueueKit as reference implementation

QueueKit is the Swift package that implements the queue protocol.
Its design draws from the POSIX maildir pattern (the same shape
used by mail transfer agents for decades) and from the
operational experience of the ddfactory prototype.

The key QueueKit properties the protocol depends on:

- **Filesystem-native.** Jobs are files. State transitions are
  atomic POSIX renames. Multiple daemons can watch the same
  queue directory without coordination because rename is atomic
  at the OS level.
- **No central coordinator.** The queue itself is the state.
  No in-memory orchestrator holds authoritative state. The
  filesystem is observable; in-memory state is not. This
  property satisfies Inviolable P3 and the queue-is-exposed
  principle.
- **Mailq pattern, not a re-imagining.** The directory layout
  and the transition primitives follow the well-understood
  maildir convention. This makes the protocol legible to anyone
  familiar with POSIX queueing patterns and makes the conformance
  tests straightforward to author.

The detailed design rationale, the mailq trade-offs, the on-disk
layout, and the API surface are all QueueKit's spec. When
QueueKit's `QUEUEKIT_SPEC_v1.1.md` lands at `Packages/QueueKit/docs/`,
this document will reference it directly.

## Protocol versioning

Every job file carries a `schema_version` field. The current
version is `"1"`. QueueKit's spec defines the field's location
and its semantics; this document records the cross-cutting
versioning policy.

A daemon implementation declares which protocol versions it
supports. When a daemon encounters a job at a higher
`schema_version` than it supports, the daemon moves the job to
the terminal state with an `incompatible-version` annotation
and does not attempt to process it. When a daemon encounters a
job at a lower `schema_version`, the daemon processes the job
under the lower version's semantics.

Protocol version bumps are ADRs. A version bump requires:

1. The QueueKit spec is updated.
2. All three daemon implementations (Swift, Rust, Python) are
   updated to support the new version.
3. The conformance test suite is updated.
4. The ADR records the rationale and any migration considerations.

## Extension mechanism

The protocol supports two extension mechanisms, both following
the sidecar doctrine documented in
`docs/doctrine/CONFIGURATION_STORAGE_MODES.md`:

- **In-record `extensions` object.** Top-level field of the job
  JSON, preserved verbatim by all daemons through every state
  transition.
- **Sidecar file.** `<job_id>.sidecar.json` adjacent to the
  canonical job file in the same directory, preserved verbatim
  by all daemons through every state transition.

Third-party tools writing jobs to a Forge factory may use either
mechanism to carry tool-specific metadata. Forge daemons preserve
the data through the queue lifecycle and surface it back to the
tool when the job reaches its terminal state.

The schema for what goes in `extensions` and the sidecar is the
tool author's choice. QueueKit (and conforming daemons) do not
inspect the content.

## Conformance test profiles

The conformance test suite is the authoritative test of whether
a daemon implementation conforms to the protocol. It runs as
part of the merge gate per `docs/doctrine/DAEMON_PARITY.md`.

The suite has two profiles:

- **Bit-identity profile.** Applies to Swift and Rust daemons.
  Canonical operations must produce byte-identical output. This
  profile is the strongest form of conformance: any divergence
  in serialization, ordering, or format is a test failure.
- **Behavior profile.** Applies to the Python daemon. Canonical
  operations must produce the same observable behavior at the
  queue protocol layer: same signals written, same transitions
  performed, same terminal states reached. The Python daemon
  may serialize identically to the Swift+Rust pair or may not;
  the test does not require byte-identity, only behavioral
  equivalence.

The suite covers at minimum:

1. **Schema conformance.** Job files written by the daemon
   conform to the schema documented by QueueKit. Job files read
   by the daemon are correctly parsed.
2. **Transition correctness.** Each state transition is an
   atomic rename. No state lingers in an inconsistent
   intermediate form.
3. **Signal protocol correctness.** Signals written by the daemon
   match the format. Signals read by the daemon are correctly
   interpreted.
4. **Concurrent access.** Two daemon instances watching the
   same queue do not corrupt state. Atomicity is preserved
   under concurrent contention.
5. **Extension preservation.** In-record `extensions` objects
   and sidecar files travel through every operation without
   loss.
6. **Failure modes.** A killed daemon mid-transition leaves
   state in a recoverable form. A second daemon picks up where
   the first left off.

The full test vector set is a future deliverable. The vectors
themselves live alongside QueueKit's spec at
`Packages/QueueKit/Tests/` once QueueKit is implemented; the
Rust version reuses the vector data through cross-language test
infrastructure; the Python port reuses the behavioral
expectations from the same vectors.

## Relationship to ddfactory

ddfactory is the prototype dispatch system being used to build
Forge. ddfactory is not a production system, has no users beyond
the Forge project itself, and carries no API or data contract
that Forge inherits. When Forge GUI ships, ddfactory is
retired: it shuts down, the operator switches to Forge GUI, and
the ddfactory repository remains as historical reference only.

This protocol is not designed for backward compatibility with
ddfactory. The two systems are independent. Any signal-format
resemblance is a coincidence of shape, not a compatibility
commitment; QueueKit's signal format is what it is because
text-line key-value is the simplest atomic-write-friendly form,
not because ddfactory used the same shape. The directory layout
intentionally differs from ddfactory's. No Forge daemon reads
ddfactory's queue. No ddfactory worker reads Forge's queue.

Migration of in-flight ddfactory state to Forge state is out of
scope. When Forge GUI is ready, ddfactory stops accepting new
work; in-flight ddfactory missions complete or are abandoned at
the operator's discretion; the operator starts submitting work
to Forge GUI. ddfactory is frozen per
`docs/doctrine/DDFACTORY_FROZEN.md`.

## What this specification does not cover

- **The on-disk layout, the job-file schema, the signal-file
  schema, the state-transition table, and the API surface.**
  Those are QueueKit's spec. When `Packages/QueueKit/docs/QUEUEKIT_SPEC_v1.1.md`
  lands, it is the authoritative source for these specifics.
  Until then, the MemPalace carries the design particulars.
- **The contents of mission specification files.** Those are
  documented separately under `docs/concepts/MISSION_SPEC.md` (to
  be authored).
- **The contents of completion reports.** Those are documented
  under `docs/concepts/COMPLETION_REPORT_FORMAT.md` (to be
  authored).
- **Worker-internal behavior.** Workers are anything that can
  conform to the protocol; their internal architecture is
  outside Forge's scope per the queue-is-exposed principle.
- **The harness protocol (AgentHarness).** The harness sits
  between the dispatch daemon and the worker process. It is
  specified separately in `docs/concepts/AGENTHARNESS_PROTOCOL.md`.
- **The four-state terminal vocabulary.** That is
  `docs/concepts/SIGNAL_VOCABULARY.md`. The vocabulary extends the
  signal protocol layer that QueueKit defines.

## Maintenance

This document is updated when:

- The QueueKit spec lands at its canonical path. The
  cross-references in this document become concrete instead of
  pointing at MemPalace.
- A protocol version bumps. A new ADR records the bump; this
  document's versioning section reflects the new version.
- The conformance test profile expectations change. The
  changes are an ADR.
- The relationship between QueueKit and conforming
  implementations changes. For example, if a Rust QueueKit-
  equivalent is named separately, this document records the
  pair.

Edits to this document are normal canon edits and follow the
review discipline that applies to canon. Edits to QueueKit's
own spec are owned by QueueKit's spec; this document does not
restate them.
