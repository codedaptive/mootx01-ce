---
status: accepted
question: What form do error paths and identifiers take on the ARIA surface, and what is the rule when a platform default disagrees with a standard?
authors: MOOTx01 maintainers
date: 2026-09-11
relates_to:
  - docs/engineering/ARIA_INTERFACE_LANE_DECISIONS.md
  - docs/reference/ARIA_MCP_INTERFACE.md
supersedes: none
context:
  - error data.path: 107 Rust sites $.-prefixed, 68 Swift sites bare, interface doc silent
  - estate UUID uppercase in compact text (Foundation uuidString default), lowercase in structuredContent (canonicalUUID)
  - JSON-RPC leaves the error data field to the server; MCP adds nothing; JSONPath and JSON Pointer are the two conventions in use elsewhere
---

# Identifier and path conventions

## Decision

- Error `data.path` is JSONPath, `$.`-prefixed. Swift follows Rust. Documented in the interface.
- UUIDs are lowercase everywhere, per RFC 4122, which says emit lowercase and accept either.
- The general rule: we follow standards unless there is a reason not to, such as platform
  compliance or performance overhead. For a performance gain we will go against a standard or a
  platform standard if necessary. A platform's default output format is not such a reason.

## Consequences

Finish-plan Blocks A and B8. Compact-text fixtures that pinned the uppercase form move.
