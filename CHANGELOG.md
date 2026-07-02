# Changelog

All notable code changes to MOOTx01 are recorded here. Versions follow
`VERSIONING.md`: semantic `MAJOR.MINOR.PATCH`, pre-release builds tagged with a
qualifier (`v1.0.1-beta`). The version constant tracks the semantic version;
the tag carries the pre-release qualifier.

## v1.0.7-beta — 2026-07-02

Eighth beta of the 1.0 line. Bulk-import throughput and a release-signing
security fix.

- **Bulk-import pipeline** — discrete import path with its own drain stream
  that trains and embeds once at the tail rather than per item; the streamed
  per-item path is retired so bulk is the sole route.
- **Persistence throughput** — sharded parallel postings writes with a keyed
  sorted shard merge (EXT-4), and prepared-statement reuse in both SQLite
  backends.
- **Security (927f38c4)** — the release pipeline now fails closed rather than
  publishing an unsigned macOS `.pkg` (a root-authorized installer) or unsigned
  checksums: `build-pkg.sh` gained a `REQUIRE_SIGNING` gate that CI sets on tag
  pushes, and the minisign step aborts a release when the signing key is
  absent. Local/test builds keep their clearly-labeled unsigned path. Windows
  Authenticode signing remains a documented accepted risk pending a
  code-signing certificate.

## v1.0.6-beta — 2026-07-02

Seventh beta of the 1.0 line. Installer correctness across platforms, the
contribution/CLA surface, the three-branch release model, and a batch of
substrate temporal-correctness and performance fixes.

- **Windows installers** — the Inno setup EXE now installs to the
  `%USERPROFILE%\.mootx01\bin` contract path (was Roaming AppData, which left
  `mootx01 upgrade` writing where PATH did not point); `install.ps1` gained a
  UTF-8 BOM so Windows PowerShell 5.1 parses it instead of failing on an
  em-dash byte. Both found by the installer validation harness on real arm64
  hardware.
- **Release security (734e9908)** — the `workflow_dispatch` debug picker can no
  longer reach the macOS Developer ID signing pipeline; signing, notarization,
  and upload are gated to tag pushes, so a branch named like a version cannot
  produce signed artifacts.
- **Contribution** — pull requests are open, gated on a Contributor License
  Agreement (`CLA.md`) enforced by a CLA Assistant workflow; `make pkg` builds
  the macOS `.pkg` locally.
- **Release model** — permanent `develop → candidate → stable` branch triad
  documented in `VERSIONING.md`; installers validated on `candidate` before
  promotion.
- **Substrate correctness / performance** — instants migrated to epoch
  milliseconds (ADR-023); temporal matrix folds keyed on event time with
  full-precision HLC; shared IDF-reduced vocabulary for LSA/NMF (ADR-022);
  FDC term interning and SVD/NMF hot-loop tightening.

## v1.0.5-beta — 2026-06-29

Sixth beta of the 1.0 line. A security-remediation campaign across the Swift
and Rust verticals (Postgres TLS no-downgrade floor, vault job-slot and
concurrency-cap hardening, tar member-validation deadlock fix, recall sort-key
determinism, sync error-status sanitization, release-workflow secret handling),
plus the CE installer build path and the `irm | iex` installer-header fix
(CAND-005). minisign release signing is wired fail-closed.

### CI — installer build path (ce-installer-ci)

- **macOS `.pkg` installers now produced by `release.yml`** — both arm64
  and x86_64 macOS build jobs now build the `Mootx01Setup` SwiftUI setup
  assistant (`apps/Mootx01-Setup`), sign it, then assemble a `.pkg` via
  `distribution/macos/build-pkg.sh`. The `.pkg` is signed with
  `productsign` when `APPLE_INSTALLER_IDENTITY` is set; otherwise emits
  unsigned (RC1-friendly). Artifacts: `macos-arm64-pkg` /
  `macos-x86_64-pkg`, published as release assets and covered by
  `checksums.txt` + minisig.

- **Windows Inno Setup installers now produced by `release.yml`** — both
  Windows build jobs (x86_64 and arm64) now install Inno Setup via
  Chocolatey and compile `distribution/windows/mootx01-setup.iss` to
  produce `mootx01-<version>-windows-<arch>-setup.exe`. Artifacts:
  `windows-x86_64-setup` / `windows-arm64-setup`, published as release
  assets and covered by `checksums.txt` + minisig.

### apps/installer — CAND-005 (CE edition-surface port)

- **PowerShell installer no longer advertises `irm | iex`** — `install.ps1`'s
  header documented `irm <url> | iex` / `iex "& { $(irm <url>) }"` one-liners,
  which execute remote code before it can be reviewed or integrity-checked.
  Replaced with a download-(review)-then-run instruction and an explicit warning
  not to pipe remote code into the interpreter (the legitimate `Invoke-RestMethod`
  tag lookup is unchanged). Ports the EE secfix to CE's edition-surface installer;
  CE's `install.sh` was already fail-closed (minisign port).

## v1.0.4-beta — 2026-06-19

Fifth beta of the 1.0 line. A large drive-test hardening campaign across the ARIA
MCP surface plus a full timestamp-unit sweep. Both ports move together.

### ARIA MCP surface — drive-test repairs

- **Data fidelity** — `file_memory` now persists `kind` and `sensitivity`
  (Rust port had dropped them), and records the correct capture channel
  (`actuator`, not `importedFile`).
- **Validation** — `link_memories` validates tunnel `kind` + rejects self-loops;
  `lens_complexity` rejects unknown fields; `lens_overlap`/`lens_divergence`
  reject self-comparison; `synthesize` filters stopwords.
- **Recall** — `recall_precise` gains an exact-token containment gate and an
  honest discrimination signal (computed on the composition re-rank, not the
  coarse score); the dense-lane status no longer falsely reads `active` when the
  lane was never attempted; `anti_redundant` actually suppresses near-duplicates.
- **Lenses** — the lexical-outlier lens renamed `lens_cohesion`; a genuine
  `lens_contradiction` (contradicts-tunnels + conflicting KG facts) added;
  temporal `drift`/`precedence` honor `event_time`; `drift` KL divergence is
  non-negative (Laplace smoothing); KG facts carry evaluation fields.
- **Vault** — OKF v0.1 superset export/import (Obsidian-compatible); idempotent
  re-import (no `BasisViolation` leak); `confirm_migration` encodes promoted
  memories so they are immediately searchable.

### Timestamp-unit sweep (Rust)

- Closed a class of epoch seconds-vs-milliseconds bugs: vault export `1970`,
  vault import year-9999 clamp, the HLC feed (8 sites), Corpus ingest (both
  paths), and the all-estates topology snapshot now picks the true newest.
- Rust grant store converted off Apple reference date to Unix epoch.

### Install

- Integration-depth installer (`--mode` + guided depth; Server/Skills/Plugin
  with plugin→skills fallback) and the embedded install bundle.
- Claude Desktop proxy bridge emits bare `proxy` (self-resolves the daemon port).

## v1.0.3-beta — 2026-06-18

Fourth beta of the 1.0 line. A drive-test hardening pass over the ARIA MCP
surface — quick fixes, correctness repairs, and recall guidance — plus the
vault security posture decision and the moot-mgr console connection fix. Both
ports move together.

### ARIA MCP surface — drive-test fixes

- **`file_fact` source_id always grounded** — when the caller omits `source_id`,
  the server infers it as the ingest channel (`aria-mcp-server`) so a fact is
  never stored unanchored and never rejected. Both ports.
- **Recall discrimination/confidence signal** — `memory_search`,
  `recall_shaped`, `recall_precise`, and `lens_partial_cue` now surface a
  discrimination/confidence signal and recall-mode guidance. No ranking change;
  both ports.
- **Quick fixes** — `update_memory` schema drift (Rust) corrected; empty
  `free_association` now returns an explanatory hint instead of a bare result.

### Timestamp-corruption resilience

- **Scan skips corrupt timestamps** — the Rust SQLite cursor skips rows with
  unparseable timestamps rather than aborting the scan; the Swift write boundary
  clamps out-of-range values at capture.
- **Vault fail-loud + import validation** — vault export fails loud on a bad
  timestamp rather than emitting `1970`; import validates timestamps before
  filing.

### Vault security posture

- **ADR-015 — vault security posture** — vault is open in 1.0.x-beta (trust at
  rest via encryption) with a gated vault-password feature deferred to 1.1.
- **`mootx01 install --vault-on/--vault-off`** — coarse install switch (default
  on); `--vault-off` hides and refuses the five vault MCP tools. Mandatory
  post-install next-steps disclosure explains the trade-off (vault-on enables
  import/export; vault-off disables them for a tighter posture).

### moot-mgr console

- **Daemon-port resolution** — the moot-mgr console reads the daemon's real bound
  port from `<data>/daemon.port` instead of hardcoding 4242, so it connects to a
  daemon that hunted upward off 4242 under `--http auto`.

## v1.0.2-beta — 2026-06-18

Third beta of the 1.0 line. The headline is the **planned at-rest encryption
lockdown** — estate data and structure are protected at rest, both ports moving
together.

### Encryption — planned at-rest lockdown

- **Mode 3 (FullDatabase) whole-file encryption** — SQLCipher on every platform
  (`PRAGMA key`): OpenSSL FIPS on the Rust port, CommonCrypto (Apple CoreCrypto,
  FIPS-validated) on Apple, vendored from the SQLCipher Community amalgamation.
  An external process opening an estate with a plain SQLite library cannot read
  or alter the schema. Proven end-to-end on both ports.
- **Per-estate keys, both ports** — Rust keeps a `db.key` inside each estate's
  directory; Apple keys a Keychain item by the estate file path
  (`KeychainKeyStore`, Secure-Enclave-wrapped). Distinct estates get distinct
  keys; the key is disposed on estate-remove, so it never outlives its data.
- **Mode 2 (RowEncryption) per-row content AEAD** — AES-GCM-256 content seam
  wired on SQLite and PostgreSQL, on both ports, sharing one byte-compatible
  implementation in PersistenceKit core.
- **RAM protection** — the Rust resident daemon `mlock`s its memory out of swap;
  the Apple port relies on macOS's encrypted virtual memory.
- **Federation signature** — ADR-013 selects ECDSA P-256 (FIPS-validated module
  boundary). ADR-014 records the Apple SQLCipher at-rest decision and the
  approved port divergences.

## v1.0.1-beta — 2026-06-17

Second beta of the 1.0 line. 60 changes since `v1.0.0-beta` (37 features, 7
fixes, 1 performance, 1 refactor, 4 test-hardenings, 4 spec/doc updates, 6
README/ABOUT touch-ups). The headline is the fusion-based semantic recall
stack and the substrate/kit hardening sweep; both the Swift and Rust ports
move together, conformance-gated.

### Recall — classical-fusion semantic recall

- **Decision recorded** — ADR-010: classical-fusion semantic recall +
  ARIA recall steering (Decision D); addendum for Decision B (full fusion incl.
  LSA/SVD) and CoreML-encoder flip-the-switch readiness for 1.1.
- **Substrate primitive** — float-vector ops (l2Norm / l2Normalize / dot /
  cosine), Swift+Rust conformance-gated.
- **Distributional embedding providers** (ADR-010 signals, Swift+Rust):
  Random Indexing, PPMI (+ consolidated keyword tokenizer), LSA, NMF-retrieval
  (+ shared term-document builder).
- **Deterministic one-sided Jacobi SVD**, Swift+Rust bit-identical (backs LSA).
- **FDC lane** — `FDC.ancestors(of:)` / `Fdc::ancestors` runtime façade;
  FDCProvider wired to `LatticeLib.FDC.ancestors`; FDC enum wiring + conformance
  fixtures completed.
- **Basis lifecycle** — versioned cross-port basis serialization (RI/PPMI/LSA/
  NMF); `TrainableEmbeddingBasis` seam; basis-persistence table + corpus
  training lifecycle.
- **Corpus N-provider** capability + per-signal nearest-neighbour.
- **Fusion engine** — dense-lane per-signal fan-out + N-way RRF consensus;
  `RecallShape` signed-weight fusion engine wired into the unionBest lane.
- **Steering** — named `RecallShape` preset roster + `ShapedRecall` recipe +
  ARIA exposure; the five matrix/graph/preference columns made RecallShape-
  steerable; anti-similarity (farthest-K) across VectorKit + CorpusKit + GLK.
- **Production default flipped** to the five-signal ensemble.
- **Capture/import → encode pipeline** wired across all paths + reindex
  backfill.
- **GLK parity** — GraphCache/PreferenceStore recall surface ported to Rust GLK
  (closes ADR-011 D-4); matrix/graph/preference recall lanes wired into
  RecallDirector.
- **CognitionKit** — `recall_exploratory` recipe consuming
  `RandomWalks.walkWithRestart`.

### Brain layer

- Graph-centrality producer (both ports).
- Bradley-Terry preference producer (both ports).
- Rust autonomic governor owns + ticks the standing-signal scheduler.

### Knowledge / taxonomy

- `DrawerFingerprint.qidClosureHash` wired via a pinned Wikidata Q-ID
  taxonomic-closure artifact (both ports).
- HMM novel-token tagger trained on MASC 3.0.0 (CC BY 3.0 US), rare-word
  (hapax) estimated and frozen as a checked-in resource read bit-identically by
  both ports (A-15).

### Substrate & kit hardening (the audit sweep)

- §11.5 — compile-enforced container-fingerprint **add-coverage** so recall
  pruning can never silently go unsound.
- `AssociationRuleMining` mines k>2 itemsets via Apriori row-replay (SubstrateML).
- `SqliteDrawerStore` gains a cache-accepting constructor; moot-mgr wires it.
- Audit `reason` field persisted through the full audit stack (A-8).
- KGFact exposes all four adjective axes, Rust parity (A-6).
- `CaptureFrame` exposes confirmation + confidence provenance to production
  callers (A-13); propose verb wires its three provenance bitmap axes (A-3).
- `#4` — compile-enforce required trait reads; `#7` Q-ID closure rescoped.
- Schema `ext` forward-compat slot extended to the 5 remaining entity tables
  (ADR-012).
- `ext`/forward-compat groundwork; LocusKit interface bumped to 1.6.0.

### Performance

- `tombstoned_rows_without_expunge_audit` uses a SQL LEFT JOIN in the SQL
  backends instead of an N+1 scan (A-7).

### Refactor

- FdcProvider seeds from the substrate `FNV.hash64` primitive rather than an
  inlined FNV-1a loop (one dense-math library to maintain).

### App / moot-mgr

- Persist a custom retention window to StatsStore across restart (A-10).
- `lastLoggedID` parses the intentRunLog for the created drawer UUID instead of
  always returning nil (A-4).

### Fixes

- Correct the stale `lookup_vectors` `religion_single_token` expected code (a
  common noun must resolve).
- Land FDC enum wiring + conformance fixtures omitted from an earlier commit.
- Parity-sweep: batch parity-clean items + harden two test-isolation flakes.
- Fix `vault_reconcile` temp-dir collision flake (UUID, not nanos).
- Close the VectorKit Rust SQLite cross-restart conformance gap + fix a stale
  `lib.rs` comment (A-11).
- Fix a stale Rust test comment claiming `CaptureFrame` has no confirmation slot.

### Tests & docs

- Test-isolation hardening: moot-mgr retention sidecar per-test directory;
  BasisPersistence tests serialized under `GlobalTestLock`.
- Doc fidelity: correct the stale `shingleSimilarity` rewire comment (A-5);
  spec/interface version bumps; README/ABOUT touch-ups.

## v1.0.0-beta

Initial public beta of the 1.0 line.
