# MOOTx01 Memory Policy

Use MOOTx01 to preserve knowledge deliberately. The goal is not to capture
everything. The goal is to make future agents cheaper, more accurate, and less
forgetful.

## Write When

Write to MOOTx01 when:

- The user states a durable preference.
- A decision is made.
- A correction invalidates older memory.
- A source-backed fact is established.
- A task leaves useful future context.
- Two memories should be connected.
- A contradiction or unresolved question remains.
- A corpus or source set has been imported, reconciled, or summarized.
- A workflow, command, path, or project convention is discovered and likely useful again.

## Do Not Write

Do not write:

- Throwaway chain-of-thought or speculative reasoning.
- Guesses that have not been labeled as guesses.
- Secrets, credentials, tokens, API keys, or raw private data — ever. Other
  sensitive private material only when retention is clearly appropriate and expected.
- Huge undifferentiated blobs when smaller memories would recall better.
- Generated summaries as if they were original source material.
- Tool failures with no durable lesson.

## Memory Shape

Good memory:

- Small and focused.
- Names the decision, fact, source, or correction.
- Includes a useful location.
- Separates evidence from inference.
- Preserves important dates, paths, versions, names, and identifiers.

Good locations (the `location` argument is the room/topic path):

- `project/importer/decisions`
- `user/preferences/codex`
- `mootx01/architecture`
- `wwdc2026/swiftui/drag-drop`
- `repo/harnesses/cursor`

## Wings — file by role

Every estate is organized along two independent axes: the **wing** (what role
a memory plays / where it came from) and the **location** (its room/topic path).
Subject classification is handled separately by the estate itself, so your job
is to pick the right wing.

Orient first: call `moot_estate_map`. It lists each wing inline with its
**charter** — a short memory stating what that wing is for. A fresh estate seeds
seven default wings:

- **Agentic Memory** (the default) — your own observations, inferences,
  decisions, and session learnings.
- **User Canon** — the user's explicit directives, preferences, corrections, and
  standing orders. Authoritative: weight these above your own inferences and do
  not silently overwrite them.
- **Source Corpus** — imported or ingested documents and reference material;
  external grounding, not your beliefs.
- **Personal** — the user's personal-life domain.
- **Professional** — the user's work domain.
- **Projects** — active project or workspace context.
- **Temp** — scratch and ephemeral notes.

File by role using the `wing` argument on `moot_file_memory`. Omit it and a
memory lands in Agentic Memory. The wing set is a suggestion, not a constraint —
create a new wing (and write its charter) when a role genuinely needs one.

Recall spans all wings by default. Pass `wing` to scope deliberately — for
example, answer from User Canon only, or exclude Source Corpus from synthesis.

## Facts

Use `moot_file_fact` for stable triples:

- subject: `Importer`
- predicate: `shipsBehindFlag`
- object: `true`

Facts are for stable claims. Memories preserve context.

## Links

Use `moot_link_memories` when a relationship should be durable:

- `supports`
- `contradicts`
- `refines`
- `extends`
- `precedes`
- `exemplifies`
- `supersedes`
- `references`
- `blocks`
- `validates`
- `derivesFrom`
- `covers`
- `elaborates`
- `respondsTo`
- `relates`

## Corrections

Prefer correction over deletion:

- Confirm verified memories.
- Contest uncertain memories.
- Withdraw stale memories.
- Retire false facts.
- Erase only when explicit permanent deletion is required — and ask the user for
  approval first when the tool's semantics are destructive (e.g. `moot_erase_memory`).

