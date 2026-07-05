---
status: decided
version: 1.0.1
question: How does a human approve reading restricted ("private") and secret rows through the ARIA surface, for how long, and through what mechanism on each platform?
authors: MOOTx01 maintainers
date: 2026-07-05
relates_to:
  - docs/decisions/ADR-014-apple-sqlcipher-at-rest.md
  - docs/decisions/ADR-015-vault-security-posture.md
  - docs/decisions/ADR-024-mcp-connection-ownership-and-install-dedupe.md
supersedes: none
context:
  - The sensitivity axis (provenance bits 30–35) defines normal/elevated/restricted/secret. The default recall ceiling is sensitivityAtMost(.elevated); restricted/secret rows are excluded from results and (per the v1.0.17 search-redaction parity fix) redacted from previews.
  - Until now there was no way to SEE a restricted/secret row through ARIA at all — the gate existed with no approval mechanism behind it.
---

# ADR-025 — Sensitivity unlock: grants, TTLs, and the out-of-band approval seam

## Decision

### 1. Grant policy (Bob-ruled, 2026-07-04)

- **Restricted ("show private"): an on/off grant that resets to OFF at local
  start-of-day.** Turning it on lasts until the next local midnight, then the
  estate is private again.
- **Secret: a 30-minute grant, fixed from the moment of approval** — not
  sliding. Renewal requires a fresh approval; a sliding window would let one
  approval live indefinitely under steady use.
- Grants are **daemon RAM state only**, never persisted. Daemon restart =
  everything locked. Fail closed on any ambiguity (clock skew, missing state,
  undecodable policy).
- Determinism: expiry is computed from the `now` passed at grant time; no
  engine calls Date()/SystemTime internally.
- A secret grant does not imply a restricted grant or vice versa; the two are
  independent. `mootx01 lock` drops all grants immediately.

### 2. Approval mechanism — one seam, per-platform backends

A single `UnlockAuthority` protocol/trait (the PersistenceKit/ConvergenceKit
backend pattern) with platform backends:

- **Swift (macOS/iOS): LocalAuthentication** — Touch ID / Apple Watch /
  account password via `LAContext`. No stored password of ours exists; the OS
  attests user presence. This is the Apple-first-party rule applied. Keychain
  is NOT used to persist grants — grants deliberately die with the daemon.
- **Rust (Linux/Windows): two discrete passwords set at estate creation** —
  one for restricted, one for secret (they may differ). Stored in estate meta
  as salted slow-KDF hashes (PBKDF2-HMAC-SHA256 at a cost consistent with the
  approved crypto surface; never plaintext, never reversible). `mootx01 unlock
  private|secret` prompts and verifies against the hash daemon-side.
  **No recovery path**: a lost password means those rows stay sealed. This is
  documented behavior, not a gap — a recovery backdoor would be a second,
  weaker door. Windows Hello / OS keyrings may become nicer backends behind
  the same seam later; passwords are the honest floor for headless servers.

### 3. The structural rule: approval never travels through the MCP surface

There is **no `moot_unlock` tool and there never will be** — a prompt-injected
model could call it. The approval channel is physically separate from the
model's channel:

- Search/recall over locked tiers reports plainly, WITHOUT an exact count —
  the count of matching sensitive rows is itself a leak (it confirms to a
  model that N secrets match a probe query). Two cases:
  (a) rows present in results whose previews were redacted carry their
  per-row redaction marker (free — the rows are already in hand);
  (b) rows excluded by the ceiling produce a static advisory line —
  `"results may be hidden by sensitivity tier — run `mootx01 unlock
  private` to include them"` — emitted only when the estate contains any
  restricted/secret rows at all (a cheap estate-level stat, never a
  per-query probe with the ceiling lifted).
- The human approves out-of-band: the `mootx01 unlock` CLI (v1; moot-mgr and
  the app shells later, behind the same UnlockAuthority seam).
- The daemon's grant endpoint accepts a grant only with proof: the verified
  password digest (Rust) or a grant asserted by the CLI after a successful
  LocalAuthentication evaluation (Swift), delivered over the loopback/UDS
  control surface.

**Implementation note — advisory stat mechanism (wave 8.2):** The "cheap
estate-level stat" described in (b) above is implemented as a **limit-1
bitmap probe**: the recall engine issues a single `LIMIT 1` query on the
sensitivity bitmap column, checks whether any restricted-or-higher row
exists, and emits the advisory line if and only if that probe returns a row.
This is O(1) per query, leaks nothing beyond "at least one such row exists"
(which the rule deliberately permits), and the ceiling is NOT lifted for
the probe — the query reads no content, no count, no identity. A write-path
counter (incrementing a stat on every capture) would have provided the same
boolean answer but added write-path complexity and a separate stat-store
surface. The probe approach was chosen as strictly sufficient: it is
privacy-equivalent, correct, and simpler. No deferred write-path counter
is planned.

### 4. Audit

Every grant, every denial, every manual revocation (`mootx01 lock`), and
every read served under an active grant is written to the UnifiedAuditLog
with tier, grant id, and timestamps. Expiry is not a logged event: grants
lapse passively by time, and the issued record carries its expiry
timestamp, so expiry is derivable from the log without an expiry-time
writer existing. Sensitivity-unlock events use NEW dedicated audit verbs —
the existing `grantIssued`/`grantRevoked` verbs are reserved for the
federation sharing feature and are not reused. Sensitive content never
appears in the log — row ids only.

### 5. Threat model and residual risk (stated honestly)

The adversary this defends against is the **MCP-surface client**: a model
(or a prompt-injection payload riding through one) that can call tools but
cannot act as the local user. It does NOT defend against an agent granted
unrestricted local shell access as the same user — such an agent can read
the estate file directly under the current at-rest posture (ADR-014 governs
that layer). On Swift, the CLI-asserted grant after LocalAuthentication is
trusted from a same-user process over the 0600 control surface; this is an
accepted residual within the same boundary. Per-connection grants (one
client sees private, another doesn't) are an EE/OAuth-era concern, deferred
with federation.

## Consequences

- Restricted/secret rows become reachable through ARIA for the first time —
  gated, time-boxed, audited, and only ever by human action.
- Fresh estates on Rust prompt for the two passwords at creation (or accept
  `--no-sensitive-tiers` to leave both tiers permanently sealed until set).
- The daily reset means at most one terminal command per day to work with
  private material; if that friction is wrong in practice, the knob is the
  reset boundary, not the mechanism.
- Swift and Rust reach behavioral parity at the policy layer (grants, TTLs,
  redaction, audit) while the approval backends differ per platform — parity
  of the call tree above the seam, platform truth below it.

## Verification

- Policy tests both ports: grant → visible; expiry (midnight / 30 min) →
  redacted again; restart → locked; secret/restricted independence.
- No-MCP-unlock test: the tool inventory contains no unlock verb (guard test
  over the projection, both ports).
- Rust: wrong password → denial + audit entry; hash never round-trips.
- Audit entries present for grant/expiry/read-under-grant.

## Changelog

| Version | Date | Change |
|---|---|---|
| 1.0.0 | 2026-07-04 | Initial decided record. |
| 1.0.1 | 2026-07-05 | §3: added implementation note clarifying that the advisory-stat mechanism uses a limit-1 bitmap probe (not a write-path counter), explaining why the probe is privacy-equivalent to the §3 "cheap estate-level stat" description. |
