---
status: decided
question: "How does one estate disclose to another, and what does the substrate guarantee about that disclosure?"
authors: MOOTx01 maintainers
date: 2026-05-21
relates_to:
  - docs/engineering/GENIUSLOCUS_ENGINEERING_COOKBOOK.md (§2.3 sensitivity, §3.5 Block 3 provenance, §3.7 shared seed families, §12 federation)
  - docs/decisions/DECISION_SYNCKIT_DESIGN_2026-05-19.md (§8 per-estate Ed25519 identity, signed handshake)
supersedes: none
context:
  - Federation lets one estate disclose to another; the substrate must guarantee who counts as told.
  - Builds on per-estate Ed25519 identity and the signed pairing handshake.
---

# Decision: Federation Sharing and Disclosure Model

## 1. Summary

This document specifies how one estate discloses to another, and what the substrate guarantees about that disclosure. It defines a trust doctrine, a cryptographic spine, two orthogonal disclosure dials, a disclosure ledger, and a risk-level chooser that lets a person pick how much they are trusting the cipher versus trusting the recipient.

The thesis the whole model serves is plain. A secret told is not a secret. Cryptography and provenance do not change that truth. They decide who counts as told, they keep the accidental and the passive paths from ever counting as told, and they keep an honest record of every deliberate telling. The system's job is not to make betrayal impossible, because that is impossible between people and equally impossible in software. Its job is narrower and achievable: make sure you only ever tell the party you meant to tell, make sure no one in the middle or in storage is told by accident, and keep a faithful record of every deliberate telling so trust can be audited and revised.

These positions are approved. The decisions that were once open are recorded as resolved in section 12, with the key-custody and encryption-mode mechanics detailed in Appendices A and B.

## 2. Threat model

The model is stated against a set of adversaries in increasing order of hostility. The first set assumes the other estate runs honest substrate code. The second set does not.

Honest-but-curious peer. A paired estate that follows the protocol but would learn more than intended if the protocol allowed it. Defended by scope, provenance filtering, and inference budget.

Untrusted remote store. A relay, cloud zone, or aggregator that carries or holds data in transit or at rest. Defended by at-rest and in-transit encryption to keys the store does not hold. The store is a blind courier.

Transitive disclosure, the A, B, C case. A is paired with B, B is paired with C, A is not paired with C. A asks B about something both B and C know. A is entitled to B's own knowledge, never to C's knowledge, unless A holds its own keypair relationship with C. Defended by non-transitive pairing, per-scope keys, and provenance binding. This is the central case the model is built around.

Malicious partner. A legitimately paired estate that lies within the protocol: forging events, relabeling provenance, stamping implausible clocks, or probing the similarity oracle. Defended by signed events, signed-at-rest provenance, admission control, and inference budget.

Man in the middle. An attacker on the wire or on the pairing channel. Defended by signed and encrypted payloads and by an out-of-band pairing step strong enough that a network attacker cannot substitute keys.

The honest boundary. B is the intended recipient of what A shares with B, so B must be able to read it. Encryption cannot protect data from the party whose job is to decrypt it. A recipient who reads plaintext during a live window can re-type it by hand into a new row. This willing-deputy path, the analog hole, is unpreventable. The model shrinks every other path to zero and makes this one deliberate, attributable, and recorded.

## 3. Cryptographic spine

Five mechanisms carry the model. The first two already exist in the design. The rest are this document's proposals.

Per-estate identity. Each estate holds an Ed25519 keypair generated on first launch (ConvergenceKit §8). Identity is per-estate, not per-device or per-user. Two estates never implicitly trust each other.

Sign with origin, then encrypt to recipient. Every outbound payload is signed by the originating estate's key and then encrypted to the intended recipient, scoped to the specific pairing. Signing proves authorship. Encrypting proves only that the recipient can open it, which is why both are required and why the order is sign-then-encrypt.

Encryption at rest. Every estate holds only its own data, encrypted to its owner key. A shared row held by a recipient is held as ciphertext encrypted to the pairing scope, not as plaintext. This upgrades provenance from a software tag a malicious estate could flip into a key-possession fact: a party that does not hold the scope key cannot read the scope data, in storage or anywhere else.

No durable cross-estate opener (open-source posture). The substrate never mints a durable key for another estate's data. Every cross-estate disclosure is carried by an ephemeral key derived at the moment of transfer or session, with a bound lifetime, after which the key is unrecoverable and the payload is permanently opaque. The death is the death of the key, not a fiction about self-rotting bytes. A contact-derived handshake, such as an NFC touch running a fresh X25519 exchange with both private halves discarded, is the clean instantiation. This is the structural reason a recipient cannot hold another estate's data beyond its window.

Provenance binding. The originating estate's signature travels with its rows and is retained, so authorship is end-to-end rather than verified once at a hop and discarded. A relabeled row is detectable because it claims one author but carries another's signature, or lacks the expected one. This is what makes the A, B, C guarantee hold against a hostile B rather than only an honest one.

## 4. The two disclosure dials

Disclosure is governed by two independent axes that compose. A person chooses, per row or per grant, a position on each.

The content axis is how much crosses. The protection axis is how it is protected. Opinion sharing rather than fact sharing, the case of a person saying they value a topic without saying what they know about it, lives on the content axis: it is a low position on what-crosses, not a setting on how-protected.

### 4.1. Content axis (what crosses), most disclosed to least

| Level | What the recipient receives | Typical use |
|---|---|---|
| Verbatim content | The row's actual text or blob | Full sharing with a trusted partner |
| Knowledge-graph fact | A subject-predicate-object proposition, no surrounding content | Share a fact, not the note it came from |
| Structured field | Named attributes only, the rest withheld | Share a date or a status, not the body |
| Aggregate statistic | Counts and correlations, differentially private | Contribute to a fleet or tier without exposing rows |
| Salience or posture | The weight of a topic: centrality, engagement, "I value this" | Opinion sharing, not fact sharing |
| Existence only | Acknowledge a topic exists, no content at all | Confirm overlap without disclosure |
| Nothing | No disclosure | Default for private and secret |

Salience or posture sharing is a first-class second channel, not a redaction of content sharing. The fact lives in the row's verbatim content and its knowledge-graph propositions. The posture lives in the matrix tier and the fingerprint, the correlations, the keystone centrality, the behavioral-recency and completion structure of fingerprint Block 2 (cookbook §3.4). A row's weight is encoded separately from what the row says, so the substrate can disclose weight while disclosing no content. A determined recipient can still reconstruct from enough salience queries, which is why this channel carries the inference budget by default.

### 4.2. Protection axis (how it is protected)

| Control | Options, weaker to stronger |
|---|---|
| Data class | shareable, private, restricted, secret |
| Grant scope | whole estate, wing, room, lattice subtree, single row |
| Share lifetime | durable, long decay, short decay, single session, single access, physically present only |
| Transport channel | relay link with token, cloud shared zone, direct peer to peer, QR scan, NFC touch, air-gapped physical |
| At rest | backend default, owner-key encrypted, owner-key encrypted with secret-tier sealed |
| Re-share | forbidden, with audit, free |
| Clawback | none, best-effort request, cryptographic revoke |
| Disclosure audit (tell record) | off, on, on with recipient countersignature |
| Inference budget | off, budgeted, tight differential-privacy ledger |
| Key custody | recipient holds the key, mediated per access, ephemeral only with no retained key |

## 5. Data classes and the constitutional bits

The adjective bitmap already carries sensitivity (normal 0, elevated 16, restricted 32, secret 48) and exportability (private 0, public 32), and invariant I-22 already forbids secret being public (cookbook §2.3, §9.5). This model extends those bits with the following rules.

Secret is an immutable latch. Once sensitivity reaches secret, the state validator refuses any transition that lowers it. The only exit from secret is expunge, which is itself recorded. Secret is a one-way ratchet, the same shape the automaton already uses for the tombstone terminal state. A mutable secret bit could be flipped down by a careless or compromised writer and the row then shared; a latch removes that path.

Secret is never shareable. No grant may name a secret row, no contribution may include it, no cross-estate fingerprint may carry it, and no scope key is ever minted for it. This is a new hard invariant alongside secret-cannot-be-public.

Private is the default-closed floor. Private is where nearly every row begins. A private row is never disclosed until a grant explicitly opens it. Sharing a private row therefore requires an affirmative act: a confirmation at share time, or a grant established during pairing setup.

Raising a row to private is reversible, unlike secret. Only secret latches one way. Moving a row from shareable to private, or sharing a private non-secret row, is a soft, reversible step gated by an explicit handshake prompt to the user: share this private, non-secret data? If the user confirms, the share carries a mandatory expiration date, after which the scope key dies per section 7, and the model assumes a responsible partner for that window. This is the affirmative act named above, made concrete: a prompt, an expiry, and a recipient trusted for the window. It also fixes the default content level for a private share: the system prompts and never auto-discloses. Secret remains the one-way ratchet that prompts nothing and mints no key.

These rules are forward-only. They govern future disclosure. They do not reach back into a copy a recipient already decrypted and read. Ratcheting a row to secret, or dissolving a grant, binds what happens next; the tell record carries the honest account of what was already disclosed.

## 6. Grants: the unit of sharing

A share is never "B may see my estate." It is a grant: an explicit, signed, audited row that names the grantee scope, the target set, and the terms. The grant is the object the provenance filter and the encryption-to-scope key both key off.

A grant carries: grantee (the paired estate), scope granularity (estate, wing, room, lattice subtree, or single row), content level (the content-axis position from section 4.1), lifetime (section 7), channel, re-share permission (section 8), clawback class, and inference budget.

Granularity runs from the whole estate down to a single row, with a lattice subtree as the natural middle unit because it follows the taxonomy the substrate already organizes by. The cookbook's open question on grant granularity (CS1-Q2) resolves here to: per-scope grant with per-row override, default-deny.

## 7. Share lifetime as key lifetime

Everything the system can actually enforce reduces to one idea: disclosure is the lifetime of a scope key. A grant mints a key. Confirmation or setup is when it is minted. A decay age is a key with a time-to-live. A clawback to secret is key revocation. Secret is the class for which no key is ever minted.

Mint on confirmation or setup. A private row's at-rest encryption stays owner-only until a confirmation or a setup grant mints the recipient-scope key.

Decay. A shared row carries a disclosure lifetime. At expiry the scope key is destroyed and the at-rest ciphertext becomes unrecoverable. The recipient is left holding bytes it can no longer open. This acts on the key, not on the recipient's good behavior, which is what makes it real. It does not reach plaintext the recipient read during the live window.

Clawback, two cases of differing force.

| Case | Force | Mechanism |
|---|---|---|
| Was public, now private, request deletion | Best-effort plus accountability | A signed request that lands on the next pairing; compliance is recorded, non-compliance shows as a missing expected event |
| Was private, now secret, request deletion | Cryptographic | Revoke the scope key; the recipient's at-rest ciphertext is dead; the row joins the never-shareable secret class going forward |

The public case is weak because public content may already have propagated; the honest word is request, not guarantee. The private-to-secret case is enforceable because private data was only ever shared as ciphertext under a scope key, so revoking the key kills the stored copy.

Physically connected only is the strongest lifetime. Access is bound to physical proximity and a contact event. There is no relay, no standing channel, and no remote path to re-acquire a key. This collapses the man-in-the-middle surface to almost nothing and makes holding data past the window structurally hard. The cost, stated plainly, is that it forbids remote and asynchronous sharing.

## 8. Re-share with audit

Re-share permission is a property of the grant, not of the row, at one of three levels.

| Level | Meaning |
|---|---|
| No re-share | Default and safe floor; the recipient may not disclose onward |
| Re-share with audit | The recipient may disclose onward, but only through the substrate, which records it |
| Free re-share | Effectively public-class; disclose at will |

Re-share with audit is honest only because re-share is mediated, not manual. In an ephemeral, no-durable-opener world the recipient cannot independently mint a key to a third estate. A permitted re-share is therefore an operation the recipient asks the substrate to perform: the substrate checks the grant allows it, derives the onward ephemeral key, and writes the disclosure event. Because the recipient cannot do the cryptographic step itself, the audit entry is a structural byproduct of the only path that can open the data onward, not a matter of the recipient's manners.

The result is a composing chain of custody. The original disclosure is signed in both logs. The onward re-share is signed, naming the origin estate, the discloser, the recipient, and the authorizing grant, and it propagates back to the origin on the next pairing. The provenance origin is carried forward unchanged, so a third estate receives the data stamped with its true origin and cannot strip the lineage without that being a fresh recorded act.

Decay composes. A child grant cannot outlive its parent, because the onward key is derived within the parent's window and dies with it.

This governs the mediated path only. It does not govern the analog hole, which appears instead as a recipient-authored row of suspiciously similar content and the absence of a re-share event.

## 9. The tell record

The tell record is a provenance and disclosure ledger: signed, append-only events that let a person ask where their data went. It is cached and retransmitted on the next pairing, which is how federation already moves audit events (cookbook §5 G-Set union). It is immutable by construction: a missing entry is detectable against what was already replicated, and a forged one fails signature.

It is named honestly as accountability, not prevention. It cannot force a dishonest recipient to record a manual re-disclosure. Its value is exactly the value of provenance in the physical world: it does not stop a leak, it tells you with cryptographic confidence what was disclosed through the honest channel and to whom, so trust can be audited and revised.

## 10. The two non-cryptographic companions

Encryption secures the envelope, not the contents and not the conversation. Two companions are always required.

Provenance filter at answer assembly. In federation the recipient usually receives a query result or a contribution, not a raw row. The discloser computes that answer over the plaintext it holds, which may include another estate's plaintext, and only then encrypts the answer. Encrypting the answer does nothing to stop it having been built from foreign-provenance rows. So the discloser must exclude foreign-provenance rows before it assembles and encrypts the response. This is the load-bearing rule for the A, B, C case: B answers A only from B-authored or B-to-A-granted rows, and C-origin rows are excluded before the reduction, both as raw rows and inside any aggregate fingerprint (cookbook §12.3, §12.5).

Inference budget. A legitimate, authenticated, encrypted partner can still issue many crafted queries and read content out of the answers it rightly receives. This is a property of what the discloser answers, not of the channel, so it needs a query budget and a differential-privacy ledger. Encryption and inference are orthogonal; a perfect cipher does not reduce the budget's necessity (cookbook §12.6).

## 11. The risk-level chooser

A person reads down a column to adopt a posture, or mixes per row. The presets run from most convenient to most private, and two further presets capture special corners. The honesty columns keep each control's promise truthful.

### 11.1. Presets across the protection axis

| Control | Open | Convenient | Balanced | Locked | In-person | Sealed |
|---|---|---|---|---|---|---|
| Data class | shareable | private | private | restricted | private | secret |
| Content level | verbatim | verbatim | fact or field | statistic | posture only | nothing |
| Grant scope | estate | room | room or row | single row | single row | none |
| Share lifetime | durable | long decay | short decay | single session | physically present | never shared |
| Transport | relay link | cloud zone | peer to peer or QR | NFC touch | NFC touch | none |
| At rest | backend default | owner-key | owner-key | owner-key sealed | owner-key sealed | owner-key sealed |
| Re-share | free | with audit | no | no | no | no |
| Clawback | none | best-effort | revoke where mediated | cryptographic | cryptographic | not applicable |
| Tell record | on | on | on | on with countersign | on with countersign | not applicable |
| Inference budget | off | off | budgeted | tight | tight | not applicable |
| Key custody | recipient holds | recipient holds | mediated | ephemeral only | ephemeral only | no key minted |

The most secure useful corner of the whole space is the In-person preset: posture only, physically connected, ephemeral key, no re-share, with a tell record. In plain terms, "I let my partner feel how much I value this topic, in person, and nothing about it can outlive the moment or travel further." It is a close reconstruction of how a careful person shares a confidence in the real world.

### 11.2. What each control actually does

| Control | Holds against a malicious recipient? | What it cannot do |
|---|---|---|
| Data class (secret latch) | Yes; secret mints no key for anyone | Forward-only; cannot recall copies already disclosed |
| Grant scope | Yes; the scope key opens only the granted set | Coarser grants widen the blast radius |
| Share lifetime (decay) | Yes if the key is ephemeral or mediated; No if a durable key was handed over | Cannot reach plaintext read during the live window |
| Transport encryption | Yes; a relay or cloud holds blind ciphertext | Protects against the store, not against the recipient device's owner |
| Pairing channel | Partly; rests on the out-of-band human step | A link channel is exposed to a middleman; proximity and code-compare close it |
| At-rest encryption | Yes; storage holds ciphertext only | Does not protect against the device's own owner |
| Re-share with audit | Yes for the mediated path; the audit entry is structural | Cannot govern manual re-typing; shows only as a missing event |
| Clawback to secret | Yes; key revocation kills the stored copy | Cannot erase what was already read |
| Clawback from public | No; best-effort request only | A dishonest holder may ignore it; visible as a missing compliance event |
| Tell record | No; this one is accountability, not prevention | A dishonest recipient can re-type without recording |
| Inference budget | Policy on what is answered | Orthogonal to encryption; still needed with a perfect cipher |

The rows marked Yes hold even when the other estate is hostile, because they reduce to whether a key exists, for how long, and who it opens for. The rows marked No or accountability hold only when the other estate is honest, and their value is to make dishonesty visible after the fact. That split is the real risk dial: the more of a posture a person pushes onto cipher-enforced rows, the less they trust the recipient's software and the more they trust only the math.

The line no preset changes, worth printing on the chooser itself: every profile still lets a person you deliberately shared live plaintext with re-disclose it by hand. The Locked and In-person profiles shrink every accidental, passive, and stored-copy path to zero and keep a signed record of the deliberate ones. They cannot shrink the deliberate path itself, because a secret told is not a secret.

## 12. Resolved decisions

The items below were open in the proposed draft. They are now resolved. The mechanics live in Appendices A and B; this section records the resolution and points to where each is specified.

Key custody, resolved. Custody is a property of the grant, chosen per share from four custody modes (Appendix B). Custody modes 1 (mediated per-access) and 2 (raw handed-over) are production at v1.0; custody modes 3 (decay-derived) and 4 (physical decay) are experimental, gated to v1.5, and carry an IP-clearance opt-in. The open-source default is custody mode 1, mediated, no durable opener, which preserves the section 3 posture. Offline access is not a separate setting: it falls out of the mode, custody mode 1 is live-only, custody mode 2 reads offline within the grant window.

Standing versus session-bound federation, resolved. Not an architectural fork; the custody mode decides it (Appendix B.6). Always-on federation uses custody mode 2, a durable handed-over shared seed. Session-bound federation uses custody mode 3, a seed that decays after the window, or custody mode 1 mediation as the production-ready fallback at v1.0. Resolved in principle at v1.0, enforced in mechanism at v1.5 when the decaying mode is required to work.

Reversibility of a private raise, resolved. Reversible, with a handshake (section 5). Only secret latches one way. Sharing a private non-secret row prompts the user, sets a mandatory expiry, and assumes a responsible partner for that window. This also fixes the default content level for a private share: prompt, never auto-disclose.

Encryption at rest, resolved. Per-record encryption under a generated, hardware-wrapped key, with four user-chosen encryption modes and a query-forwarding federation posture once encrypted (Appendix A). Encryption modes 1 through 3 are v1.0; encryption mode 4, database plus threshold, is the FedRAMP-tier experimental gate.

Deferred to a post-v1.0 tuning pass, not architecturally blocking. Decay half-lives and inference-budget epsilon and delta per content level are numeric tuning values that want real usage data and attach to the experimental, v1.5-gated features. They are deliberately left unset here; the architecture does not depend on their values. The default content level per data class is set above by the private-share handshake.

## 13. Conformance

A conforming implementation must demonstrate, by negative test as well as positive:

An A-versus-C operation is refused. With A paired to B and B paired to C and no A-C shared seed, any attempt to compare against or retrieve C-origin rows on A's behalf is refused (cookbook I-23, refusal three of §1.3).

No durable cross-estate opener is minted. Under the open-source posture, the pairing path produces no retained key that opens another estate's data outside its bound window.

Secret is never keyed. No grant, contribution, or cross-estate fingerprint includes a secret row, and the secret bit cannot be lowered except by expunge.

Provenance survives a relabel attempt. A row whose provenance is relabeled fails verification against its retained originator signature.

The federation conformance suite (cookbook §18.2) is extended with these negative cases. Today it tests handshakes but not the refusals.

## 14. Relationship to the current specification

Already present. Per-estate Ed25519 identity and signed handshake (ConvergenceKit §8). Per-pairing shared hyperplane families (cookbook §3.7, §12.2). Sensitivity and exportability bits, and secret-cannot-be-public (cookbook §2.3, I-22). Provenance bitmap with source-type and channel, and the originating estate-uuid hash in fingerprint Block 3 (cookbook §2.5, §3.5). Non-transitive pairing and the refusal of unseeded cross-estate comparison (cookbook §12.1, §1.3). Contribution-provenance audit and tier differential privacy (cookbook §12.6).

New in this document. Sign-then-encrypt-to-scope as a substrate requirement. At-rest encryption as a requirement rather than a storage-backend option. The no-durable-opener open-source posture and ephemeral session or contact-derived keys. The secret latch and the secret-never-shareable invariant. Grants as the unit of sharing with the content and protection axes. Share lifetime expressed as key lifetime, with decay and the two clawback cases. Re-share with audit as a mediated, composing chain of custody. The tell record framed as accountability. The risk-level chooser. The provisional-drawer lifecycle as the soft-encryption basis for unreviewed writes (Appendix A.2), specified in its own decision record. The write gate and vocabulary freeze (`SubstrateLib.AuditGate` / `VocabularyValidator`): one substrate write path that makes an illegal state unrepresentable (undeclared field, out-of-range value, illegal transition, corrupt vocabulary all refused), the substrate-minimum-plus-frozen-union model, name-keyed content-addressed event identity, and capability-scoped disclosure of the governed grant verbs (Appendix C). Projection is verb-independent, so the handshake negotiates only governed capabilities; the gate is built, the handshake is v1.0, its enforcement rides the sharing implementation.

Changed. At-rest encryption moves from out-of-scope for ConvergenceKit (ConvergenceKit §2) to a substrate requirement. The durable per-pairing shared family (cookbook §3.7) is reframed, under the open-source posture, as a session-bound exchange rather than a retained opener. Both changes are now resolved per section 12 and specified in Appendices A and B.

The reusable parts of this document fold into the federation paper as a federation-security subsection. The encryption-mode and custody-mode mechanics (Appendices A and B) are owned by the storage and federation layers respectively and are built there; this document is the approved reference for the disclosure model they serve.

---

## Appendix A: Encryption modes and what they mean for federated search

This appendix is recorded here, in the federation document, because the choice of how an estate encrypts itself at rest decides what federated disclosure is even possible. The mechanism belongs to storage: PersistenceKit and LocusKit own the at-rest encryption, the key table, and the per-row crypto, and the authoritative build specification lives there. But the consequence is topological. As an estate climbs the encryption ladder, the place where a search can run migrates, and federation has to follow it. So the modes are noted here for their federation meaning, with storage holding the implementation.

The cross-reference is deliberate. Section 3 of this document already names at-rest encryption and the no-durable-opener posture as part of the cryptographic spine, and section 12 records key custody as a resolved decision. This appendix specifies the mechanism behind that resolution and sharpens both by stating the user-chosen encryption modes and tracing each one's effect on the disclosure paths the rest of the document defines.

### A.1. The mechanism storage owns

Encryption is per-record, not whole-file. The estate is one database file. A key registry table maps a key identifier to a wrapped key, and each record's content columns are stored as ciphertext under a key identifier. A record may be encrypted under one key or several. A machine can read exactly the records whose key identifiers it holds; a record under an absent key is unreadable, not missing.

This is a deliberate choice against whole-file encryption such as SQLCipher. Whole-file encryption uses one key for the entire database and cannot express per-record keys, and it imposes a heavy federation penalty: to share even a few rows, the source must decrypt the whole file, encode for transport, and the target must decode and re-encrypt into its own file. Per-record encryption turns that into work that scales with what is shared, not with database size, and it makes the discrete-key case in section A.2 fall out of the schema rather than requiring a second mechanism.

The data encryption key is generated for the user, not chosen as a passphrase, on the model of a disk encryptor or a crypto wallet: a full-entropy random key, wrapped by device hardware where available (Secure Enclave on Apple, TPM on Windows and Linux, the platform keystore on Android), with a one-time recovery phrase for portability and disaster recovery. The hardware holds the wrapping key and never exports it; the recovery phrase, or a device-linking handshake, is how the data key reaches a second device, which then re-wraps it with its own hardware.

What gets encrypted is enforced by the mode, not chosen column by column by the user, because encryption fights search and a free mix produces leaky states. Encrypting a row's vector embedding breaks semantic recall against it; encrypting its inverted-index terms breaks keyword recall; but leaving those plaintext while encrypting the content is a partial disclosure, since an embedding approximates the content and an index is its vocabulary. The coherent rule is that an encrypted mode encrypts content, vector, and text-index together, so that holding the key unlocks both reading and searching, while the classification and integrity fields, the operational bitmap, the lattice anchor, and the audit structure, stay plaintext because they are not the secret.

### A.2. The four modes and their federation meaning

The modes are a user choice at setup. They are one mechanism with different key-distribution choices, not four systems, and modes one through three are the same build plus a setup decision. Each mode changes where a federated search can execute, which is why they belong in this document.

| Mode | At rest | Sharing cost | Federated search |
|---|---|---|---|
| 1. Plaintext, fence encryption | Plaintext; encrypted only at the share fence | One encrypt on send, one decrypt on receive | Any holder of the data can search it; index-pull federation is possible |
| 2. Row encryption | Ciphertext per row at rest | Every local read is a decrypt; sharing is one decrypt from the row key plus one encrypt to the fence | A holder of the row keys can search; results are computed locally and re-encrypted for transport |
| 3. Full database encryption | The whole estate is encrypted (per-row under a per-install key) | Near zero between installs that share the key, since ciphertext ships as is; per-row when keys differ | The remote cannot be searched without its key; federation becomes query-forwarding, see A.3 |
| 4. Database plus threshold | As mode 3, but the key is split M of N | As mode 3 | The remote cannot open even itself without quorum present; search availability is gated on custody |

The through-line is that as the mode climbs, search migrates from anywhere the data sits toward only the place the key, or the quorum, lives. Mode 1 lets any file holder search. Mode 2 lets any holder of the row keys search. Mode 3 lets only the key holder search, which forces federation into query-forwarding. Mode 4 lets the estate be searched only when quorum convenes.

Provisional data, defined in the provisional-lifecycle work, is soft-encrypted under a system key regardless of the estate's mode, because provisional means not yet trusted. A provisional row can be flushed only on the hardware that ingested it, so an unreviewed write cannot be read or promoted elsewhere. This is hygiene that protects against leakage through the normal read, sync, and index paths before review; it is not hardened custody, which is mode 4 territory.

### A.3. Mode 3 federation: query-forwarding, with an edition boundary

Once an estate is encrypted, a peer cannot pull its index and search it, because the index is opaque without the key. There are three behaviors, and the difference between two of them is an enforceable edition boundary, not a setting.

Query-forwarding is the default and is available in every edition. The query travels to the estate that owns the key; that estate decrypts in memory, runs the search locally, and returns only the chosen result rows, re-encrypted for transport. The key never leaves the owner. This composes with the disclosure model in the body of this document: the owner is the discloser, the provenance filter of section 10 runs at answer assembly, and the inference budget applies to what the owner chooses to return.

Index-handoff is an opt-in, owner-consented behavior available only in the commercial edition. The owner explicitly chooses to decrypt an index, warm up a searchable form, and hand it to the requester for a session. It is the heavy path, a long handshake and a warm-up, and it exists because the owner chose to expose searchable data to a party it trusts for that session.

The FedRAMP edition removes index-handoff entirely. Query-forwarding is the only behavior. In a regulated multi-party estate the key, and the quorum that assembles it, must never produce an exportable searchable form that leaves the owning machine. The capability is absent from the build, not merely disabled, which is the distinction a compliance reviewer wants to see: a regulated edition that cannot export a searchable index, rather than one configured not to.

This makes the edition line a security boundary that fits the rest of the model. The open core ships the encryption modes and query-forwarding, because quarantine-before-trust and search-where-the-key-lives are properties everyone benefits from. The commercial edition adds owner-consented index-handoff and the key-management and recovery tooling around at-rest encryption. The FedRAMP edition adds threshold custody and removes index-handoff, consistent with the standing position that FedRAMP hardening is not shared to the open source.

### A.4. Relationship to the resolved decisions

This appendix supplies the encryption-mode mechanism behind the resolved decisions in section 12 and should be read with them. The no-durable-opener posture of section 3 and the mediated-versus-handed-over key custody question are the same question this appendix answers per mode: mode 3 query-forwarding is the no-durable-opener posture expressed for search, since the requester never receives a key or an openable index. The session-bound-versus-standing federation resolution in section 12 maps onto query-forwarding (session-bound) versus commercial index-handoff (a standing searchable form for the session's duration). The defaults this appendix leaves open are the per-mode availability by edition and tier, the warm-up cost ceiling for index-handoff, and whether the personal tier defaults to mode 1 or mode 2 in jurisdictions where strong at-rest encryption is export or import restricted, which is a legal input, not only a performance one.

The build specification for the encryption mechanism, the key table schema, the per-row crypto, the hardware wrapping, and the recovery phrase, belongs to the storage layer and is authored there. This appendix records only what the modes mean for federation, so that the topological consequence is visible in the document that owns disclosure.

---

## Appendix B: Key custody modes (resolves Open Decision 1 and 2)

This appendix resolves the key-custody open decision (section 12, Open Decision 1) and, as a consequence, the standing-versus-session-bound federation fork (Open Decision 2). It defines four custody modes: how a shared scope key is held and how it dies.

A word on naming first, to prevent a collision. Appendix A defines four encryption modes, which describe how an estate's data sits at rest, plaintext through full-database encryption. This appendix defines four custody modes, which describe how a shared scope key is held by a recipient, mediated through physically decaying. The two are orthogonal axes, consistent with the two-dial model of section 4: encryption mode is a position on how the data is protected at rest, custody mode is a position on the share-lifetime and key-custody controls. An estate encrypted under encryption mode 3 can issue a grant under any custody mode. To keep the two straight, this appendix always writes custody mode N, never a bare Mode N.

A second framing note, on shipping. Custody modes 1 and 2 are production targets for v1.0. Custody modes 3 and 4 are experimental: they may or may not ship in working order in v1.0, and they are a hard gate on v1.5. Their value is recorded now because they answer the open decisions and because a sibling effort is prototyping them, but no v1.0 ship commitment rests on them. Both experimental modes carry an IP clearance gate that must be satisfied at the call site before any deployment enables them. The clean-room statement and the activation-gate language below are load-bearing legal text and are reproduced as authored.

The mode is a property of the grant, not of the estate. A single estate can issue grants under different custody modes to different recipients.

### B.1. Custody mode 1, mediated per-access (production, v1.0)

The scope key never leaves the substrate's custody. Every read by the recipient is a live request to the substrate, which verifies the grant is still valid before deriving the session key. Clawback is cryptographic: the substrate removes the grant entry and the recipient's next access request fails. Offline access to shared content is not possible.

This is the default mode for all new grants. No activation required.

Threat model: holds against a malicious recipient. Key revocation is structural, not dependent on the recipient's cooperation.

Tradeoff: requires a live connection to the originating estate for every read of shared content.

### B.2. Custody mode 2, raw handed-over key (production, v1.0)

The scope key is derived once and handed to the recipient at grant creation. The recipient holds the key independently and can read shared content offline at any time during the grant lifetime. Clawback is a signed request that the recipient's substrate honors if honest; it does not enforce against a non-cooperating recipient.

This mode is appropriate for long-term trusted partners where offline access is a genuine requirement and the risk of a non-cooperating recipient is accepted.

Threat model: holds against honest-but-curious recipients. Does not hold against a recipient who caches the key before receiving a clawback request.

Tradeoff: clawback is best-effort. Once the key is handed over, the originating estate cannot enforce forgetting.

### B.3. Custody mode 3, decay-derived key (experimental, v1.5 gate, IP clearance required)

The scope key is never stored. It is reconstructed on demand from a Lagrange basis polynomial whose xi coordinates are drawn from time-varying data sources. During the grant window the polynomial can be reconstructed by any party who knows the reconstruction parameters. As the xi values drift past the threshold K, because the source data changes over time, the polynomial becomes unrecoverable. No vault, no active revocation. Data drift enforces the key lifetime.

Reference design: Darwish and Zarras, "Digital Forgetting Using Key Decay," ACM SAC 2023. DOI: 10.1145/3555776.3577641. Licensed CC BY 4.0.

Implementation note: the production implementation is developed clean-room from the algorithmic description in the paper. No code from the authors' Python prototype is used or referenced during implementation. The xi source pool for the substrate is drawn from cryptographically random estate-internal data that evolves at a predictable rate, rather than from public internet sources, which provides a controlled and auditable drift rate.

Activation gate: this mode requires an explicit opt-in flag in the grant creation API:

```swift
GrantOptions(keyCustody: .decayDerived(
    threshold: 15,
    totalShares: 50,
    driftRatePerDay: .moderate,
    experimentalIPClearanceConfirmed: true   // caller asserts clearance
))
```

The `experimentalIPClearanceConfirmed` parameter must be set to `true` by the caller. Setting it to `true` constitutes the caller's assertion that they have verified IP clearance for their jurisdiction and use case. The substrate logs this assertion in the grant audit record.

IP status: the technique is described in a CC BY 4.0 paper. No patent claim is stated in the paper. The implementation is clean-room. The activating party bears responsibility for confirming freedom to operate in their jurisdiction before enabling this mode in a production deployment.

Threat model: holds against any party including the originating estate. The key cannot be recovered by anyone after the drift threshold is breached. Does not depend on the originating estate remaining online or trustworthy.

Tradeoff: the grant window is probabilistic, not exact. The drift rate of the xi pool determines the window; miscalibration can cause premature key loss. The substrate provides a confidence interval, not a guaranteed window.

### B.4. Custody mode 4, physical decay key (experimental, v1.5 gate, IP clearance required)

The scope key is derived from the SRAM state of a specific device. SRAM cells written to a known state decay irreversibly during power-off as the supply voltage falls below each cell's data retention voltage. The key material is recovered from the surviving cell states. Once sufficient cells have decayed, the key cannot be reconstructed by anyone, including the originating estate.

This mode is the mechanical enforcement of the In-person preset from section 11. The grant is physically bound to a device and a time window. The window is set by hardware parameters: capacitor size and temperature. A 100 microfarad capacitor at room temperature provides approximately two hours. A 10 millifarad capacitor provides approximately two days.

Reference design: Rahmati, Salajegheh, Holcomb, Sorber, Burleson, and Fu, "TARDIS: Time and Remanence Decay in SRAM to Implement Secure Protocols on Embedded Devices without Clocks," USENIX Security 2012.

Implementation note: the production implementation is developed clean-room from the algorithmic description in the paper. The paper states "portions of this work are patent pending." A 2012 filing would expire approximately 2032; the filing may have been granted, lapsed, or narrowly scoped to the original batteryless RFID context. IP clearance must be confirmed before enabling.

Activation gate: same pattern as custody mode 3, with an additional hardware capability check:

```swift
GrantOptions(keyCustody: .physicalDecay(
    deviceSRAMRegion: sramRegion,
    capacitorProfile: .tenMilliFarad,
    experimentalIPClearanceConfirmed: true
))
```

The substrate will refuse to activate custody mode 4 on devices without an accessible SRAM region of sufficient size and a measurable capacitor profile.

IP status: the TARDIS paper states "patent pending" as of 2012. The implementation is clean-room. The activating party bears responsibility for confirming the patent status and freedom to operate before enabling this mode in a production deployment. A USPTO patent search on "SRAM remanence timekeeping" and the authors' names is the recommended first step.

Threat model: holds against any party with network access. The key cannot be recovered remotely. A sophisticated attacker with physical access to the device and extreme cold (liquid nitrogen, approximately minus 40 degrees C per the TARDIS paper's thermal attack analysis) can slow the decay rate, extending the window. The substrate logs the device's temperature profile during the grant window to detect thermal attacks.

Tradeoff: requires supported hardware. The grant is non-transferable: it is bound to the physical device that holds the SRAM region. Losing the device during the grant window means losing access to the shared content.

### B.5. Mode selection guidance

| Requirement | Recommended custody mode |
|---|---|
| Default, no special requirements | Custody mode 1, mediated |
| Offline access needed, trusted partner | Custody mode 2, handed-over |
| Time-bounded sharing, no device dependency | Custody mode 3, decay-derived (experimental, v1.5) |
| Physical presence required, maximum security | Custody mode 4, physical decay (experimental, v1.5) |
| In-person preset (section 11.1) | Custody mode 4, physical decay (experimental, v1.5) |

### B.6. Standing-versus-session-bound federation (Open Decision 2, resolved)

Custody mode 3 resolves Open Decision 2 without requiring an architectural choice. A shared hyperplane family seed derived via decay-derived key is naturally session-bound: the seed is unrecoverable once the xi values have drifted past threshold. Two estates that want always-on federation use custody mode 2 (durable shared seed, explicitly handed over). Two estates that want session-bound federation use custody mode 3 (seed decays after the session window). The architecture does not need to pick one. The mode choice makes it explicit.

Because custody modes 3 and 4 are a v1.5 gate rather than a v1.0 commitment, Open Decision 2 is resolved in principle at v1.0 (the mode choice is the mechanism) and enforced in mechanism at v1.5 (when the decaying modes are required to work). At v1.0, session-bound federation that needs a hard guarantee falls back to custody mode 1 mediation, which is production-ready.

### B.7. Conformance additions (new negative tests for section 13)

In addition to the existing conformance requirements:

Custody mode 3, decay-derived:
- A grant with `experimentalIPClearanceConfirmed: false` is rejected at creation time with `GrantError.experimentalModeNotActivated`.
- A grant key reconstruction that fails the threshold check (insufficient valid xi shares) returns `GrantError.keyDecayed` rather than attempting partial recovery.
- The audit record for a custody mode 3 grant includes the `experimentalIPClearanceConfirmed` assertion and the creation timestamp.

Custody mode 4, physical decay:
- A grant with `experimentalIPClearanceConfirmed: false` is rejected at creation time.
- A custody mode 4 grant issued on a device without a qualifying SRAM region is rejected at creation time with `GrantError.hardwareNotSupported`.
- Temperature logging is present in the grant audit record for the full window duration.

Because these two modes are a v1.5 gate, these conformance tests are required to pass before v1.5 ships, not before v1.0. At v1.0 they may be present as skipped or expected-failure tests.

### B.8. Clean-room statement

Custody modes 3 and 4 are implemented independently from any reference code produced by the cited authors. The implementation derives from the algorithmic description in the published papers only. The activating party's assertion of IP clearance is recorded in the grant audit log and is their legal responsibility, not the substrate's or MOOTx01's.

---

## Appendix C: The write gate, the minimum, and what the handshake exchanges

This appendix states what the implemented substrate does. Vocabulary is not a verb-negotiation problem: peers with different verb vocabularies do not project divergent state, because projection is verb-independent (C.1). The write gate (`SubstrateLib.AuditGate`) and the vocabulary validator (`SubstrateLib.VocabularyValidator`) are built and conformance-gated on both ports; the handshake that consumes them is a v1.0 pairing concern, and the sharing enforcement that rides it follows per the rest of this document.

### C.1. Projection is verb-independent; the minimum is the value encoding

The substrate projects a row's state by folding audit events in HLC order, last-writer-wins over the whole bitmap snapshot each event carries (`AuditLogFold`). The fold never reads the event's verb. Two peers given the same event set therefore project identical state regardless of whether they share a verb vocabulary, because the verb is attribution, not a projection driver. An unshared verb does not cause divergent projection.

What must be universal across federation peers is not the verb set but the bitmap value encoding: the state nibble and its values (active 0 through tombstoned 33, tombstone-sticky), sensitivity (normal/elevated/restricted/secret), exportability (private/public), and I-22. These are what the fold and the access path read, so a peer that disagreed on them would fold or gate wrong. They are baked into the substrate identically everywhere (`RowState`, the adjective bits per cookbook §2.3), so they are universal by construction. This is the federation minimum, and it is already the substrate, not something a handshake negotiates.

### C.2. The write gate makes corruption unrepresentable

Every mutation goes through one substrate function, `AuditGate.admit`. A consumer supplies the row identity and only the field values it owns; the gate read-modify-writes them into the prior snapshot, preserving every bit the consumer did not address, so a consumer cannot clobber a field it does not own. The gate then enforces, in order: that each written field is a declared slot in `basis ∪ union`; that its value is in-range for the field width (an over-wide value is rejected, never truncated) and, where the slot enumerates legal values, one of them; and that the merged result is a legal transition with a legal field combination (`RowStateAutomaton`, I-22). A write that fails any check is refused and the caller aborts. The interface cannot produce an illegal state — out-of-range value, undeclared field, illegal transition. It does not prevent a wrong-but-legal value; that is a correct recording of a mistaken intent, which the audit log makes recoverable. The guarantee is structural integrity, not intent.

The vocabulary is two parts. The basis is the substrate-owned slots (state, sensitivity, exportability, trust, flags) — the minimum of C.1, universal. The union is the slots wired consumers contribute, assembled and frozen once at instantiation by `VocabularyValidator.freeze`, which rejects overlapping slots, basis collisions, and malformed widths before any data exists — so a database can never run on a corrupt vocabulary. The frozen union lives in the database header; the open sequence reads it, freezes it, arms the gate, and only then admits writes. The gate takes the assembled vocabulary as a parameter and reads no storage itself, so it stays pure.

### C.3. Event identity is content-addressed by name

The gate assigns each event a deterministic identity: SHA-256 over the wire fields including the verb name, folded to the event's id. Identical logical events compute the same id on both ports and across configurations, so the G-Set deduplicates and "receiving the same event twice is a no-op" actually holds. Hashing the verb by name, not by an enumeration ordinal, is what keeps identity stable when an event minted in one configuration lands in another — a LocusKit-only estate and a full stack agree on the id of the same event. This is the only sense in which the verb vocabulary touches federation convergence, and it is satisfied by the carrier storing the verb as a name (`AuditEvent.verb` is a string) and the gate hashing it as one. Both ports are gated against a shared content-ID vector.

### C.4. What the handshake actually exchanges

Because state convergence is verb-independent (C.1) and identity is name-keyed (C.3), the pairing handshake does not need to negotiate the semantic verb vocabulary at all. It exchanges two things. First, a compatibility check on the minimum: two estates that do not share the substrate value encoding are not the same kind of database and do not pair — but since the minimum is baked in, this is a version check, not a per-pair negotiation. Second, and the only real negotiation, the governed capabilities: the grant lifecycle (grant issued/revoked, key decay) is security-governing, and a peer must advertise and attest that it enforces those semantics before grant-controlled data is shared to it. A peer that does not present the grant capability never receives a grant-governed row, for the same structural reason a secret row is never keyed (section 5). The attestation is the load-bearing part — advertising a governed verb is committing to enforce it, not merely to store the name.

### C.5. Open sub-decision: static versus renegotiable capability set

One fork is left open, narrowed to the governed capabilities (C.4) since nothing else is negotiated. The capability set a handshake agrees may be static — fixed at pairing time and frozen for the relationship — or renegotiable when a peer gains a capability (a LocusKit-only estate later upgraded to a grant-capable stack). Static is simpler and safer. This attaches to the v1.0 handshake implementation and leans static unless a concrete upgrade-in-place requirement forces otherwise.

### C.6. The same structure governs nouns and adjective values

The minimum-plus-frozen-union structure is not unique to fields. `AuditLogFold` keys on noun type, so the substrate knows the generic row and consumers contribute their noun types, frozen per instance. Adjective values follow the same line: the four categories (state, trust, sensitivity, exportability) and the security value sets (sensitivity, exportability) are in the minimum and universal because they gate exposure; the non-security value vocabularies are consumer contributions declared as gate slots and frozen at instantiation. One mechanism — the substrate minimum plus a per-instance union enforced at the write gate and frozen at the header — covers fields, nouns, and adjective values together.

### C.7. Conformance

The write gate and validator are gated by the `AuditGate` test suites on both ports (no-clobber RMW; undeclared-field, illegal-value, and over-width rejection; illegal-transition rejection; freeze rejection of overlap, basis collision, malformed width, and out-of-width values) plus a shared content-ID vector asserted identically on Swift and Rust. The federation handshake adds, when built: a minimum/version compatibility check at pairing; capability-scoped disclosure (grant-governed data is not shared to a peer that did not attest the grant capability); and content-ID stability across configurations. These join the federation conformance suite (cookbook §18.2).
