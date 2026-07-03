# Gemini CLI MOOTx01 Adapter

Gemini CLI reads `GEMINI.md` context files from the project root, parent
directories, and the user-level `~/.gemini/` directory. This adapter includes:

- `GEMINI.md` - always-on project instruction block.

Copy `GEMINI.md` into a repository root for one project, or into
`~/.gemini/GEMINI.md` for all projects. If a `GEMINI.md` already exists,
merge this content into it instead of replacing it.

Gemini CLI also supports lifecycle hooks (enabled by default since v0.26.0).
This adapter ships context instructions only; a hook set equivalent to the
Claude adapter's context meter is a candidate for a future release once the
Gemini hook schema is verified against a pinned CLI version.

Test after installing:

```text
Where were we?
```

The agent should orient with `moot_estate_ping`, `moot_estate_status`, and
`moot_read_journal` before answering.
