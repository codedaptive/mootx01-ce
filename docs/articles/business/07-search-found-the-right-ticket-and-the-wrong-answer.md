# Search Found the Right Ticket—and the Wrong Answer

The most dangerous line in a service ticket was rarely nonsense. It was usually a reasonable repair that someone tried before discovering the real problem. The words belonged in the record because they explained what happened. They did not belong in the next technician's hands as the answer.

For nineteen years I ran a managed services company, and ticket history often kept us from solving the same problem twice. A useful ticket held the symptoms, the questions, the failed attempts, the correction, and the customer's confirmation that the service worked again. Its value came from the sequence rather than one matching sentence.

Search could find the right ticket and still highlight the wrong paragraph. The failed repair often repeated the error message more closely than the eventual solution did.

A technician reading the complete record could see what happened next. The author and date placed each note in the incident. A phrase such as "that did not work" changed the meaning of the instruction above it. The final confirmation showed which repair survived contact with the customer. Search found the history; the technician decided which part deserved to guide the work.

AI agents are beginning to collapse those two steps. An agent can search memory, receive an ordered result, and use the first passage to prepare a release or change a system. The evidence around the passage may never reach a person before the next action begins.

That shortcut changes the product's responsibility. Keyword search finds shared language, while semantic search finds similar meaning expressed with different words. Hybrid search combines several signals and ranks the candidates. Each method helps answer where the system should look, but none can establish what the organization currently believes.

Resemblance belongs to the ranking. Authority belongs to the record's history and the conditions of the present job.

A pricing exception may match a sales question while belonging to another account. A support workaround can remain highly relevant after a permanent repair has shipped. An early budget estimate may contain the same project language as the approved number and still be the wrong basis for a commitment.

The first generation of agent memory naturally concentrated on persistence. Give the model a place to store useful lessons, index what accumulates, and bring related text into later sessions. That removes the cold start. Once recalled text begins directing action, however, the system has to distinguish a candidate from a current answer. Persistence has moved the bottleneck from finding the past to judging it.

We met that boundary while working on our memory system. Its recall tools can cast a broad net, favor exact identifiers, or explore conceptual relationships. A discrimination signal also classifies the relative gap between the leading result and its neighbors, and applies a saturation discount when the semantic lane did not contribute. The source describes that signal as a confidence estimate of relative separation, not a statement about truth — a clear winner in the ranking can still be an abandoned experiment or a rule written for another condition.

The next stage needs questions that a search score cannot answer:

- Who or what created the memory?
- Did a person confirm it?
- Has anyone contested it?
- Did a later record supersede it?
- Is it current for this task?
- May this reader see it?

Those questions do not always produce the same view. An investigation may need tentative observations and rejected ideas because they explain how earlier work unfolded.

An operational action may require only the records the system currently treats as settled. Hiding that choice inside one relevance score makes the result look more certain than the evidence allows.

The practical strategy in MOOTx01 is to separate the jobs. Let retrieval gather candidates, then return enough state and provenance for the agent to judge how each candidate may be used. Keep the operational view distinct from the historical or exploratory view. When the evidence is weak and the consequence is large, bring a person back into the decision.

AI can carry much of the mechanical load by comparing a large record set, combining retrieval methods, and searching again when the first ranking is flat. Related records can show how an answer changed over time. The machine brings analysis, context, and iteration to a history no person could scan on every request.

The meaning of current remains human work. Experience recognizes a temporary exception even when the note sounds general. Perspective asks who will carry the cost of a wrong answer, and imagination considers the customer or condition the old record never anticipated. Those judgments become more useful when the system preserves the evidence needed to exercise them.

Search gives an agent reach into the past, while memory gives that past enough structure to be used with judgment. The first result tells the machine where to look. It should not decide by itself what the organization believes.

## Sources
1. MOOTx01 maintainers, `packages/kits/AriaMcpKit/Sources/AriaMCP/RecallDiscrimination.swift`.
2. MOOTx01 maintainers, `apps/moot-agent-skills/shared/MOOTX01_TOOL_SELECTION.md` and `MOOTX01_AGENT_RULES.md`.
3. MOOTx01 maintainers, `docs/concepts/ARIA.md`.
4. MOOTx01 Git history: `903bfb91`, `f41307a4`, `1143ac7f`, and `2c7e7098`.

---

[← Previous: Same Memory Commands. Safer Memory Records.](06-same-memory-commands-safer-memory-records.md) | [Series index](../README.md) | [Technical edition](../technical/07-search-found-the-right-ticket-and-the-wrong-answer.md)

Originally published on [LinkedIn](https://www.linkedin.com/in/bobpankratz/recent-activity/articles/) on 2026-07-23. Revised for this repository on 2026-07-23.

Copyright 2026 Codedaptive LLC. Article text licensed under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
