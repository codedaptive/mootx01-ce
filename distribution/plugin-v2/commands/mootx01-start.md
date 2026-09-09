---
description: "Orient to MOOTx01: ping, status, journal, and map before beginning work."
---

# Mootx01 Start

Orient yourself to MOOTx01 for this task.

1. Call `moot_estate_ping`.
2. Call `moot_estate_status`.
3. Call `moot_read_journal` if the task may depend on previous work.
4. Call `moot_estate_map` if the task may depend on stored structure.
5. Call `moot_list_lenses` if analysis may be needed.
6. Report briefly what is available and what you will use.

If MOOTx01 is unavailable, say so and continue only from current context. If
`moot_estate_ping` fails or the tools are absent entirely, the `mootx01`
binary is likely not installed — offer the user the fix:
`brew install codedaptive/mootx01-ce/mootx01` (macOS/Linux) or
`winget install Codedaptive.MOOTx01` (Windows), then restart the client.
