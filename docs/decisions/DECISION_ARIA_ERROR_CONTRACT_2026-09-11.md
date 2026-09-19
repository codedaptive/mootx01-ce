---
status: accepted
question: How does a failed ARIA operation report itself, and which lane sees which part?
authors: MOOTx01 maintainers
date: 2026-09-11
relates_to:
  - docs/engineering/ARIA_INTERFACE_LANE_DECISIONS.md
  - docs/reference/ARIA_MCP_INTERFACE.md
  - docs/reference/ARIA_MCP_SPEC.md
supersedes: none
context:
  - v2 flattened every failure into operation_failed with a hard-coded retryable:false (ToolDispatch.swift:828-838)
  - v1 was inconsistent by surface: a bad preset returned an isError envelope, a bad hydration level threw
  - Restoration unit U6 (1fcb3ac2d) added a distinct invalid_argument class and inline allowed lists; the class set and channel split were still open
---

# ARIA error contract: two errors, the channel chooses

## Decision

Every failure produces two things and never fails quietly.

1. A simple class from a small closed set: syntax error, record not found, write failed, and a
   few more. Deterministic: from the class alone an AI knows whether to correct its call, retry
   later, or tell the user. `retryable` derives from the class. The set is shaped so an AI cannot
   hammer a server whose disk is full.
2. The detailed technical error: message, `data.path`, allowed values, cause.

The channel decides which the client sees. The MCP adapter presents the class to the AI, plus the
correction for a syntax error (offending argument, allowed values). 1stPP and ProductDock present
the technical error, because a programmer or a deterministic client reads those lanes.

An undecodable call is a JSON-RPC protocol error. Everything the operation decides is a result
with `isError: true`.

HammerGuard enforces the anti-hammer half: a per-tool refusal counter at egress position one of
the MCP door; three refusals of one tool within thirty seconds emit a do-not-retry notice and
short-circuit the chain.

## Alternatives rejected

- One error shape for every lane. Rejected: the AI cannot use a stack of technical detail and the
  programmer cannot act on a class alone.
- Throwing syntax errors as v1 did. Rejected: some clients discard text from thrown JSON-RPC
  errors, and the AI loses the correction.

## Consequences

Finish-plan Blocks A6, B8 and C1. `data.path` per DECISION_ARIA_IDENTIFIER_CONVENTIONS. The MCP
specification's requirement that servers rate limit tool invocations is met by HammerGuard.
