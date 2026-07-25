---
version: v0.1
---

# Continuous Obsidian Vault Sync

MOOT can continuously sync your Public memories with an [Obsidian](https://obsidian.md) vault. When enabled, your Public memories appear as `.md` files in your vault, and notes you add to the vault flow back into your estate.

## What syncs and what doesn't

| Memory tier | Syncs to vault? |
|---|---|
| Public | Yes — visible in vault as `.md` files |
| Normal / Elevated | No |
| Restricted | No |
| Secret | No |

The sync is one-way for private content: **vault deletions never erase estate memories.** If you delete a note from Obsidian, MOOT records the event but keeps the memory. You can review blocked deletions in the daemon log.

## Enabling vault sync

### In the app (Settings)

1. Open **Settings** (Cmd+, on macOS, or the gear icon on iOS).
2. Scroll to the **Obsidian Vault** section.
3. Toggle **Obsidian Vault Sync** on.
4. Enter the full path to your vault directory (e.g. `/Users/you/Documents/MyVault`).

> The app saves your preference. The daemon connection requires the `MOOTX01_VAULT_PATH` environment variable (see below). A future update will wire the preference directly.

### In the daemon (environment variable)

Set `MOOTX01_VAULT_PATH` to the vault root before starting `moot serve` or `aria-mcp`:

```sh
export MOOTX01_VAULT_PATH=/Users/you/Documents/MyVault
moot serve
```

The daemon also reads `MOOTX01_VAULT_ESTATE_POLL_S` (default 60) to control how often it pushes new memories from the estate to the vault.

## How it works

**Vault → estate (import):** A watcher polls the vault every 10 seconds (configurable). When `.md` files change, they are imported into your estate as unconfirmed memories. Multiple rapid saves collapse into one import.

**Estate → vault (export):** Every 60 seconds (configurable), the daemon exports all Public memories to the vault as `.md` files. Only Public memories are exported — the privacy fence is enforced by the daemon and cannot be overridden from the vault side.

**Conflict policy:** The estate is always authoritative. If the same memory is edited in both the estate and the vault between two sync cycles, the estate version wins. The vault file is overwritten with the estate content. The conflict is logged but never auto-resolved silently.

## Troubleshooting

**No `.md` files appear in the vault:** Check that you have at least one memory set to **Public** exportability. Normal and Elevated memories are not exported.

**Notes I added to the vault didn't appear in MOOT:** The import runs on a 10-second poll cycle. Wait a few seconds and check again. If the note still doesn't appear, verify the file has a `.md` extension and isn't hidden.

**Daemon log shows "vault resident: start failed":** Verify the vault path exists and is a directory. Check the path with `ls -la "$MOOTX01_VAULT_PATH"`.
