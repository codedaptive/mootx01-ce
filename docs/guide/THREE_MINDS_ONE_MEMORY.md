---
title: Three Minds, One Memory — Work Packet Lineage Demo
version: v0.1
status: active
date: 2026-07-24
---

# Three Minds, One Memory

A five-step choreography that shows how three distinct AI agents — a frontier
cloud model, a second frontier model, and an on-device Apple Intelligence
worker — collaborate through a shared MOOTx01 estate, filing structured work
packets with full lineage so any agent can resume from where the others left off.

---

## What You Will See

After completing this demo you will have:

- Two independently-filed work packets (one from Claude, one from Codex) on the
  same topic, each with provenance capturing which model and agent filed it.
- A comparison summary packet derived from both, filed with `derivesFrom` lineage
  links pointing to both antecedents.
- The synthesis packet visible in the app's **Packets** tab (Advanced Mode),
  with a working lineage trace that walks the three-level chain.

---

## Prerequisites

| Requirement | Notes |
|---|---|
| MOOTx01 estate running | `moot_estate_ping` returns `{ "reachable": true }` |
| Claude connected via MCP | `moot_estate_status` succeeds in Claude Code / claude.ai |
| Codex connected via MCP | Run via `codex` CLI with `--mcp` flag pointing to the estate |
| MOOTx01 app open (Advanced Mode) | Packets tab visible after this demo |
| On-device Apple Intelligence | Required for Step 4 (SummarizeWorker). Falls back gracefully if unavailable. |

Verify the estate is reachable before starting:

```
moot_estate_ping
```

Expected:

```json
{ "reachable": true, "estate": "your-estate-name" }
```

---

## The Topic

Use this topic verbatim across all three agents — it keeps the packets comparable:

> **What are the key trade-offs between local-first AI memory (like MOOTx01) and
> cloud-managed memory (like OpenAI Memory)?**

---

## Step 1 — Claude Researches and Files

**In Claude (claude.ai or Claude Code with MCP enabled):**

Ask Claude to research the topic and file a structured work packet:

```
Research the following question and file a structured work packet to our
shared MOOTx01 estate:

"What are the key trade-offs between local-first AI memory (like MOOTx01)
and cloud-managed memory (like OpenAI Memory)?"

File the packet to room "work-packets" in wing "Agentic Memory" using:
  moot_file_memory

Use this JSON structure as the memory content (WorkPacket schema v1):
{
  "schemaVersion": 1,
  "id": "<generate a UUID>",
  "objective": "Compare local-first vs cloud-managed AI memory trade-offs",
  "sources": [...],
  "claims": [...],
  "uncertainties": [...],
  "nextSteps": [...],
  "provenance": {
    "model": "claude-sonnet-4-6",
    "agent": "claude-research",
    "createdAt": "<ISO8601 now>",
    "updatedAt": "<ISO8601 now>"
  },
  "lineageLinks": []
}

After filing, share the drawer ID that the estate returned.
```

**What to capture from this step:**

Record the drawer ID returned by `moot_file_memory`. You will pass it to Step 3
and Step 4 as `claudeDrawerID`.

---

## Step 2 — Codex Files Independently

**In Codex CLI (with MCP wired to the same estate):**

Run a parallel research task. Codex must NOT read Claude's packet before filing —
the independence is the point. Start Codex with:

```
codex --mcp mootx01 "Research this question independently and file a work
packet to our MOOTx01 estate:

'What are the key trade-offs between local-first AI memory (like MOOTx01)
and cloud-managed memory (like OpenAI Memory)?'

File to room 'work-packets', wing 'Agentic Memory', using moot_file_memory.
Use WorkPacket schema v1 JSON (schemaVersion: 1) with provenance.model
set to your model name and provenance.agent set to 'codex-research'.
Set lineageLinks to [].

Return the drawer ID."
```

**What to capture from this step:**

Record the drawer ID returned. This is `codexDrawerID`.

---

## Step 3 — Local Model Compares via SummarizeWorker

**In the MOOTx01 app on your Apple device (Advanced Mode):**

This step uses the on-device `SummarizeWorker` (shipped in FAB5-H1) to
summarize both packets together. The comparison gives the synthesis agent
a concise picture of where Claude and Codex agreed or diverged.

In the **Intelligence** tab, ask:

```
Recall the two work packets filed by 'claude-research' and 'codex-research'
from room 'work-packets'. Summarize the key agreements and divergences
between them. Focus on: privacy model, latency, portability, and vendor lock-in.
```

The on-device assistant reads both packets from the estate via `moot_memory_search` and
uses SummarizeWorker to produce the comparison.

> **Note (FAB5-H2):** A dedicated `CompareWorker` that takes two packet IDs and
> produces a structured diff is planned for FAB5-H2. Once FAB5-H2 ships, replace
> this step with:
> ```swift
> CompareWorker().runSafe(
>     input: .init(packetIDs: [claudeDrawerID, codexDrawerID]),
>     caller: bridge
> )
> ```

**What to capture from this step:**

Copy the on-device summary text. You will include it in the synthesis packet's
`claims` or `sources` in Step 4.

---

## Step 4 — File the Synthesis Packet with Lineage

**In Claude or Codex (whichever you prefer for synthesis):**

Now file the synthesis — a third work packet that derives from both Step 1 and
Step 2. Pass `claudeDrawerID` and `codexDrawerID` (captured above):

```
Using the comparison summary below, file a synthesis work packet to our
MOOTx01 estate. This packet MUST include lineageLinks pointing to both
prior packets.

Comparison summary (from Step 3):
<paste the on-device summary here>

File to room 'work-packets', wing 'Agentic Memory', using moot_file_memory.

Use WorkPacket schema v1 JSON with these lineageLinks:
[
  { "kind": "derivesFrom", "targetPacketID": "<claudeDrawerID>" },
  { "kind": "derivesFrom", "targetPacketID": "<codexDrawerID>" }
]

Set provenance.agent to 'synthesis' and provenance.model to your model name.
Return the drawer ID.
```

**What to capture from this step:**

Record the synthesis drawer ID as `synthesisDrawerID`.

---

## Step 5 — Either Frontier Model Resumes from Synthesis

**In Claude or Codex:**

This step demonstrates the core capability: a fresh agent picks up the synthesis
packet by ID and continues the thread as if it had done all the prior work.

```
Recall the work packet with drawer ID: <synthesisDrawerID>

Using its objective, claims, uncertainties, and next steps as your starting
point, draft a one-page technical brief on local-first vs cloud-managed AI
memory trade-offs. Reference the lineage (two antecedent packets) to show
where the synthesis came from.
```

The agent uses `moot_memory_search` to retrieve the synthesis packet by room and wing,
reads its fields, and resumes — without you having to re-explain the prior work.

---

## Verifying the Lineage in the App

1. Open the MOOTx01 app on your device.
2. Enable **Advanced Mode** (Settings → Advanced Mode).
3. Tap the **Packets** tab (shippingbox icon).
4. Tap the synthesis packet row.
5. Tap **View Lineage** — the lineage trace walks back through both antecedents
   (Claude's packet and Codex's packet) in breadth-first order.

You should see:
- **Root Packet:** the synthesis (Hop 0)
- **Hop 1:** Claude's packet (`claudeDrawerID`)
- **Hop 1:** Codex's packet (`codexDrawerID`)

> **Production wiring note:** The Packets tab shows an empty state by default
> because PacketListView's default loader returns `[]`. To show live estate
> packets, pass a `WorkPacketStore.list` closure at app launch:
>
> ```swift
> let store = WorkPacketStore(client: EstateAdapter(estate))
> PacketListView { try await store.list() }
> ```
>
> This wiring is deferred to a follow-on mission. The demo works with the app
> acting as the lineage viewer while the agents file packets via MCP.

---

## ARIA Tool Reference

| Tool | What it does in this demo |
|---|---|
| `moot_estate_ping` | Verify estate is reachable (Step 0) |
| `moot_estate_status` | Show wing/room counts before and after |
| `moot_file_memory` | File a WorkPacket-schema JSON string as a drawer |
| `moot_memory_search` | Retrieve packets by room, agent, or content query |
| `moot_estate_map` | Inspect which wings/rooms contain packets |

All tools ship in the MOOTx01 ARIA MCP surface. Call `moot_estate_status` at
any point to confirm packets landed in the `work-packets` room.

---

## Troubleshooting

**Packets tab is empty after the demo**

The default `PacketListView` uses a no-op loader. The Packets tab shows live
estate content only when wired to a `WorkPacketStore`. Until that wiring lands
(follow-on mission), use `moot_memory_search` from an AI client to query packets, or
inspect the estate via `moot_estate_map`.

**Lineage View shows "No antecedents found"**

`LineageView` loads antecedents via `LineageGraph.antecedents(of: drawerID)`.
This requires the drawerIDs in `lineageLinks` to be estate-assigned IDs (the
value returned by `moot_file_memory`), not the WorkPacket's own `id` field.
Confirm you passed the estate-returned drawer ID as `targetPacketID` in Step 4.

**On-device summary step fails**

Apple Intelligence may not be available on the device or simulator. The
`SummarizeWorker` calls `fallback()` automatically and returns a canned
placeholder. The demo still works — use the placeholder as the comparison text
in Step 4.

---

## Execution Log Template

Copy this into your notes and fill in as you run the steps:

```
Date: _____________
Estate: ____________

Step 1 — Claude drawer ID:    _________________________________
Step 2 — Codex drawer ID:     _________________________________
Step 3 — On-device summary:
  [paste here]

Step 4 — Synthesis drawer ID: _________________________________
Step 5 — Brief drafted: [ ] yes  [ ] no

Lineage verified in app: [ ] yes  [ ] no
```
