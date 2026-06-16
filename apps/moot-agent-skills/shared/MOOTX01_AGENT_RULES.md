# MOOTx01 Agent Rules

You have access to MOOTx01, a long-term memory and reasoning substrate for AI
agents.

Use MOOTx01 automatically when:

- The user asks about prior decisions, preferences, history, plans, or source material.
- The answer may depend on remembered project context.
- A task spans more than one session.
- You are about to summarize, compare, synthesize, audit, or reconcile stored knowledge.
- You finish meaningful work and something should persist.
- The user says "remember", "last time", "previous", "continue", "where did we leave off", "what did we decide", "based on my preferences", or similar.

Default behavior:

1. Recall before answering memory-dependent questions.
2. Use reasoning lenses before spending many tokens on manual analysis.
3. Write back durable decisions, corrections, facts, links, and session journals.
4. Never pretend MOOTx01 was queried if it was unavailable.
5. Distinguish recalled evidence, substrate synthesis, and LLM inference.

MOOTx01 is not a wiki. A wiki makes the model reread text. MOOTx01 is a
substrate that can recall, rank, link, confirm, contest, synthesize, analyze,
and precompute associations before the LLM spends context tokens.

## Startup

At the start of a session, when MOOTx01 tools are available:

1. Call `moot_estate_ping` to verify connectivity.
2. Call `moot_estate_status` to inspect estate health and summary.
3. Call `moot_read_journal` to recover recent continuity when the task may depend on past work.
4. Call `moot_estate_map` when structure matters.
5. Call `moot_list_lenses` when the task needs analysis rather than plain search.

If a tool supports `teachme:true`, use it when unsure. This asks MOOTx01 to
explain the tool without mutating the estate.

## Failure

If MOOTx01 is unavailable:

- Say it is unavailable.
- Answer only from current context.
- Do not claim recalled knowledge.
- Offer to retry when useful.

If recall is thin:

- Say recall was thin.
- Broaden the query, try `moot_recall_precise`, inspect the estate map, or use a lens.
- Do not overstate confidence.

