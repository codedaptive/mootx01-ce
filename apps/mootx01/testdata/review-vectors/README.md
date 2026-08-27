# Review Canonical Vectors

Language-neutral canonical test vectors for the review session engine.

Each vector file defines a specific estate input (drawer set) and the expected
canonical session output. Both the Swift implementation (CommunityReviewEngine)
and the Rust implementation (Wave B2) must produce byte-identical sessions from
the same input.

## Format

```json
{
  "vectorID": "...",
  "description": "...",
  "kind": "morning|endOfDay|weekly",
  "now": "<ISO8601 with fractional seconds>",
  "drawers": [ ... DrawerInput objects ... ],
  "expectedSession": { ... ReviewSession object ... }
}
```

### DrawerInput fields

- `id`: string — the drawer's stable id (used as-is; no conversion)
- `subject`: string? — optional subject field
- `content`: string — verbatim content
- `filedAt`: string — ISO8601 timestamp
- `tombstonedAt`: string? — if present, the drawer is excluded from the session

### Canonical JSON serialization rules

All JSON in these vector files uses:
- Sorted keys (alphabetical at every level)
- Compact encoding (no extra whitespace except as defined here)
- UUID values: lowercase hyphenated strings (e.g. "68450a7d-0df3-55c0-b6ac-6f6a1826af5a")
- Date values: ISO8601 with fractional seconds in UTC (e.g. "2026-08-23T09:00:00.000Z")
- Boolean values: JSON true/false
- No trailing commas

### ID derivation

All session, section, item, action, group, and choice IDs are derived via:
  SHA-256(namespace_bytes + NULL_JOINED_INPUT_UTF8), first 16 bytes,
  with UUID version bits = 0x50 (byte 6) and variant bits = 0x80 (byte 8).

Namespace: 4c6f7257-5265-7669-6577-000000000001

See CommunityReviewEngine.swift for the Swift implementation and
the Rust review engine (Wave B2) for the equivalent Rust implementation.

### Estate fingerprint

Format: "sha256:{first32hexchars}:{activeDrawerCount}"
Hash input: sorted active drawer IDs joined by "\n" (newline).
An empty estate produces "sha256:{sha256_of_empty_string}:0".

## Vector files

| File | Description |
|------|-------------|
| morning-single-drawer.json | Morning session with one drawer |
| morning-duplicate-group.json | Morning session with two drawers sharing the same subject |
| endofday-single-drawer.json | End-of-day session with one drawer |
| weekly-single-drawer.json | Weekly session with one drawer |
| empty-estate.json | Any kind session with an empty estate (no drawers) |
