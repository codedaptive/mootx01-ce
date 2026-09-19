---
status: decided
question: The estate is encrypted at rest (ADR-014), but the Vault feature (moot_vault_export / moot_vault_reconcile) is a bidirectional plaintext seam any connected agent can drive — export decrypts the estate to human-readable markdown on disk (an exfiltration surface), and import reads plaintext disk files back into the estate (an injection/corruption surface). How should Vault be governed across the 1.0.x-beta line and 1.1?
authors: MOOTx01 maintainers
date: 2026-06-18
version: 1.0.0
relates_to:
  - docs/decisions/ADR-014-apple-sqlcipher-at-rest.md
  - docs/reference/PERSISTENCEKIT_SPEC.md
description: Vault ships OPEN (no authorization gate) through the 1.0.x-beta line as a deliberate, eyes-open posture — its plaintext portability is the feature that lets users trust and own their data during beta. A coarse install-time on/off switch is the interim control. A full authorization gate (off by default; export and import gated behind a consent mechanism the agent cannot satisfy alone) is a planned 1.1 hardening feature.
---

# ADR-015 — Vault security posture: open in 1.0.x-beta, gated in 1.1

## Context

ADR-014 makes the estate encrypted at rest (SQLCipher whole-file). That key is
loaded transparently by the resident daemon / app, so the protection is against
an **offline** reader or another process opening the database file — not against
operations performed *inside* a live, authenticated session.

The **Vault** feature is exactly such an in-session operation, and it is a
**bidirectional plaintext seam**:

- **`moot_vault_export`** reads the decrypted estate and writes
  **human-readable markdown** to a directory on disk (a wing/room/ tree plus a
  SHA-256 manifest). This is an **exfiltration surface**: any agent connected to
  the MCP surface can one-shot dump the entire estate to plaintext, bypassing
  at-rest encryption entirely.
- **`moot_vault_reconcile` (apply)** reads plaintext markdown from disk back
  **into** the estate. This is an **injection / corruption surface**: anything
  that can write the vault files can have its content pulled into the estate on
  reconcile. (This is the path through which an out-of-range timestamp entered
  an estate during drive-testing and bricked its drawer store.)

Vault's value and its risk are the same property. The plaintext, on-disk,
Obsidian-editable form is **why** users can trust and own their memory —
inspectable, portable, recoverable, not locked inside an opaque database — and
it is **also** the exfiltration/injection surface. The feature cannot be both
fully transparent and fully sealed at once.

## Decision

### 1.0.x-beta — Vault ships OPEN, eyes open

Through the 1.0.x-beta line, Vault is available with **no authorization gate**.
This is a deliberate posture, not an oversight: the open, plaintext-portable
Vault is what lets users trust their data is safe and theirs during the beta,
and that flexibility is necessary while the substrate and the
edit-on-disk/sync workflows stabilize.

We accept, explicitly, that in this posture Vault is a **data-exfiltration
surface** and a **data-corruption (injection) surface** drivable by any
connected agent.

The mitigations that **do** ship in 1.0.x are **correctness**, not
authorization:
- At-rest encryption of the estate (ADR-014).
- Vault **export fails loud** instead of reporting a successful zero-note export
  when drawer reads fail (no false "backup").
- Vault **import validates/clamps timestamps** so a malformed note cannot
  persist an out-of-range value, and the corpus read path is resilient to a
  single corrupt row (skip-and-log) rather than failing the whole estate.
- Every export/import is recorded in the estate journal/audit trail.

These reduce silent failure and accidental corruption; they do **not** add a
human-in-the-loop authorization gate. That is intentional for beta.

### 1.0.x interim control — coarse install on/off switch

To give a deployment that cannot accept the surface a real off-switch *before*
the 1.1 gate, the installer exposes Vault as an install-time choice:

```
mootx01 install --vault-on     # expose the Vault MCP tools
mootx01 install --vault-off    # hide the Vault MCP tools entirely
```

This is a **blunt, all-or-nothing** control: it exposes or withholds the Vault
tool surface (`moot_vault_export`, `moot_vault_reconcile`, `moot_vault_status`,
`moot_vault_job`, `moot_vault_import`) at the MCP layer. It is not a per-
operation gate and carries no passphrase. A deployment that wants neither the
exfil nor the injection surface installs with Vault off and gives up
import/export in exchange.

**Default: `--vault-on`.** Vault is available by default — that is the
flexibility the 1.0.x-beta posture intends. `--vault-off` is the opt-out for a
more secure position, at the cost of import/export.

**Mandatory disclosure in the post-install "next steps" prompt.** Because the
default exposes the surface, the user MUST be told plainly. After the GitHub
install lands and the installer prints the next-steps prompt that directs the
user to run `mootx01 install` (wire AI clients / activate the daemon), that
prompt MUST state, in plain language:

- Vault is **on by default**, which enables memory **import/export** to/from
  human-readable files on disk.
- For a **more secure position**, install with **`--vault-off`**, which
  **disables import/export**.

This disclosure is a ship requirement for `install.sh`, `install.ps1`, and the
`mootx01 install` flow — the user must make an informed choice rather than
discover the surface later. The wording follows planned-feature framing (a
capability and its security trade-off), not incident/vulnerability framing.

### 1.1 — Vault authorization gate (planned hardening)

In 1.1, Vault becomes a deliberate, human-authorized sync rather than a silent
decrypt-and-dump. The design:

- **Off by default.** No Vault export/import exists until the user **initializes
  Vault** — a conscious, human-only step in moot-mgr (not reachable through the
  agent), at which point the user also fixes the **export directory** (the agent
  cannot redirect an export elsewhere).
- **Both directions are gated** — export (exfiltration) *and* import/reconcile
  (injection). The import gate is specifically what stops external files being
  pulled into the estate without consent.
- **The gate must be one the agent cannot satisfy on its own.** A stored
  passphrase that lives where the agent already reads the estate key is theater.
  The control is a user-supplied secret at time of use, or OS-backed user
  authentication (Touch ID / Secure Enclave / an out-of-band approval prompt) —
  something the agent cannot script or replay.
- **The gate protects the *operation* (consent), not the *output*.** Exported
  files remain plaintext markdown by design (that is the Obsidian-edit point).
  The guarantee is "no silent exfiltration, no silent injection," not "exported
  files are encrypted."

**UX shape (to be finalized when 1.1 is specced):** for non-Vault users,
nothing changes and the surface does not exist. For Vault users, one
unlock-or-approve step gates the powerful operation — candidate models are a
**session unlock** (lower friction, open-window risk) and **per-operation
approval** (tighter, more interruptive), with a likely asymmetry of
per-operation approval on **import** (the dangerous direction) and session
unlock on **export**. Touch-ID-style consent is preferred over a remembered
passphrase (nothing to forget; losing it loses no data because the files are
plaintext).

## Consequences

- 1.0.x-beta users get the full, frictionless, trust-building Vault, with the
  exfil/injection surface documented and accepted.
- Deployments that cannot accept the surface have a coarse off-switch at install
  (once built).
- 1.1 closes the surface for users who want the gate, without taking the
  plaintext-portability that makes Vault valuable away from those who don't.
- This ADR is the record that the open 1.0.x posture is a **decision**, so it is
  never mistaken for an unrecognized vulnerability.

## Changelog

### 1.0.0 -- 2026-06-18
Initial decision. Vault open through 1.0.x-beta (correctness mitigations only:
export fail-loud, import timestamp validation, scan resilience, audit trail);
coarse `mootx01 install --vault-on/--vault-off` switch as the interim control,
**default `--vault-on`**; the post-install next-steps prompt
(`install.sh`/`install.ps1`/`mootx01 install`) MUST disclose the vault-on
default and the `--vault-off` opt-out (disables import/export) so the user
chooses informed; full authorization gate (off by default, both directions,
agent-unsatisfiable consent, operation-not-output protection) planned for 1.1.
