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
- Sensitive private material unless retention is appropriate and expected.
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

Good locations:

- `project/importer/decisions`
- `user/preferences/codex`
- `mootx01/architecture`
- `wwdc2026/swiftui/drag-drop`
- `repo/harnesses/cursor`

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
- `relates`

## Corrections

Prefer correction over deletion:

- Confirm verified memories.
- Contest uncertain memories.
- Withdraw stale memories.
- Retire false facts.
- Erase only when explicit permanent deletion is required.

