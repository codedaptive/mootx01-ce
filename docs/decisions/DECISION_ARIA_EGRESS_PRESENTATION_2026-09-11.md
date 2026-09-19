---
status: accepted
question: What does the MCP lane send back to an AI, who decides, and how is it kept consistent across 85 operations and two ports?
authors: MOOTx01 maintainers
date: 2026-09-11
relates_to:
  - docs/engineering/ARIA_INTERFACE_LANE_DECISIONS.md
  - docs/reference/ARIA_MCP_INTERFACE.md
  - packages/kits/AriaMcpKit/Sources/AriaMCP/AriaV2Envelope.swift
supersedes: none
context:
  - moot_reclassify_fdc compact text led with estate identity and three data-version hashes, exceeding the 512-scalar cap so the dry-run notice, rerun hint and change list never shipped, both ports
  - The v2 discrimination warning was gated behind explain on a false premise (it emits only for weak rankings); the restoration ungated it (0a0831ddd)
  - Estate UUID printed uppercase in content[0].text and lowercase in structuredContent
  - MCP 2025-06-18 offers audience annotations of user or assistant only; there is no programmer audience in the protocol
---

# ARIA egress presentation: always rich internally, squash at exit

## Principle

The MCP lane sends back nothing an agentic AI cannot use. Anyone who needs a deterministic or
diagnostic payload goes the other way.

## Decision

- Operations always produce the full rich typed result. Nothing is trimmed inside an operation.
- One boundary transformer at the MCP egress squashes the result from a field list per result
  shape with a visibility bitmap per field: a bit for the AI Assistant audience, a bit for the API
  audience. No bits set means internal only; the field never leaves the process on any lane.
- The compact text is derived at the boundary from the assistant-visible fields, not hand-written
  per operation.
- The visibility table is the master conformance table. A test in each port proves that every
  operation's output data schema properties equal its table rows, both directions. The egress
  fails closed on an unlisted key. Masks are explicit, never defaulted, even when the table
  skeleton is generated from the schemas. The check runs pre-commit on AriaMcpKit.
- The MCP connection has a presentation mode for the life of the connection. Default AI
  Assistant. Diagnostic makes that connection noisy. In 1.1 the mode is one settings-module
  value fixed to AI Assistant and existing loud code moves behind the gate rather than being
  deleted. In 1.2 an HTTP connect URL parameter and a stdio flag select Diagnostic; the same
  switch is a compile-time debug aid.
- Advisory lines whose type is known follow the token saver level: High off, Medium weak
  rankings only, Low always. Seam: `X = tokensaver.mode()`, one switch, default Medium, at the
  egress. Token saver becomes a settings-module key.
- Compact text names the estate only when more than one estate is open: `estate: ...XXXXX`,
  trailing characters, at least five, unique among open estates, lowercase.
- Benchmarks run in AI Assistant mode, always, and every record states the mode.

## Alternatives rejected

- Reorder the FDC report so the useful lines fit. Rejected: fixes one operation, leaves the class.
- Trim inside each operation. Rejected: 85 hand-written rules that drift; the table is one rule.
- An audience class on each field declaration. Rejected in favour of the per-shape table, which
  is data, identical in both ports, and freezable as a conformance fixture.
- Echo the serialized structured JSON in the text block, as the MCP spec suggests SHOULD for
  backwards compatibility. Rejected: the text half is what the AI reads; the echo doubles tokens.

## Consequences

One egress presentation stage in the MCP door's egress chain, both ports. The table is documented in ARIA_MCP_INTERFACE.md as "what the AI sees
for operation X". House bitmap rules apply.
