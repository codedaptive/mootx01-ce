# MOOTx01 System Engineering Reference

This document is the stable home for cross-cutting rules that span multiple
kits, applications, transports, and editions. Algorithm-level rules live in the
GeniusLocus cookbook; FDC and conformance details live in their specialized
engineering masters. Current reference specifications remain the detailed API
contracts.

## 1. Current-truth discipline

- Source, tests, and accepted current specifications define shipped behavior.
- An unimplemented proposal is not a contract. It is listed under **Current
  non-contracts** only when engineers need to know that the surface does not
  exist.
- Swift and Rust are co-authored implementations of one contract. Shared types,
  wire values, persistence shapes, algorithms, and fixtures change together.
- Platform adapters may differ below a common seam. Parity means equivalent
  contract and provenance behavior, not identical operating-system APIs.
- Historical rationale does not appear in source citations. Code states what it
  does and why the invariant matters in present terms.

## 2. Package, application, and edition architecture

### 2.1 Dependency direction and kit ownership

The system composes bottom-up. A downstream kit may declare an in-repository
dependency on an upstream kit in `Package.swift` and `Cargo.toml`; the two ports
move together. Dependencies may not invert the layer graph. Third-party package
dependencies require explicit per-package approval and a documented supply-chain
and portability justification. Cosmetic manifest edits are not mixed with
dependency changes.

The principal ownership boundaries are:

- `SubstrateTypes` owns pure cross-port data types, including HLC types.
- `SubstrateKernel` owns bandwidth-bound bit, hash, and exact numeric atomics.
- `SubstrateML` owns learning, graph, distributional, and cold-path algorithms.
- `SubstrateLib` is the public substrate composition product; it does not become
  a second implementation of its sibling packages.
- `PersistenceKit` owns schema declaration, migration, transactions, storage
  backends, and storage observation.
- `ConvergenceKit` owns replication policy and transport over PersistenceKit
  operations; consumers do not bypass PersistenceKit to sync.
- `EngramLib`, `LocusKit`, `VectorKit`, and `CorpusKit` own representation,
  estate/domain state, vector engines, and corpus/encoder integration
  respectively.
- `NeuronKit` owns brain algorithms, signals, daemon policies, and update work.
- `CognitionKit` owns intent-level recall and cognition recipes.
- `GeniusLocusKit` composes the estate and brain layers and owns orchestration.
- MCP and application targets are access and presentation surfaces. They do not
  absorb domain or substrate ownership.

The FDC encoder follows the same rule: LatticeLib owns lattice data and lookup,
CorpusKit owns encoding and model/provider integration, Substrate packages own
the reusable math, and the standalone seed generator is a maintainer tool rather
than a runtime dependency. See `FDC_ENCODER_COOKBOOK.md`.

### 2.2 Apple application envelope and host ownership

The Apple app is an envelope around the cross-platform engine. Engine packages
contain no Apple presentation types; application targets may use Apple UI and
service APIs through explicit adapters.

One estate has one owning process at a time. Other applications reach that
owner through a transport rather than opening the same database concurrently.
On macOS, an ownership handoff checkpoints and closes the old host before the
new host opens the estate, and completion requires a positive acknowledgement.
The supported hosting shapes are:

- embedded engine inside the app;
- managed subprocess over stdio;
- resident service over loopback HTTP.

`moot-mgr` is an observer and administrative plane, not an MCP dispatcher. Its
declared in-repository dependencies may expose read models from LatticeLib,
AriaLexiconLib, and CognitionKit without moving their ownership into the app.

### 2.3 Loopback HTTP boundary

Swift loopback HTTP behavior shared by resident processes lives in the
`LoopbackHTTP` library. The library supplies bounded HTTP/1.1 request handling,
responses, and server-sent-event support. Authentication, origin policy, OAuth,
and product routing belong to each consumer's composition layer. Request limits
are configurable at the consumer boundary.

Rust owns its native loopback implementation rather than importing Swift-only
OS glue. The cross-port contract is the JSON-RPC/HTTP wire behavior, limits, and
failure semantics.

### 2.4 CE and EE edition boundary

EE is the private superset and the publication source for shared features. Every
path is classified as one of:

- **SHARED** — byte-identical in CE and EE;
- **EDITION-SURFACE** — independently owned public/private packaging or product
  surface;
- **EE-ONLY** — private material that is never published.

Features flow EE to CE through SHARED paths. Fixes made on a supported CE branch
are backported to EE before the next shared publication. Trust, individual
import/export, and the ability to leave the product are never paywalled; EE may
add organization, remote administration, federation, and policy surfaces above
the shared mechanism.

Release work follows `RELEASE_RUNBOOK.md` and the repository edition-boundary
manifest. Stable documentation never assumes that a private path exists in CE.

### 2.5 Approved Swift dependency baseline

The workspace baseline is swift-crypto 4.x and swift-nio 2.100.0 for the 1.0
line. Direct swift-crypto constraints use a 4.x floor, not 3.x. These are
approved infrastructure dependencies; adding a different external dependency
still requires its own review.

## 3. Persistent model and identity

### 3.1 UUID identity and lineage

Every synced or audited row has a UUID primary identity in both ports and on the
wire. Row identity is not a backend-native integer and is never synthesized from
an ingest order. `lineageID` is a separate stable UUID naming a supersession
chain. A row version's `id` may change during supersession; lineage identity does
not.

The audit log is self-sufficient. Capture emits the genesis event through the
same validation gate as every mutation, with no prior state and the captured
state as the post-image. A projection at a time before genesis returns no row.
The live row is a materialized projection of the event fold, not the seed from
which history is reconstructed.

### 3.2 Time model

`eventTime` is the authored-in-world origin time. `filedAt` is the local ingest
time. The model does not add a parallel `occurredAt` primitive. An incoming
capture may omit origin time; the ingest boundary then supplies `filedAt` as the
backfill so persisted drawers always have an origin time.

All substrate instants are signed 64-bit Unix epoch **milliseconds**. Persistent
timestamps use UTC ISO-8601 with exactly millisecond precision:
`YYYY-MM-DDTHH:MM:SS.sssZ`. Continuous calculations convert milliseconds to
seconds with floating-point division by 1000; whole-second bucket and calendar
logic uses Euclidean integer division. Durations and cadence constants remain in
seconds unless their type says otherwise.

An event also carries one HLC, minted by the highest-ranking active host and
held unchanged by lower layers. HLC is the fold and convergence order; origin
time is not. The event seal binds its HLC, content, and identity. Strict custody
seals at write time; lazy custody may defer seal computation to maintenance
while recording that recalculation is required. Persistence declares and
enforces storage, but does not author clocks or seals.

Federation carries the origin event verbatim and wraps it in the receiving
estate's evidence rather than rewriting its clock. An already-owned log refuses
a second clock maker; an explicit takeover records the ownership handoff.

### 3.3 Manifest

The estate manifest is a dedicated key/value table in the same database as the
estate. It has a semantic `manifest_version`, well-known scalar keys, and only
the bounded structured values defined by the current LocusKit contract. Missing
keys use documented defaults; malformed required values fail closed rather than
silently becoming a new estate.

Consumer-owned state uses namespaced manifest keys through the estate surface.
A daemon or kit does not bypass LocusKit to write the manifest directly.
`Estate.meta`/`setMeta` (and the Rust equivalents) are the durable string-value
surface. The substrate owns storage while the consumer owns typed
serialization. NeuronKit persists dreaming and maintenance policy, bandit, last
run, idempotency, cycle, vocabulary, consolidation, and fingerprint-baseline
state under `neuronkit.*` namespaces. Values that require byte-stable comparison
use canonical ordering and serialization.

### 3.4 Forward-compatibility slot

Every persistent entity table has exactly one nullable `ext` column holding a
JSON object. In the 1.0 contract it is null/inert and reserves a location, not a
schema-free alternate model. SQLite stores it as the PersistenceKit JSON/BLOB
representation and PostgreSQL as JSONB. Any future payload remains subject to
the common storage rules, including UTC ISO timestamps and no stored Boolean
primitive. Regenerable caches and bookkeeping tables do not acquire `ext`.

### 3.5 Lattice, wings, rooms, and nodes

The v1 lattice citation is UDC plus an optional Wikidata QID. UDC is the durable
hierarchical coordinate; the QID is a language-neutral concept anchor. Drawers
and estate manifests carry the current citation fields, and federation reasons
about overlap between declared UDC zoom windows. A `LatticeProvider` keeps the
classification system replaceable without weakening the v1 reference contract.

Wings are the provenance/role axis and rooms are locations within a wing.
Classification belongs to the lattice rather than being encoded in wing names.
Recall spans wings unless a caller deliberately scopes it. Wings are soft
organizational partitions, not security boundaries.

A fresh estate suggests seven editable wings: **Agentic Memory** (default),
**User Canon**, **Source Corpus**, **Personal**, **Professional**, **Projects**,
and **Temp**. These names are seeded guidance, not an enforced schema. Each
seeded wing contains an ordinary, recallable, user-deletable hint memory in
`AI_Charter_Hint`; code gives that memory no sentinel identity or special
exclusion. Filing may infer Agentic Memory for agent observations and Source
Corpus for imports, while an explicit wing always remains available. A caller's
path maps to rooms and is never split to invent a wing.

The substrate hierarchy is fixed-depth containment:

```text
estate -> wing -> room -> drawer
```

Containers and drawers are independently identified nodes; a drawer's
`parent_node_id` points to its room. Names preserve display spelling but use a
normalized lookup key. Create-on-demand resolution is idempotent. Tombstoned
nodes do not resurrect implicitly. `lineageID` remains the drawer-version chain
and is not reused as containment. The FDC classification tree is a separate
taxonomy and never becomes the estate's physical node tree.

Snapshots are copy-on-write views of the node skeleton with payloads referenced
by identity. Per-wing commitments compose into an estate commitment. Expunge
removes recoverable content and vectors, invalidates affected commitments, and
re-roots future attestations while preserving the audit fact that expunge
occurred. Detailed fold, commitment, and state-machine rules live in the
GeniusLocus cookbook.

### 3.6 Shared content across composed kits

Standalone kits may own the content required to make their product complete in
their own domain. Standalone LocusKit stores Drawer content. Standalone
CorpusKit stores corpus documents and may derive passage-level retrieval units.
Those standalone storage capabilities do not imply duplicate content in a
GeniusLocusKit composition.

Within GeniusLocusKit, LocusKit's Drawer is the single canonical content
object. GeniusLocusKit owns the composition and supplies CorpusKit with an
adapter implementing CorpusKit's content-source contract. CorpusKit does not
import LocusKit and does not own a second verbatim-content table in that mode.
It stores only derived retrieval state and keys that state to the canonical
Drawer UUID. Every CorpusKit result returned to GeniusLocusKit identifies that
same Drawer UUID, so lane fusion and deduplication operate on one object
identity rather than translating between storage identities.

CorpusKit passage segmentation is an optional standalone indexing policy. It
is dark in GeniusLocusKit and therefore dark in MOOTx01. If standalone
CorpusKit enables passage indexing, passage rows contain only revision-bound
ranges into the canonical standalone document; they do not contain a second
copy of passage text, and passage identity never replaces document identity in
public results. Passage sizing is based on the selected provider's token budget,
not a global character-count threshold.

The two operating modes use the same CorpusKit indexing, provider, ranking,
invalidation, and retrieval engine behind interchangeable content-source
adapters. CorpusKit publishes one black-box conformance suite that runs against
its standalone content store and the GeniusLocusKit/LocusKit adapter. A working
GeniusLocusKit composition therefore exercises the same CorpusKit core as the
standalone product; the standalone suite additionally covers its local content
store, migrations, close/reopen behavior, and optional passage policy.

The 1.1 migration from the 1.0 chunk-backed GeniusLocusKit schema treats all
chunk rows and chunk-keyed retrieval artifacts as regenerable derived state.
Canonical Drawers, their audit history, and unrelated Drawer-keyed vectors are
preserved. CorpusKit recall remains dark while its BM25 state, provider
bases/counts, and CorpusKit vector partitions are rebuilt once per active Drawer
under the Drawer UUID. The migration is ordered and resumable through
PersistenceKit; it must never use an unscoped vector wipe that could delete
non-CorpusKit Drawer vectors.

## 4. Persistence, vectors, and convergence

### 4.1 PersistenceKit contract

PersistenceKit owns a typed schema declaration, a closed predicate tree,
explicit transactions, ordered migrations, storage observation, and backend
conformance. The application chooses a backend at estate construction; domain
kits program to the storage protocol rather than to SQLite, PostgreSQL, or an
in-memory implementation.

The storage layer applies declared constraints and migrations transactionally.
Observers report committed changes, never half-applied transaction state. Audit
events and their materialized projections commit atomically. Backend-specific
connection pools, SQL, encryption handles, and TLS configuration remain behind
the backend boundary.

### 4.2 Vector ownership correction

PersistenceKit guarantees that a backend can store the vector-related data the
current schema requires. It does **not** define or own a per-backend k-nearest-
neighbor engine. VectorKit owns vector indices and search engines. There is no
`Storage.vectorIndex` contract and no sqlite-vec/pgvector shadow implementation
in PersistenceKit.

### 4.3 ConvergenceKit contract

ConvergenceKit observes committed PersistenceKit changes, transports typed row
mutations, and applies incoming mutations through the receiver's PersistenceKit.
Domain kits do not call backend transports directly. A sync record identifies
its table, event kind, UUID row key, typed post-image when present, HLC, schema
version, and kit identity. Schema or kit mismatches are rejected and retained
for an explicit retry path rather than adapted silently.

Sync direction and conflict policy are declared per table. Append-only audit
events converge idempotently by event identity and HLC; projections use the
declared HLC policy. CloudKit is the Apple same-owner device transport,
federation is cross-estate exchange, and the none backend is deterministic
single-device/test behavior. Storage observation remains PersistenceKit's job;
ConvergenceKit provides push, pull, subscription, receipts, and coarse state.

The 1.1 operational-store contract extends this model without changing the
pipeline. Mutable tables may select field-level LWW with per-column HLC
metadata so disjoint concurrent column edits survive. A table may exclude
locally derived columns from replication, and a manifest may install a
post-apply integrity hook that repairs application invariants in the consumer's
transaction scope. ConvergenceKit does not learn those domain invariants.

CloudKit durability is part of that contract: the outbox is persistent and
entries clear only after per-record confirmation; server change tokens survive
restart and reset cleanly when expired; retry policy distinguishes record and
transport failures; deletes carry tombstone HLCs and route by record type;
newer-schema records wait for local migration instead of being dropped; and a
push emits one completion event rather than a synthetic empty completion at
start. Polling is sufficient for correctness, while subscriptions may reduce
latency.

Two HLC integer layouts coexist and must never be mixed. CloudKit record
metadata uses `physical(48b)<<16 | logical(12b)<<4 | node(4b)` so bare integer
ordering is chronological. The compact SubstrateTypes form used by federation
and fingerprints uses `node(8b)<<56 | logical(16b)<<40 | physical(40b)`.

Operational-store sync beyond the shipped manifests is not inferred. A new
table family must explicitly define zone/partition identity, owner identity,
record mapping, conflict policy, deletion semantics, retry behavior, and
backend conformance before it is enabled.

### 4.4 Rust cryptography and PostgreSQL TLS seams

Rust row encryption uses the approved `aes-gcm` crate behind a swappable AEAD
interface. The contract is AES-256-GCM with unique nonces, authenticated
ciphertext, fail-closed verification, and key material kept outside ordinary
row data. FIPS deployments substitute an approved provider at the seam; crate
selection alone is not a claim of FIPS validation.

Rust PostgreSQL TLS uses `postgres-native-tls` behind the backend connection
boundary. `require` fails if TLS cannot be established; `prefer` may fall back
only when policy permits. Custom CA configuration is explicit. Swift and Rust
must match transport policy and error behavior even though their TLS libraries
differ.

### 4.5 Table residency

The shipped 1.0 contract does not expose an application-defined per-table
residency profile. Persistent tables use the selected durable backend; caches
may use their documented in-memory implementations. Any future RAM-mirrored or
RAM-only profile requires an accepted API, both-port implementation, durability
semantics, memory-pressure behavior, and conformance before documentation may
present it as available.

## 5. Recall, embeddings, matrices, and autonomous work

### 5.1 Honest semantic fusion

The semantic lane is an explainable classical ensemble: FDC, LSA, random
indexing, NMF, PPMI, and BM25 contribute through rank fusion/soft consensus.
Consensus is a confidence signal, not a claim that the system used a learned
neural model. Learned encoders are additive providers; they do not replace or
rename the classical lane. Adaptive optimization owns signal weights.

Callers steer recall by goal/recipe and effort (`fast`, `standard`, `deep`), not
by selecting internal math. Result provenance reports the providers and spaces
that actually contributed.

### 5.2 RecallShape

RecallShape's key space covers every scoring column: `locus`, `bm25`,
`hamming`, `dense`, `dense:<modelID>`, `fieldFit`, `coOccurrence`, `temporal`,
`graph`, and `preference`. Weight `1` is neutral, `0` excludes, and a negative
weight suppresses. Missing keys default to `1`. The effective factor is shape
weight multiplied by adaptive weight and the column score.

Matrix, graph, and preference columns participate only in matrix-aware recall;
raw and reciprocal-rank-fusion modes leave them inert. Graph and preference
producers are owned by the AutonomicGovernor. A fresh estate with no producer
cache contributes zero rather than fabricated evidence.

### 5.3 Embedding provider seam

Embedding inference is a selectable signal family behind the CorpusKit
provider protocol. Each provider declares a stable model/provider identity,
dimension, normalization behavior, and embedding-space identity. Stored vectors
carry the space provenance required to prevent comparison across incompatible
spaces. Recall searches compatible spaces independently and fuses results at
the result layer.

Apple `NLEmbedding` and `NLContextualEmbedding` providers are opt-in Swift
adapters below that seam. They use distinct projection seeds/spaces, return an
absent lane when a language or asset is unavailable, and never pretend an
unavailable model produced a vector. Rust need not implement the Apple backend;
it must preserve provider, absence, and provenance semantics.

The stable Apple provider identities are `apple-nlembedding-v1` and
`apple-nlcontextual-v1`, both version `1.0.0`. Their FloatSimHash projection
seeds are `0x4150_4E4C_454D_4231` and `0x4150_4E4C_4354_5831` respectively.
Both providers are item-local, L2-normalize their float vectors, do not conform
to the trainable-basis contract, and do not join the default ensemble.

LSA and NMF train on one stored, shared, IDF-reduced vocabulary, normally in the
1,000–3,000 term range. The vocabulary is frozen with the basis and projection
uses that exact mapping. Bulk import defers automatic retraining/reindexing and
triggers one rebuild after the batch. Rebuild refits the basis and re-embeds the
estate. Random indexing, PPMI, FDC, and BM25 retain their own representations.

### 5.4 Matrix T

The temporal-causality population pass is a standing signal with a 3,600-second
cadence, independent of the slower dreaming work. It reads the audit stream off
the capture hot path and uses `eventTime` for the temporal relationship while
HLC remains the fold order.

The fold has a 256-minute window and retains at most the 512 most-recent
in-window source events for each target. This bounds work to
`O(events * 512)` and deterministically favors the closest events. Wikidata QID
is excluded from T because its high cardinality creates content-pair noise; it
remains a valid coordinate in the co-occurrence matrix O. Incremental and full
rebuilds use the same cap and exclusion.

### 5.5 Brain-layer ownership and dreaming

NeuronKit supplies algorithms, policies, daemon state, and signals. CognitionKit
supplies intent-level recipes. GeniusLocusKit composes the estate and owns the
AutonomicGovernor that schedules standing signals, dreaming, maintenance,
training, matrix work, and preference updates. MCP exposes control and results;
it is not the owner of the loop.

Dreaming candidates arise from actual co-recall, not all pairs that happen to
share a room. Recall enqueues a bounded, idempotent work item in the estate's
queue; both resident and stdio modes drain the same persisted mechanism.
Repeated co-recall increments evidence rather than duplicating an association.
Workers are bounded, stream-scoped, and safe to resume. Bulk import suppresses
per-item drain/reindex churn and performs the bounded follow-up work once.

One estate uses one multi-stream queue (`encode`, `dreaming`, `signals`), and a
drainer claims only its stream. Encrypted-SQLite estates keep queue payloads in
a separate encrypted `queue.sqlite` using the estate encryption configuration;
PostgreSQL estates use a PostgreSQL queue table; ephemeral estates use memory.
MOOTx01 does not select QueueKit's maildir backend because job payloads may hold
private text and identifiers. Per-estate/per-stream leases prevent a drainer
stampede while allowing independent streams to progress.

The consolidation schedule has four roles: ALPHA drains fresh co-recall work at
30-second cadence; THETA consolidates and decays repeated co-recall over the
last day; BETA prunes internal count/consolidation state weekly; OMEGA retires
unreinforced dreamed tunnels biweekly. Retirement is audited and reversible and
never targets imported or user-declared tunnels. Resident mode runs due cycles
from the governor. Stdio mode uses a detached, leased dream process after
recall, on exit, and when an invocation discovers overdue work.

The 1.0 line uses bounded workers within each estate's drain. It does not claim
a process-global CPU cap across multiple estates. A future central dispatcher
must use one process-wide pool, fair-share estate queues, parallel compute with
serialized per-estate writes, and route every heavy background duty through the
same budget before it can claim that cap.

### 5.6 Diffusion boundary

Shipped motion and change-over-time algorithms may expose deterministic
node-layer deltas, anomaly scores, and temporal views where current source and
tests define them. The broader proposed diffusion hierarchy, noise schedule,
position-fingerprint audit extension, and anticipation engine are not a 1.0
contract. No caller may depend on those proposed surfaces until they have
accepted interfaces and cross-port conformance.

## 6. Vault and data movement

### 6.1 Ownership and trust posture

Mass import/export belongs in VaultKit through adapter boundaries and the
language-neutral `NoteIR`. Adapters transform formats; access surfaces own file
or network transport. Imported notes become ordinary drawers in the estate,
not a sealed side estate. Attachments remain referenced by path, digest, MIME
type, and size rather than being copied into row blobs.

Every bulk operation produces an audit receipt. Friction rises with volume and
sensitivity. Normal and elevated data use the normal export tier; restricted
data needs an owner-authorized private path; secret data is excluded from bulk
movement and requires a separate, explicit item-level operation if any current
contract permits it. Trust, individual import/export, and exit remain available
in CE.

The Vault seam is a plaintext boundary: export is exfiltration and import is
injection. Access is therefore visible, attributable, bounded, and provenance-
preserving. At-rest estate encryption does not make a plaintext export safe.

In the 1.0.x beta line, Vault has no per-operation authorization gate. The MCP
surface is on by default and any connected agent can drive it. `mootx01 install
--vault-off` removes the entire Vault tool family; `--vault-on` exposes it. The
installer must disclose that default and trade-off. Shipped mitigations are
correctness controls: export fails loudly on read failure, import clamps invalid
timestamps, corrupt individual rows are skipped and logged, and every operation
is journaled. They are not described as human consent. A future gated Vault must
be initialized out of band, bind its export directory outside agent control,
and gate import as well as export before claiming authorization.

### 6.2 Note identity and import semantics

`NoteIR` uses open string block kinds and serializes equivalently in Swift and
Rust. Imported wikilinks become tunnels with imported provenance. Explicit UDC
wins; otherwise resolved FDC classification wins; the final fallback is `000`.

Import idempotency uses the stable source key to derive lineage identity with
the cross-port FNV-1a-128 rule. Tunnel idempotency uses a stable signature over
endpoints and label. Re-import updates the same lineage instead of duplicating
content.

Vault round-trip identity is the stable `lineageID`, written as `moot_id` in
frontmatter. Human filenames use a sanitized, lower-case slug (maximum 60
characters) under the room. Import resolves identity in this order: `NoteIR`
identity, frontmatter `moot_id`, then the stable-source-key derivation. Renaming
a file with `moot_id` therefore updates rather than duplicates it.

### 6.3 Export scope and drift

Export scope is explicit:

- `believed` is the default current-belief projection across confirmation and
  trust states;
- `exportable` also requires the drawer's exportable intent;
- `confirmed` requires user confirmation;
- `unconfirmed` is the capture-inbox view.

All scopes retain the evaluator's normal-sensitivity ceiling unless a future
authorized contract deliberately changes it.

Exact SHA-256 state lives in `.moot/export-manifest.json`. Reconciliation
reports added, modified, and deleted paths; deletion is reported but never
performed automatically. MCP Vault tools return candidates and receipts. They
do not write Proposal rows or enqueue QueueKit work as a side effect.

## 7. Federation, cryptography, and sensitivity

### 7.1 Identity and signatures

Each estate has a distinct federation identity. Pairing is explicit and
out-of-band; two estates owned by the same person do not implicitly trust each
other. Federation signatures use ECDSA over NIST P-256. Apple uses approved
platform cryptography; Rust/Linux/Windows FIPS deployments use an approved
OpenSSL provider. RFC 6979 deterministic nonces are preferred where the API
exposes them. Approved randomized signing is valid; verification, not signature
byte equality, is the cross-port contract. Nonces are never hand-rolled.

Outbound material is signed by its origin and encrypted to the intended pairing
scope. Origin provenance survives every hop. Pairings are non-transitive: an
estate answering a peer excludes third-party material unless that peer holds an
independent grant from the origin. Filtering happens before aggregation or
encryption. Query/inference budgets remain necessary even on authenticated,
encrypted channels.

### 7.2 Disclosure model

Disclosure has independent content and protection axes. Content ranges from
verbatim rows through facts, fields, aggregates, posture, existence, to nothing.
Protection declares data class, grant scope, lifetime, transport, at-rest mode,
re-share policy, clawback, disclosure audit, inference budget, and key custody.

A grant is an explicit signed object naming grantee, target scope, content
level, lifetime, channel, re-share permission, clawback class, and inference
budget. Default is deny. Child/re-share grants cannot outlive their parent.
Mediated re-share records origin, intermediary, recipient, and authorizing grant
without changing origin provenance. The tell record is append-only
accountability; it does not claim to prevent a recipient from manually copying
plaintext already shown.

Secret is never public or bulk-exportable and no federation scope key is minted
for it. Private/restricted disclosure requires an affirmative, expiring grant.
Revocation can kill mediated ciphertext by destroying the relevant key, but it
cannot erase plaintext a recipient already observed.

### 7.3 Estate encryption

SQLite estate files use SQLCipher on supported platforms. Apple key handling
uses a per-estate 256-bit data key wrapped by Secure Enclave-backed Keychain
material where available; deleting a protected estate deletes its wrapped key.
Apple Data Protection, app-group controls, and FileVault are defense in depth,
not substitutes for database encryption.

Rust protects key files with owner-only permissions and uses the approved crypto
provider required by the deployment. Sensitive key pages use the platform's
available memory-locking facility; implementations fail closed when a required
protection cannot be established. Backend coverage and provider validation are
deployment claims and must be tested as such.

### 7.4 Human sensitivity grants

Restricted and secret reads require independent, RAM-only grants:

- restricted access lasts until the next local midnight;
- secret access lasts 30 minutes.

Restart locks both tiers. Expiry is calculated from the caller-supplied current
time so tests and implementations agree. Apple authorization uses
LocalAuthentication. Rust uses separate restricted and secret credentials
stored with a salted, slow password KDF.

Approval never travels through MCP. There is no MCP unlock tool or prompt token;
the human authorizes through an out-of-band platform surface. Locked recall
returns a static advisory without an exact hidden-row count and may use only an
O(1), limit-one sensitivity probe. Grant, denial, revocation, and each protected
read are audited with tier, grant identity, and timestamps, never content.

The protected boundary is the connected MCP client. This policy does not claim
to defend against a malicious process already running as the same OS user with
direct access to unlocked process or database material.

## 8. Connection ownership and installation

The plugin is the preferred installation moment and owns the client connection.
Plugin manifests connect to resident HTTP at `127.0.0.1:4242`. Clients without
HTTP transport use `mootx01 proxy`; no installed client is configured with bare
`serve`.

Connection deduplication lives once in the installer binary. In active install
mode it may remove only recognized, default-owned duplicates. Plugin hooks are
warning-only and do not edit client configuration. Non-default or foreign
entries are reported and preserved. Duplicate active wiring fails loudly.

The resident daemon reports client/server version skew. Development builds use
visibly different binary and connection names. The 1.0 contract supports one
default daemon/database connection per client; static plugin manifests do not
solve arbitrary port overrides.

## 9. Current non-contracts

The following ideas were recorded during 1.0 design but are not shipped 1.0
contracts:

- application-selected per-table disk/RAM residency profiles;
- the complete diffusion/anticipation architecture and audit extension;
- a process-global central drain master and global cross-estate CPU cap;
- automatic operational-store sync for undeclared table families;
- a universal provisional-drawer review state for ordinary capture;
- any persistence or convergence API that appears only in an unaccepted design
  sketch and is absent from the current reference specification and source.

Engineers may design these later, but must not infer their types, storage
semantics, or availability from historical proposals.
