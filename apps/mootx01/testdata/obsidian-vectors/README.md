# Obsidian Sync Status Vectors

Language-neutral (Swift + Rust) test vectors for `moot_community_obsidian_status`
state-machine transitions. Each JSON file contains an array of status snapshot
objects that CommunityObsidianTests.swift loads and validates against the CORE-06
contract invariants.

## Format

Every status snapshot object must obey these rules:

1. **`state`** (string, required): one of
   `starting | scanning | synchronizing | idle | waiting | paused |
    interrupted | blocked | failed`

2. **`checkpointAt` / `recordCount`** — both present or both absent (never
   one without the other).

3. **`pendingCount` / `totalCount`** — both present or both absent, and
   `pendingCount <= totalCount`.

4. **`reason`** — required when `state` is `interrupted`, `blocked`, or `failed`.

5. **`retryable`** (boolean) — required when `state` is `interrupted` or `failed`.

## Invariant summary (machine-checkable)

```
IF checkpointAt != null THEN recordCount != null (and vice versa)
IF pendingCount != null THEN totalCount != null (and vice versa)
IF pendingCount != null AND totalCount != null THEN pendingCount <= totalCount
IF state IN [interrupted, blocked, failed] THEN reason != null
IF state IN [interrupted, failed] THEN retryable != null
```

## Files

| File | Description |
|------|-------------|
| `status-lifecycle.json` | Full state-machine lifecycle: no-auth → select → enable → sync → idle → disable → paused |
| `status-error-states.json` | Error/interruption scenarios: vault loss, access revoked, non-retryable failure |
| `status-checkpoint.json` | Checkpoint field invariants across states |
| `status-synchronizing.json` | `synchronizing` state with various pendingCount/totalCount pairs |

## Usage

CommunityObsidianTests.swift (C6-T15) automatically loads all `*.json` files from
this directory at test time and validates each entry against the invariants above.

New vectors can be added by dropping additional `*.json` files here. The test
harness picks them up without code changes.
