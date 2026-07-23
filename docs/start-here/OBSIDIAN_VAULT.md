# Maintain an Obsidian vault

MOOTx01 can project an estate into a normal Markdown vault, import Markdown
notes into an estate, and compare a vault with the manifest written by the
last export. Obsidian can open that directory like any other vault.

In version 1.0 these operations are on demand. MOOTx01 does not continuously
watch the directory and does not automatically keep both sides synchronized.

## Enable or disable the vault tools

Vault tools are available in a normal install. To make the filesystem
import/export surface explicit:

```sh
mootx01 install --vault-on
```

For the tighter posture that removes the vault tools from the MCP surface:

```sh
mootx01 install --vault-off
```

Restart the AI client after changing its installed MCP configuration.

## Tool map

| Tool | Operation |
|---|---|
| `moot_vault_export` | Write eligible estate content into a Markdown vault and stamp a manifest |
| `moot_vault_import` | Import a Markdown vault as a background job |
| `moot_vault_status` | Report manifest presence, note count, and last export time |
| `moot_vault_reconcile` | Compare current note hashes with the export manifest |
| `moot_vault_job` | Poll an import or export job |

The manifest lives at `.moot/export-manifest.json` inside the vault. The
directory is hidden from normal note import.

## Establish a vault

Ask the connected AI client to call:

```json
{
  "name": "moot_vault_export",
  "arguments": {
    "vaultPath": "/absolute/path/to/My Vault",
    "scope": "exportable"
  }
}
```

The default `exportable` scope includes currently believed drawers explicitly
marked public/exportable. Other scopes are:

| Scope | Meaning |
|---|---|
| `exportable` | Public/exportable current belief; safest normal default |
| `believed` | Current belief across confirmation states |
| `confirmed` | User-confirmed current belief |
| `unconfirmed` | Capture-inbox current belief |
| `believed-including-private` | Explicit private-tier widening; secret remains excluded |

Secret-tier content never uses bulk vault export. Restricted/private content is
excluded unless the explicit private scope is selected. Exclusion counts are
returned by the export.

Export and import return a `job_id`. Poll it instead of restarting a slow job:

```json
{
  "name": "moot_vault_job",
  "arguments": {
    "job_id": "<returned id>"
  }
}
```

## Edit with Obsidian

Open the exported directory in Obsidian and edit its Markdown files normally.
MOOTx01 reads both ordinary Markdown links and Obsidian `[[wikilinks]]`.
Frontmatter carries stable identity, sensitivity, exportability, provenance,
and other round-trip fields.

Keep the `.moot` directory intact. Removing its manifest prevents drift
reconciliation until another export establishes a baseline.

## Check drift

Start with a dry run:

```json
{
  "name": "moot_vault_reconcile",
  "arguments": {
    "vaultPath": "/absolute/path/to/My Vault"
  }
}
```

The result lists:

- added notes;
- modified notes;
- deleted paths;
- added and modified candidates eligible for import.

Dry-run mode writes nothing.

To import only the added and modified candidates:

```json
{
  "name": "moot_vault_reconcile",
  "arguments": {
    "vaultPath": "/absolute/path/to/My Vault",
    "apply": true
  }
}
```

Deleted files are always reported and never expunge estate drawers. Estate
deletion remains a separate, explicit operation.

## Import an existing vault

For a vault that was not created by MOOTx01:

```json
{
  "name": "moot_vault_import",
  "arguments": {
    "vaultPath": "/absolute/path/to/Existing Vault",
    "mode": "foreground"
  }
}
```

`foreground` and `background` select encoding speed, not a different write
policy. Large imports are background jobs and can take minutes. Poll the job;
do not resubmit it simply because it is still running.

Import is idempotent by stable note identity. It also:

- refuses to resurrect withdrawn or erased lineages;
- prevents a re-import from lowering an existing sensitivity tier;
- protects an existing lineage from a foreign-path identity claim;
- reports unchanged and skipped notes.

## Resync procedure

“Resync” in version 1.0 means this explicit sequence:

1. `moot_vault_status` — confirm the baseline manifest.
2. `moot_vault_reconcile` — inspect drift without writes.
3. Back up the estate and vault when changes are material.
4. `moot_vault_reconcile` with `apply: true` — import added/modified notes.
5. Run a fresh `moot_vault_export` when you want a new outward projection and
   manifest baseline.
6. Poll each returned job to completion.

An export is an outward projection, not a three-way merge. Preserve a backup
when both the estate and vault changed since the previous baseline.

## Planned version 1.1 continuous mode

Version 1.1 plans an optional, daemon-managed mode that continuously maintains
a normal retail Obsidian vault. It builds on the existing manifest and
reconcile behavior:

1. Establish the initial vault and manifest.
2. Watch eligible estate changes and project them into the vault.
3. Watch vault file changes and import eligible added/modified notes.
4. Run a full resync at service start, after watcher overflow or missed-event
   detection, and periodically as an integrity check.
5. Surface mode, path, last successful cycle, blocked candidates, drift, and
   failures through `moot-mgr`.

Direct stdio lives only as long as its parent AI client. An always-running
watcher therefore belongs to the resident service, not a per-client stdio
subprocess.

### Why it is called insecure mode

The mode continuously mirrors eligible material into a conventional directory
of readable Markdown files. Its exposure depends on filesystem permissions,
backups, synchronization services, user accounts, and Obsidian plugins. The
name describes that wider operating boundary; it does not disable the data
classification controls.

### Automated-mode data gate

Automation is intentionally narrower than the manual tools:

- outbound automation uses only public/exportable material;
- restricted and secret sensitivity tiers are blocked;
- private/non-exportable material is blocked;
- inbound automation rejects or quarantines notes marked private, restricted,
  or secret before capture;
- an automated vault edit cannot modify a lineage already classified as
  restricted or secret;
- deletions remain report-only and never automatically expunge an estate
  drawer.

Manual, authorization-gated operations remain the path for an intentional
private transfer. Secret data never uses bulk vault export.

The gate depends on correct classification. Private text incorrectly labelled
public/exportable and below the protected sensitivity tiers can still be
mirrored. Automated mode is not a content-loss-prevention classifier.

### Resync versus sync

- **Sync** is the planned incremental watcher path for ordinary eligible
  changes.
- **Resync** is a complete manifest/hash comparison used at startup, after a
  watcher gap, on schedule, or on explicit operator request.

The planned scheduler advances the manifest only after a successful cycle.
Failed or blocked candidates remain visible for operator review rather than
being silently treated as synchronized.

## Security boundary

A retail Obsidian vault is a conventional directory of readable Markdown
files. Files inherit the protections, backup behavior, synchronization tools,
plugins, and account access of that directory. Before exporting private
material, consider:

- full-disk and backup encryption;
- cloud-sync and sharing configuration;
- Obsidian community plugins;
- filesystem permissions;
- whether the target directory is indexed or backed up elsewhere.

`--vault-off` is the appropriate posture when filesystem import/export is not
needed. Classification remains important: text incorrectly marked
public/exportable cannot be protected by a sensitivity label it does not have.

## Recovery

| Condition | Safe response |
|---|---|
| Manifest missing | Export again to establish a new baseline |
| Reconcile reports unexpected changes | Stop, back up both sides, and inspect the listed paths |
| Import appears slow | Poll `moot_vault_job`; do not duplicate the job |
| File was deleted in Obsidian | Treat the report as advisory; no estate drawer was deleted |
| Private data appeared unexpectedly | Stop using the vault, secure/remove exposed copies, correct classification, and re-export |

Implementation details live in
[`../reference/VAULTKIT_INTERFACE.md`](../reference/VAULTKIT_INTERFACE.md).
