---
title: ARIA Interface Lane Decisions
version: 1.0.0
status: accepted, implementation pending
author: "MOOTx01 maintainers"
date: 2026-09-11
description: Architecture decision record for the ARIA interface lanes after the v2 adoption. Ten rulings by the owner on 2026-09-11 covering the error contract, egress presentation, advisory lines, compact text, multi-estate lenses, sensitivity on create, identifier and path conventions, and the status of converted tests. Each decision names the code it governs and whether that code has shipped.
relates_to:
  - docs/reference/ARIA_MCP_INTERFACE.md
  - docs/reference/ARIA_MCP_SPEC.md
  - docs/concepts/ARIA.md
  - docs/engineering/STANDARD_CODE_AUTHORING_PRACTICE.md
  - docs/engineering/SYSTEM_ENGINEERING_REFERENCE.md
  - VERSIONING.md
---

# ARIA Interface Lane Decisions

This document records decisions, not shipped behaviour. Per `README.md` in this
directory, a rule becomes normative when source and conformance tests confirm
it. Each decision below carries a **Status** line saying whether the code that
implements it has landed. Until a decision's status reads *shipped*, the
reference interface documents describe the surface as it is, and this document
describes where it is going and why.

The decisions were made by the owner on 2026-09-11 while closing the ARIA v2
adoption. The reasoning behind each one is kept here because the reasoning is
what a future engineer needs when the code no longer explains itself.

## Frame: three lanes, shared typed operations

Topology 1.2.0 defines three interface lanes, all hosted by the one resident
daemon on macOS and by the application process on iOS and iPadOS:

| Lane | Protocol | Reader | Contract owner |
|---|---|---|---|
| ARIA-MCP | MCP over stdio or HTTP | an agentic AI | this repository's MCP adapter |
| ARIA-JSON / 1stPartyProvider | authenticated HTTP + JSON, not MCP | deterministic applications | its own catalog, version and admission |
| ProductDock | authenticated Unix domain socket, bidirectional JSON-RPC | licensed attached products | its own registration and allowlist |

Beneath the adapters sit the **typed ARIA operations**: the application
actions with explicit Swift and Rust inputs and results. An adapter decodes its
own wire format, establishes authority, calls an operation, and presents the
result in its own language. JSON stops at the adapter boundary. Operations use
GeniusLocusKit for every mutation. No operation depends on another lane's
protocol, catalog or admission. In the code the operations are the v2 lower
layer: the `AriaV2*Request` and `AriaV2*Result` types, `AriaV2LensLower`,
`AriaV2MemoryOperations`, `AriaV2MemoryMutations`, `AriaV2KnowledgeJournal`
and their Rust twins.

Every decision below follows from one principle the owner stated: **the MCP
lane sends back nothing an agentic AI cannot use. Anyone who needs a
deterministic or diagnostic payload goes the other way.**

---

## D1. Error contract: two errors, the channel chooses

**Context.** v2 flattened every failure into one `operation_failed` refusal
with a hard-coded `retryable: false`. An AI reading that cannot tell a typo in
its own call from a full disk, so it either gives up or retries against a
server that cannot recover.

**Decision.** A failed command never fails quietly. Every failure produces two
things:

1. A **simple class** from a small closed set (syntax error, record not found,
   write failed, and a few more). The set is deterministic: from the class
   alone an AI knows whether to correct its call, retry later, or tell the
   user. `retryable` is derived from the class, never set by hand. The set is
   shaped so an AI cannot hammer a server whose disk is exhausted.
2. The **detailed technical error**: message, `data.path`, allowed values,
   underlying cause.

Both are produced on every failure. The **channel decides which the client
sees**. The MCP adapter presents the simple class to the AI. For a syntax
error it also presents the correction, the offending argument and the allowed
values where a closed set exists, because that is information the AI acts on.
The 1stPP and ProductDock adapters present the technical error, because a
programmer or a deterministic client is on the other end.

An undecodable call is a JSON-RPC protocol error. Everything the operation
decides is a result with `isError: true`. This settles the v1 inconsistency in
which a bad preset returned an envelope and a bad hydration level threw.

**Consequences.** Blocks A6 and B8 of the finish plan reshape the operation
error types; HammerGuard (D2) enforces the anti-hammer half.
`data.path` follows D7. The MCP spec requires servers to rate limit tool
invocations, which this satisfies.

**Status.** Pending. Partial groundwork shipped in `1fcb3ac2d` (a distinct
`invalid_argument` class and inline allowed lists).

## D2. HammerGuard is the exit gate

**Decision.** A refusal counter per tool name sits at egress position one of
the MCP door's egress chain. Three refusals of the same tool within thirty
seconds emit a do-not-retry notice and short-circuit the rest of the chain.
Counters are dynamic, keyed by tool name; there is no maintained table.

**Status.** Pending.

## D3. Egress presentation: always rich internally, squash at exit

**Context.** The compact text of `moot_reclassify_fdc` opened with the estate
identity and three data-version hashes. Those alone exceeded the 512-scalar
cap on compact text, so the dry-run notice, the rerun hint and the list of
changes were cut off in both ports on every call. The AI never saw the half it
needed, and the half it saw it could not use. Reordering per operation would
fix one report; the owner ruled on the class.

**Decision.**

- Operations always produce the **full rich typed result**. Nothing is trimmed
  inside an operation.
- One **boundary transformer** at the MCP egress squashes the result. It works
  from a **field list per result shape** with a **visibility bitmap per field**:
  bit for the AI Assistant audience, bit for the API audience. A field with no
  bit set is internal only and never leaves the process on any lane.
- The compact text is derived at the boundary from the assistant-visible
  fields. It is not hand-written per operation.
- The MCP connection has a **presentation mode**, held for the life of the
  connection. Default is **AI Assistant**. **Diagnostic** mode makes that
  connection noisy: versions, hashes, counters, change lists, technical error
  detail. In 1.1 the mode is one settings-module value fixed to AI Assistant,
  and existing loud code moves behind the gate rather than being deleted so it
  is not rewritten later. In 1.2 an HTTP connect URL parameter and a stdio flag
  select Diagnostic per connection; the same switch serves as a compile-time
  debug aid.
- **Benchmarks run in AI Assistant mode, always**, and every benchmark record
  states the mode.

**Consequences.** The visibility table is data, identical in Swift and Rust,
frozen as a conformance fixture beside the schema vectors, and documented in
`ARIA_MCP_INTERFACE.md` as the answer to "what does the AI see for operation
X". House bitmap rules apply: `Int64`, bits never reused, tested bitwise. This
departs from one SHOULD in the MCP specification (2025-06-18, Tools), which
suggests echoing the serialized structured JSON in a text block for backwards
compatibility; we do not, because the text half is what the AI reads and the
echo would double its tokens.

**Status.** Pending.

## D4. The visibility table is the master conformance table

**Decision.** A test in each port proves, for every operation, that the set of
properties in its declared output data schema equals the set of rows in the
visibility table for that shape, in both directions. A schema property with no
row fails. A row with no property fails. At runtime the egress helper fails
closed on an emitted key it has no row for: the key is dropped, and under test
it raises. The table skeleton may be generated from the schemas, but the mask
on each row is explicit and never defaulted, because a defaulted row would
silently expose a field to the AI or to the API. The check runs pre-commit on
AriaMcpKit.

**Status.** Pending, with D3.

## D5. Advisory lines follow the token saver level

**Context.** The search discrimination warning was gated behind `explain` in
v2 on the grounds that callers who did not ask should not pay tokens. The
premise was wrong: the line is emitted only for low and medium confidence, so
it is a warning that appears exactly when the ranking is too weak to trust,
not a per-call cost. The restoration removed the gate, and neither shape was
right on its own.

**Decision.** Every advisory line whose type is known follows the token saver
level: **High** = off; **Medium** = weak rankings only; **Low** = always, all
types. The seam is one read, `X = tokensaver.mode()`, then one switch with the
default **Medium**, at the MCP adapter's egress. Token saver becomes a
settings-module key; it did not previously exist as a product setting.

**Status.** Pending, same egress stage as D3. The Medium behaviour shipped
ungated in `0a0831ddd` and is what the switch will select by default.

## D6. Compact text names the estate only when it could be ambiguous

**Decision.** If one estate is open, the compact text is just the message. If
more than one estate is open, the message is prefixed `estate: ...XXXXX`, the
trailing characters of the estate id, at least five and as many as needed to be
unique among the open estates. The set of open estates is the daemon's pool
(D9). Lowercase per D8.

**Status.** Pending, same egress stage as D3.

## D7. Error `data.path` is JSONPath

**Context.** 107 Rust sites wrote `$.field`; 68 Swift sites wrote `field`; the
interface document specified neither. JSON-RPC leaves the error data field to
the server and MCP adds nothing.

**Decision.** JSONPath, `$.`-prefixed. Swift follows Rust. Documented in
`ARIA_MCP_INTERFACE.md`.

**Status.** Pending, Block B8.

## D8. Identifiers are lowercase; standards unless there is a reason

**Context.** The estate UUID appeared uppercase in the compact text and
lowercase in `structuredContent`, in both ports. Foundation's `uuidString`
prints uppercase; RFC 4122 says emit lowercase and accept either.

**Decision.** Lowercase everywhere. The general rule the owner stated: **we
follow standards unless there is a reason not to**, such as platform compliance
or performance overhead; for a performance gain we will go against a standard
or a platform standard if necessary. A platform's default output format is not
such a reason.

**Status.** Pending, Block A. The `canonicalUUID` helper already exists.

## D9. Cross-estate lenses read any estate the daemon has loaded

**Context.** The overlap and divergence lenses compare two estates. v1 handed
them an unrestricted registered-estate resolver. v2's context promised
separately authorized handles but never populated them, so both lenses always
refused.

**Decision.** If the daemon has authenticated and loaded an estate, a lens may
read it. Which estate a row lives in is data organisation, not authorization.
The comparison-handle map is populated from the daemon's pool of open estates
through **one predicate**, "is this open estate a member of the lens pool",
which returns true for every loaded estate today. That predicate is the seam:
in 1.2 each estate gains an option to join or exclude itself from the pool,
and the option plugs into the predicate. Everything federated is deferred to
1.2 and 1.3. The seam is code with a comment naming the 1.2 option, not a
comment alone.

**Status.** Pending, Block C5. Test: the disabled
`estateDivergenceDispatchRoutesSecondEstate` plus a real two-estate case.

## D10. Sensitivity on create is normal

**Context.** A Codex finding proposed that a memory filed without a
sensitivity while a restricted grant is live should default to the grant's
tier.

**Decision.** The existing protocol stands. (a) A row is **normal on create
unless specifically set higher**. (b) A row later tunneled to higher-sensitivity
items follows the tunnel rules already in place. (c) An estate may carry a
default sensitivity tier; that does not exist in the code today and is
deferred to 1.2. The finding closes as by design.

**Status.** Shipped as-is; no change.

## D11. Converted tests are drift guards, not push gates

**Context.** About 300 v1 regression tests were deleted with the v1 surface and
are being converted to v2 in batches. Every plan since assumed the push waited
on all of them.

**Decision.** They are tests of code that is already done, so they are
validators against drift. More of them landing is better; none of them blocks
the push. The design audit of the v2 surface, the review of the 26 operations
that only fixture or catalog tests ever exercised, stays last, and it takes D1
and D3 as criteria: does each operation have the typed shape, and does its
compact text carry only what the AI can act on.

**Status.** In force.

---

## Changelog

- 1.0.0 (2026-09-11): initial record of the eleven decisions made while
  closing the ARIA v2 adoption. Source rulings filed in the estate under
  `mootx01/aria-v2/rulings-2026-09-11`.
