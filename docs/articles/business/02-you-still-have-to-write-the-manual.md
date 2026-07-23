# You Still Have to Write the Manual

A new employee opens a tool for the first time and asks an AI assistant how to finish a task. The assistant finds a command in the documentation, runs it, and reports success. Nothing looks unusual until the employee discovers that the command took the slowest path, changed more data than expected, and left no clear way back.

The damage did not begin with a weak model; the product supplied a command without enough guidance to judge when that command was appropriate. As agents begin operating software for people, missing documentation becomes operating risk rather than a support inconvenience.

The useful question has therefore changed. A manual must still help a person recover. It must also teach an agent how to choose, verify, and stop. What should a product explain so both readers can reach a dependable result without borrowing the creator's memory?

For years, documentation carried a private joke: the team still had to write the manual, and users still would not read it. Some people did read it, usually after an error had already consumed their patience. The joke survived because manuals were expensive to maintain and easy to postpone.

Agents upset that bargain because they read differently; a person often looks for one answer and leaves, while an agent can compare several paths, inspect examples, and keep searching until a plan forms. Speed helps only when the product has exposed the facts that make one plan better than another, so the manual now influences action as directly as a menu or button.

That change gives a product three readers. The creator needs a record that survives turnover and forgotten decisions. A human user needs the shortest safe path. An AI agent needs stable names and boundaries. Examples and evidence show that the work is complete.

A tool list does not meet those needs by itself. Commands reveal what the system can do, but they do not explain cost, danger, recovery, or the moment when a person must decide. An agent facing two plausible commands will otherwise improvise from names and nearby text.

I saw the difference while organizing a large collection of conference transcripts. My first request described a file-by-file routine. Extract one transcript, clean it, store it, and repeat. The route was valid, yet repetition would have spent most of the effort moving text through a narrow door.

The agent inspected the available source and documentation before committing to that routine; a bulk import path was already present, and the transcripts could be organized into the format that path expected. Once the agent connected those facts, the work changed from hundreds of isolated writes into one prepared collection followed by verification.

The faster route mattered less than the reason it was available. Nobody had placed a secret shortcut in the prompt. The product had a named bulk operation, the manual explained its purpose, and the result offered a way to check that the collection arrived.

That incident suggests a practical documentation test. A useful manual should let a reader answer five independent questions:

- What is the ordinary path?
- When is another path cheaper or safer?
- Which actions change state?
- What evidence proves completion?
- Which decision still belongs to a person?

Together, the questions turn documentation into a review of the product itself. If the normal path requires an apology, the workflow may need redesign. When recovery depends on a fact remembered only by the creator, the product is still carrying an invisible employee.

MOOTx01 supplied the technical incident behind this lesson, but the method is broader than memory software. Its agent guide distinguishes single-memory filing from vault import. It tells an agent to poll long-running work and requires verification after a large ingest. The guide does more than name commands; it connects each command to a circumstance and a finish line.

The same guide also separates runtime installation from agent behavior; giving an assistant access to tools does not teach it to recall before guessing or to write back a decision that should persist. Those habits live in the operating instructions because a capable agent still needs the product's intent.

There is a fair complication. Documentation cannot anticipate every useful route, and a manual that describes every internal mechanism becomes another obstacle. The answer is to document decisions rather than narrate the entire codebase: name the common path, the costly alternative, the boundary, the verification step, and the recovery route.

AI can help keep that material current by comparing commands with prose, testing examples, and finding stale names. Product judgment remains human work because someone must decide which result is safe enough, which shortcut deserves support, and where the software should refuse to continue.

Better agents do not reduce the value of a manual. One clear instruction can guide a person today and an agent tomorrow. The same explanation can serve a team member months later. Documentation becomes the place where private operating knowledge turns into a reusable product capability.

You still have to write the manual. Write the parts that help each reader choose well, recognize completion, and recover without calling the person who built the first version. The product becomes easier to trust when its best judgment no longer lives in only one head.

## Sources
1. MOOTx01 maintainers, "How To Use MOOTx01," `apps/moot-agent-skills/shared/HOW_TO_USE_MOOTX01.md`, especially "Vaults And Source Material" and "Cost Discipline."

2. MOOTx01 maintainers, "MOOTx01 Agent Adapters," `apps/moot-agent-skills/README.md`, especially "What The Adapter Teaches" and "Install Order."

3. MOOTx01 maintainers, "MOOTx01 Session Ritual," `apps/moot-agent-skills/shared/MOOTX01_SESSION_RITUAL.md`, especially "After Bulk Ingest."

4. Bob Pankratz, "You Still Have to Write the Manual," LinkedIn, July 9, 2026, https://www.linkedin.com/pulse/you-still-have-write-manual-bob-pankratz-swsuc/.

---

[← Previous: The Prototype Is Not the Product](01-the-prototype-is-not-the-product.md) | [Series index](../README.md) | [Technical edition](../technical/02-you-still-have-to-write-the-manual.md) | [Next: AI Doesn't Need a Good Installer, But You Still Do →](03-the-installer-is-part-of-the-product.md)

Originally published on [LinkedIn](https://www.linkedin.com/pulse/you-still-have-write-manual-bob-pankratz-swsuc/) on 2026-07-09. Revised for this repository on 2026-07-22.

Copyright 2026 Codedaptive LLC. Article text licensed under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
