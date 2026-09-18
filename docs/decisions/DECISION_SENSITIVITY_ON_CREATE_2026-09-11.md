---
status: accepted
question: When a memory is filed without a sensitivity while a restricted or secret grant is live, what tier does it get?
authors: MOOTx01 maintainers
date: 2026-09-11
relates_to:
  - docs/engineering/ARIA_INTERFACE_LANE_DECISIONS.md
  - docs/reference/ARIA_MCP_INTERFACE.md
  - docs/reference/LOCUSKIT_SPEC.md
  - docs/decisions/DECISION_STALE_TUNNEL_SENSITIVITY_2026-08-03.md
supersedes: none
context:
  - Codex finding a46c8160 (Medium) proposed defaulting the new drawer to the live grant tier
  - Checked 2026-09-11: no estate default sensitivity tier exists in GLK, LocusKit or AriaMCP sources
---

# Sensitivity on create is normal

## Decision

The existing protocol stands.

(a) A row is normal on create unless specifically set higher.
(b) A row later tunneled to higher-sensitivity items follows the tunnel rules already in place.
(c) An estate may carry a default sensitivity tier. That does not exist today and is deferred
to 1.2.

The Codex finding closes as by design. No grant-tier default.

## Consequences

None in code. Close the finding in Codex with this record.
