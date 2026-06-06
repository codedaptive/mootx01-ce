# Decision: VaultKit Bidirectional Identity and Export Scope

**Date:** 2026-06-05
**Stream:** cp-vault-bidir (Newton)
**Status:** ACCEPTED
**Supersedes:** ADR-VAULTKIT-002 decision (a) — "Rust mirror deliberately deferred"

---

## Context

Two problems were identified with VaultKit's original bidirectional bridge:

**Problem 1 — Confirmed-drop bug:**
The old export hard-coded `Filter.unconfirmed` as its recall filter chain. This
silently excluded user-confirmed drawers from every export. A vault produced by
`moot_vault_export` was missing the confirmed portion of the estate, with no error
or warning to the user.

**Problem 2 — Rename-unsafe round-trip identity:**
The old `stableSourceKey` was `"\(wing)/\(room)/\(drawer.id)"` — the random UUID
`drawer.id` at the end made it human-unreadable; the wing prefix created a
per-user vault layout not suitable for sharing or portable archives. On re-import
after a vault-side rename (human renames the `.md` file), the FNV hash of the new
path did not match the existing lineageID, creating a duplicate drawer instead of
updating the original.

---

## Decisions

### A — Export scope as a user preference

**Chosen approach:** a `VaultExportScope` enum with four named cases, threaded
through `DrawerMapping.export(kit:handle:scope:)`, `VaultBridge.export(estate:to:scope:)`,
and the `moot_vault_export` MCP tool `scope` argument.

**Default:** `.believed` — currently-believed drawers with any confirmation state
and any trust level. This is a strict superset of both the old `.unconfirmed` filter
and the `.confirmed` filter, fixing the confirmed-drop bug without breaking existing
workflows that export unconfirmed (capture inbox) content.

**Filter chains per scope:**
- `.believed`:    `[.currentlyBelieve, .any([.userConfirmed, .unconfirmed, .automatedConfirmedOnly]), .any([.trustworthy, .requiresConfirmation])]`
- `.exportable`:  `[.exportable, .currentlyBelieve, .any([.userConfirmed, .unconfirmed, .automatedConfirmedOnly])]`
- `.confirmed`:   `[.userConfirmed, .currentlyBelieve]`
- `.unconfirmed`: `[.unconfirmed, .currentlyBelieve]` ← the legacy hard-coded behavior

Sensitivity is intentionally left unaddressed in all scopes. The recall evaluator
supplies its `.normal`-or-below default, ensuring elevated/restricted/secret content
is never exported to a plaintext vault without the user explicitly requesting it via a
future `sensitivity` scope parameter.

**Rejected alternatives:**
- Bool `includeConfirmed` on `export` — too coarse, doesn't support the exportable tier.
- Dynamic Filter chain in the MCP tool — too low-level for a user-facing parameter;
  exposes filter algebra to the LLM.

### B — Human filenames and `moot_id` frontmatter identity (Plan B1)

**Filename rule:** stableSourceKey = `"<room>/<slug>.md"` on disk.
- **Wing is dropped from the path.** One vault = one owner, wing rides the `wing:` frontmatter key.
- **Slug derivation:** first Markdown `# heading` found on any line, else first non-empty line, sanitized to `[a-z0-9-]` max 60 chars, UUID-prefix fallback for empty content.
- **No collision risk in practice** (same-room same-title drawers are a user-data problem, not a vault problem); the sanitized slug is deterministic for a given content so re-exports are stable.

**`moot_id` frontmatter key:**
- On export, `DrawerMapping.noteIR(from:)` writes `moot_id: <drawer.lineageID>` in the frontmatter.
- `drawer.lineageID` is the STABLE substrate UUID (the FNV-1a 128-bit hash of the original stableSourceKey). It does NOT change when a drawer is superseded. `drawer.id` (the row ID) is re-minted by the supersession cascade on every capture and MUST NOT be used as the identity anchor.
- `NoteIR.mootID: UUID?` field carries this UUID through the `ObsidianAdapter → DrawerMapping` pipeline on re-import.

**Identity resolution priority on import:**
1. `NoteIR.mootID` (set by `ObsidianAdapter.toIR` from `moot_id` frontmatter) → use directly as `lineageID`.
2. `frontmatter["moot_id"]` → parse as UUID → use as `lineageID`.
3. FNV-1a 128-bit hash of `stableSourceKey` (original idempotency anchor, unchanged).

This means: after a vault-side rename, the re-import finds the existing drawer by
`moot_id` (priority 1) and updates it, producing `drawersUpdated = 1` rather than
`drawersWritten = 1`. The rename-safe round-trip is the `renamedFileWithMootIDPreservesLineage`
test in `VaultBridgeTests`.

**Rejected alternatives:**
- B2 (content hash as identity): non-trivial hash changes on any edit, creating duplicates for updated notes.
- UUID in filename: human-unreadable, defeats the stated goal.

### C — ADR-VAULTKIT-002 decision (a) is superseded

ADR-VAULTKIT-002 decision (a) stated "VaultKit ships no Rust target; the Rust
mirror is deliberately deferred." This was accurate when written (stream va, 2026-06-05);
the Rust crate was added in stream `w2-vaultkit` (Newton, 2026-06-05) and the full
ARIA_MCP Rust surface was completed in stream `cp-vault-bidir`. Both ports are now
live and in sync. The stale comment in `VaultTools.swift` and `tool_list.rs` was
corrected as part of this stream.

---

## Conformance requirement

Both ports (Swift and Rust) must produce the same slug for the same content input.
The slug algorithm is deterministic (FNV-1a hash of the content is NOT used; it is
purely text-based), so no additional cross-language test vector is required beyond the
unit tests for `slug(from:id:)` and `sanitize_slug`.

The `moot_id` value in frontmatter is the existing FNV-1a 128-bit UUID. The FNV
conformance anchor in `tests/fnv_vector.rs` covers this indirectly (same lineageID
derivation, same UUID format on both ports).

---

## Tests added

**Swift VaultKit:**
- `believedScopeIncludesConfirmedDrawers` — the confirmed-drop bug fix
- `unconfirmedScopeExportsOnlyUnconfirmed` — regression guard for old behavior
- `mootIDPreservesLineageOnRoundTrip` — export → import produces `drawersUpdated` not `drawersWritten`
- `renamedFileWithMootIDPreservesLineage` — rename-safe identity
- `exportProjection` — asserts `moot_id` in frontmatter, `stableSourceKey` format, `originalPath` room-only
- `slugDerivation` — covers heading/first-line/punctuation/empty/heading-on-any-line cases
- `mootIDWinsOverFNV` — identity priority assertion
- `absentMootIDFallsBack` — FNV fallback when no `moot_id`

**Rust VaultKit:**
- `moot_id_wins_over_fnv_in_make_capture_frame` — matches Swift
- `absent_moot_id_falls_back_to_fnv` — matches Swift
- `slug_from_heading`, `slug_from_first_line_no_heading`, `slug_punctuation_collapse`,
  `slug_empty_content_produces_uuid_prefix`, `slug_heading_on_any_line_wins`
- `from_str_round_trips`, `default_is_believed`, etc. for `VaultExportScope`
