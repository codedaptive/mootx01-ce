# Changelog

All notable code changes to MOOTx01 are recorded here. Versions follow
`VERSIONING.md`: semantic `MAJOR.MINOR.PATCH`, pre-release builds tagged with a
qualifier (`v1.0.1-beta`). The version constant tracks the semantic version;
the tag carries the pre-release qualifier.

## develop/1.1.x — fast-moving 1.1 beta

This branch is the source beta for 1.1 feature updates. It changes continuously
and is identified by commit rather than a release tag. Stable installers and
the public marketplace plugin continue to track the supported 1.0 line until
1.1 work is promoted through candidate and stable.

Current development themes include the native MOOTx01-App, CorpusKit
shared-content architecture, Apple surfaces and on-demand federation, and the
foundation for continuous Obsidian synchronization. Individual entries and
feature guides distinguish implemented behavior from planned work.

## v1.0.33 — 2026-07-16

Release-engineering release. No user-facing code changes — Windows release
signing and version-integrity hardening.

- **Windows release signing wired for tagged releases.** The two Windows
  sign jobs in `release.yml` now run under the `release` GitHub Environment,
  so a tag-triggered release presents the OIDC subject
  `repo:codedaptive/mootx01-ce:environment:release` that an Azure federated
  credential can match. (Tag refs can't be wildcarded in a federated-credential
  subject; the environment can.) Candidate signing was validated end-to-end
  on both arches ahead of this.
- **Version-integrity gate.** `release.yml` now verifies, before publishing any
  asset, that every in-source version stamp equals the release tag — the number
  `mootx01 --version` prints can no longer disagree with the tag it shipped
  under. A forgotten `bump_version.py` now fails the release loudly instead of
  shipping a mislabeled binary.

## v1.0.32 — 2026-07-14

Protocol-honesty and release-integrity release. No user-facing feature
changes — MCP error surfacing, upgrade trust, and CI supply-chain
hardening.

- **MCP tool failures surface as results, not protocol errors.** aria-mcp
  now returns tool failures as `isError` tool results instead of raw
  `-32010` JSON-RPC protocol errors, so clients see the actual failure
  reason instead of an opaque transport-level code. Both legs.
- **Authenticated upgrades.** `mootx01 upgrade` now authenticates release
  checksums before installing (#18), and the installer rejects a binary
  whose signature doesn't match. A tampered or truncated download can no
  longer install.
- **CI supply-chain hardening.** The release pipeline isolates OIDC-bearing
  jobs from package builds (Windows code-signing and PyPI publish each run
  in their own job, separate from cargo build), validates the release tag
  before any version rewrite, drops write-token exposure from build jobs
  (`persist-credentials:false` + least-privilege perms), and excludes the
  `windows-*-unsigned` handoff artifacts from published release assets.
- **Cross-leg grant integrity.** GLK canonicalizes the grant signature
  payload at the initial-budget boundary and aligns the ConflictCue Swift
  tokenizer to Unicode scalar semantics, so Swift and Rust agree
  byte-for-byte on the signed payload. The InMemory RowStore comparator
  gained the blob/json/fingerprint/array cases it was missing.
- **Tunnel-disclosure closure.** FIND4 enforces `lifecycle == active` on
  every MCP disclosure path (including `memory_get` and
  `allActiveTunnels`) and hardens `addTunnel`; FINDING-3 stops
  `VectorSimilaritySignal` from accumulating duplicate association edges.
- **VectorKit schema v4.** Index and projection fixes for `recentItemIDs`
  and `findByKeyword`.

## v1.0.31 — 2026-07-13

Substrate-capability and test-integrity release. New contradiction-hunting
and proposed-tunnel-lifecycle surfaces, the corpus-lane retrieval fixes
that make them work on production estates, and the completion of the
XCTest → swift-testing migration.

- **Contradiction hunter.** New GLK core plus an aria-mcp surface (hunt,
  review, proposed links, lens tiers — 66→68 tools) that mines the corpus
  vector lane for conflicting facts, backed by ConflictCue, a
  deterministic pairwise text-conflict screen. Both legs.
- **Proposed-lifecycle tunnels.** Tunnels can be captured in a `proposed`
  lifecycle and promoted via a `respondToTunnel` review verb, so a link
  isn't live until it's been reviewed. Both legs.
- **Retrieval that works on real estates.** The hunter corpus lane now
  generates candidates by BM25 lexical retrieval rather than vectors;
  `VectorSimilaritySignal` and the contradiction hunter mine the corpus
  vector lane (associations were dark on production estates); bounded
  sweeps probe newest-first via `recentItemIDs`; and `findByKeyword`'s
  limit counts distinct items, not rows.
- **Writer-lock liveness.** The writer lock verifies process identity
  rather than a bare PID check, which had crash-looped after a reboot when
  the PID was reused.
- **Scope-aware tunnel read.** Private-scope export carries its provenance
  tunnels again; audit ordering is re-keyed on full-precision HLC columns.
- **swift-testing migration complete.** The last XCTest is gone from the
  tree; the fast unit lane was stabilized and its parallel-runner races
  fixed.
- **Windows install.** `install.ps1` documents running via
  `-ExecutionPolicy Bypass`.

## v1.0.30 — 2026-07-11

Installer trust release: two small features that keep an install honest
about what will actually run.

- **PATH shadow warnings.** install.sh and install.ps1 now walk PATH after
  placing the binaries and warn when a DIFFERENT `mootx01` or `moot-mgr`
  sits earlier on PATH and shadows the fresh install (a stale copy from an
  old install dir, Homebrew, or a prior custom location) — naming the
  shadowing copy, the installed copy, and the fix. Previously the stale
  copy silently won and `mootx01 --version` disagreed with what was just
  installed.
- **Public upgrade path.** `mootx01 upgrade` now downloads the latest
  release (SHA-256 verified, typed confirmation unless `--yes`), installs
  it, converges plugin packages and tool permissions, and restarts the
  background services. `--from <path>` remains the local-build path; the
  implicit `.build/` search is gone. `upgrade --check` now queries the
  public repo (it pointed at an inaccessible internal repo — dead for
  every public user); `MOOTX01_REPO` overrides it, matching install.sh.
- **Restart reminder.** When an install or upgrade refreshes Claude Code's
  plugin cache, the success output now says to restart Claude Code — the
  refresh updates the on-disk cache only, and a running session keeps the
  old plugin loaded until restarted. Both language verticals.

## v1.0.29 — 2026-07-11

First-run reliability release. Same-day follow-up to v1.0.28 driven by a
fresh-machine install shakeout: every fix targets the out-of-box experience
or per-machine hygiene.

- **Install no longer hangs wiring Claude Code.** The plugin-refresh step
  shells out to the `claude` CLI; it now runs with stdin closed and a hard
  60-second deadline, so a CLI that decides to prompt (first-run onboarding,
  consent) or stall can never freeze the installer — it falls back to a
  printed instruction and the launchd services always get registered.
- **`install --yes` takes the safe default.** With an existing database and
  no explicit flag, `--yes` now adopts it (reuse) without prompting instead
  of blocking on a hidden question. Replacing still requires the explicit
  `--replace-db` flag — destruction is never a silent default.
- **Fresh sessions no longer show a spurious stop-hook error.** The
  writeback reminder matched its own banner text as "memory tools were
  used", then drove a tool call in sessions whose MCP connection wasn't up
  ("MCP server not connected"). It now recognizes genuine tool invocations
  only, and finishes quietly when the tools are unavailable.
- **Keychain hygiene.** Ephemeral estates (branch copies, in-memory serving
  modes, test estates) no longer persist their identity keys to the login
  Keychain — identity persistence now follows storage durability. A
  long-running install previously accumulated one orphaned
  `com.mootx01.estate.identity` item per throwaway estate, unboundedly.
- **Homebrew flow reworked.** The formula no longer runs a sandboxed
  post-install step that could neither write user config nor answer
  prompts; setup is one caveat-printed command, and stale `~/.local/bin`
  shadows from earlier script installs are called out explicitly.
- **winget manifests move to schema 1.12.0** (1.6.0 was deprecated and
  blocked submission validation). This release's winget submission is the
  first to carry the current schema.
- **Test integrity.** Restored the GLK audit-mining test fixtures that a
  refactor had silently disconnected, and pinned the transaction-isolation
  invariants at the persistence boundary.

## v1.0.28 — 2026-07-11

Security-hardening and substrate-robustness release. A full sweep of the
Codex security findings plus a resource-bounds, access-enforcement, and
privacy pass across the kits. No user-facing feature changes — all
correctness and hardening, both legs where a kit is dual-language.

- **Resource bounds (DoS resistance).** Every unbounded fan-out or matrix
  now has a cap: float recall is bounded to a top-k scan; the moot-mgr read
  API caps dropboxes and per-dropbox rows; Bradley-Terry preference
  competitors and latent-theme matrices are bounded; the migration
  benchmark caps its plan/entry fan-out; and the branch registry enforces
  an active-branch quota and releases a terminal branch's copied rows and
  parent estate to close a derive→discard memory-growth vector.
- **Sensitivity and access enforcement.** Tunnel (graph-edge) reads are
  gated by endpoint sensitivity; the memory-tool opt-out is enforced at
  dispatch, not just at projection; the memory tool honors the no-claims
  sensitivity posture on both legs.
- **Server-side authority.** Migration-promotion verdicts are decided
  server-side (no client-controlled disqualification); confirmation-strip
  and mutate-confirm noun-binding invariants are pinned so a stripped or
  mis-bound confirmation cannot slip a destructive op through; `--yes` no
  longer skips the interactive replace confirmation.
- **Privacy.** MindOverlap is gated on k-anonymity (k=3, not emptiness) and
  reports per-side k-sufficiency instead of exact drawer counts, so a
  federated overlap query discloses no per-estate structure beyond the
  differentially-private score.
- **Prompt-injection.** Untrusted FDC content is sanitized before it can
  enter the dashboard AI prompt.
- **Correctness / integrity.** RAM-resident caches invalidate on every
  mutation path; maintenance commits proposed keys per-key after a
  successful write; reanchor rejects an empty room or empty UDC;
  synthetic-audit hydration paginates with an HLC cursor; the BM25 rebuild
  is guarded against actor reentrancy; the memory adapter enforces the
  `/memories` path-segment boundary; version-skew parsing handles
  prerelease components.
- **Resident governor.** The graph-centrality and topology-snapshot duties
  now detect standalone tunnel and knowledge-fact changes — previously they
  could serve stale centrality or a stale topology snapshot after a
  graph-only edit — bringing the Swift watermark in line with the Rust
  governor.
- **Build hygiene.** Vendored SQLCipher amalgamation warnings are silenced
  on the SQLCipher target only (no first-party code touched); redundant
  access modifiers removed across GeniusLocusKit and LocusKit; the
  transaction-isolation invariant is documented at the persistence boundary.
- **Release / CI.** Trusted PyPI publishing with SHA-pinned actions, pinned
  winget submission, a data-retention-aware uninstall with reuse/replace
  reinstall, and permission classification for the newer memory tools.

Deferred to their own tracked follow-ups: audit-event coverage for
standalone tunnel/fact writes; the PostgreSQL backend NULL/JSON fidelity
pass (dormant backend); the Rust GLK zoom-window manifest read; and the
MindOverlap differential-privacy budget ledger.

## v1.0.18 — 2026-07-05

moot-mgr fix release. With monitoring now on by default (v1.0.17), the
dashboard's dead spots got a full wiring pass.

- **Capabilities panel fixed on Linux/Windows** — the Rust console read
  metrics that nothing emits, so the panel was always empty; it now shows
  the shipped capability set exactly as the macOS console does.
- **Busiest-estates panel** — the Overview now ranks the top five estates
  by activity, as the console spec always promised.
- **Topology chain proven** — the graph endpoint verified end-to-end
  against a populated estate snapshot in both consoles.
- **Test hygiene** — moot-mgr's test suite no longer depends on whether a
  live daemon happens to be running on the machine.
- Deferred (needs daemon-side support, v1.1): per-session Connections
  panel; estate admin controls.

## v1.0.17 — 2026-07-05

Sensitivity unlock and monitoring release. Private and secret memories
become reachable — by human approval only, never by a model — and the
monitoring dashboard is live out of the box.

- **Sensitivity unlock** — restricted ("private") rows unlock
  until local start-of-day; secret rows for a fixed 30 minutes. Approval
  is strictly out-of-band: `mootx01 unlock private|secret` and
  `mootx01 lock` in a terminal — macOS verifies with Touch ID / password
  (LocalAuthentication), Linux/Windows with two discrete passwords set at
  estate creation (salted PBKDF2, no recovery path). There is deliberately
  NO unlock tool on the MCP surface, so a prompt-injected model can never
  grant itself access. Grants live in daemon memory only (restart =
  locked), every grant, denial, and read-under-grant is audited, and
  search results never reveal how many sensitive rows matched — only that
  something may be hidden.
- **Monitoring ships ON** — the moot-mgr dashboard is live from first
  install instead of dark by default. Existing installs converge once on
  upgrade; an explicit user OFF is always respected. New
  `moot_monitoring_status` tool reads or sets the state (prompted, both
  namespaces).
- **Install integrity follow-ups** — the plugin package now refreshes for
  Claude Code even when the plugin owns the connection (the v1.0.16
  self-heal had skipped exactly that case); .pkg installs converge
  automatically; Desktop proxies run under the visible name
  `mootx01-proxy` so Activity Monitor distinguishes bridges from the
  daemon; plugin hooks fail soft when the daemon is down.
- **Search redaction parity** — Swift search previews now redact
  restricted/secret content exactly as Rust does; restricted-grant expiry
  on Linux/Windows honors local midnight, not UTC.

## v1.0.16 — 2026-07-04

Usability release: fetch any memory by ID, permission prompts collapsed to
the destructive few, and real fast-path word-class coverage out of the box.

- **New tool: `moot_memory_get`** — fetch a full memory drawer by UUID
  (verbatim content, metadata, provenance), closing the gap where search
  and recall return previews and `moot_recollect` covers only distilled
  factoids. Applies the exact containment and trust gates the search tools
  enforce — by-ID access is not a bypass.
- **Permission tiers re-cut by verb semantics** — the installer previously
  put every non-diagnostic tool behind an "ask" prompt (55 prompts,
  including every read). Now: reads and additive captures (file_memory,
  file_fact, write_journal, link_memories) are allowed; mutations of
  existing state still ask; erase stays denied. Rules are written for both
  the direct and plugin namespaces, and upgrades migrate the old
  conservative tiering in place — while never overriding an entry the user
  explicitly denied.
- **WordClassTable pristine seed curated** — the bundled seed grew from
  21 nouns / 18 verbs (a hand-written fixture) to 466 / 428 curated,
  unambiguous entries, so fresh estates take the fast-path lookup instead
  of paying the HMM on nearly every token. One shared artifact serves both
  ports; guard tests lock ambiguous words out.

## v1.0.15 — 2026-07-04

Installation integrity release. One daemon, one connection per client, no
accidental duplicates — however you install, in whatever order.

- **Plugin now connects over HTTP** — the Claude Code plugin's MCP manifest
  wires the resident daemon (`http://127.0.0.1:4242`) instead of spawning a
  private stdio `mootx01 serve` per session. Sessions share the one daemon
  (and its telemetry and governor); no second process ever holds the estate.
  All plugin flavors follow suit; hosts whose config schema cannot express
  HTTP use the `mootx01 proxy` bridge — no shipped manifest contains a bare
  `serve` entry, enforced by a packager test.
- **Install-moment dedupe** — the CLI installer now detects an installed and
  enabled MOOTx01 plugin and skips (and cleans up) its own direct MCP entry,
  so plugin + binary installs in any order converge to exactly one
  connection. Entries it does not own — custom data dirs, dev rigs, foreign
  servers squatting on the `mootx01` key, malformed shapes — are named in
  the output and never touched. A disabled plugin keeps the direct wiring
  (never leaves a client with no connection).
- **Existing installs self-heal** — `mootx01 install`/`upgrade` refresh the
  plugin package in place and update Claude Code's installed plugin copy
  (`claude plugin update`), so machines wired stdio by earlier versions
  converge to HTTP on their next install or upgrade plus a client restart.
- **Version-skew advisory** — `moot_estate_ping`/`moot_estate_status` report
  when the installed plugin and binary versions disagree, whichever was
  updated first.
- **Vault posture on HTTP entries** — vault-off installs carry
  `MOOTX01_VAULT=0` on the daemon itself; client-side env injection now
  applies only to command-shaped (proxy) entries where it has effect.

## v1.0.14 — 2026-07-04

Import cost release. Vault imports now pay for what they import, not for the
whole estate.

- **Vault import — delta-aware reindex tail** — importing into a populated
  estate previously always retrained the full embedding basis and re-embedded
  every chunk in the corpus (~70 minutes on a 50k estate — even when the
  vault was completely unchanged). Now: an unchanged reimport skips the tail
  outright (seconds); a small delta (under 5% of the indexed corpus) is
  embedded through the live basis by the encode drain — the same path a live
  capture takes — with no full retrain; only large imports (cold loads, big
  vaults) pay the full train-once+embed-once tail. Full retrain remains
  available on demand via `moot_reindex`. Both ports.
- **Reindex progress logging** — the full-corpus reindex now logs its phases
  (per-slot training, re-embed progress every 5,000 chunks, completion), and
  the vault import logs its sweep start and routing decision, so a long
  legitimate reindex is distinguishable from a hang in the daemon log.

## v1.0.13 — 2026-07-04

Claude Desktop reliability release. Fixes the session timeouts and
"Server disconnected" failures against large estates.

- **launchd: daemon runs at Interactive QoS** — the LaunchAgent's
  `ProcessType=Background` clamped the whole daemon to efficiency cores with
  throttled I/O. Measured live: the identical palace import ran 20x slower
  under launchd than shell-launched — long enough to starve tool responses
  past Claude Desktop's ~4-minute client timeout, whose cancel then aborted
  the import's basis-retrain tail and left semantic recall dark. The daemon
  serves live MCP requests; Interactive is the honest ProcessType.

- **Proxy: concurrent frame forwarding (both verticals)** — one slow tool call
  no longer blocks pings, cancellations, and parallel calls behind it.
- **Proxy: transport timeouts raised to 1 h** — lens/synthesis calls on a
  50k-memory estate legitimately run minutes; the client owns timeout policy.
- **Proxy: errors echo the request id** — synthesized `id:null` error frames
  were rejected by Claude Desktop's client and poisoned the stream. The Rust
  proxy additionally no longer exits the whole bridge on one failed call.
- **Proxy: daemon-start wait raised to 2 min** — a large estate takes ~30 s to
  bind its port; the 5 s window meant connecting right after a daemon restart
  always failed.
- **launchd: race-free daemon restart** — an asynchronous `bootout` could tear
  down the freshly bootstrapped replacement job, leaving no daemon at all
  after a reinstall. The restart now waits for teardown and verify-retries.
- **Storage: concurrent transactions wait instead of failing** — overlapping
  background workers (reindex rollup, dream cycle, live captures) hit
  `transactionConflict (nested transactions not supported)`; runTransaction
  now queues behind the open transaction (bounded at 60 s so true nesting
  still fails loudly).

## v1.0.12 — 2026-07-03

Plugin lifecycle hooks. The embedded install bundle (regenerated by the EE
packager) now ships Claude Code lifecycle hooks with the plugin — context
meter, compaction recovery, writeback gate, and session orientation — so
plugin-depth installs get the full memory-hygiene experience the marketplace
plugin carries. Also included: winget manifests for submission, permanent
version-less `.pkg` download aliases in the release workflow, PRIVACY.md, and
the release runbook.

## v1.0.11 — 2026-07-03

Installer correctness release. The v1.0.10 macOS `.pkg` was pulled because it
half-installed (wired MCP clients to a daemon it never registered). This
release makes every install path produce a working install and adds native
plugin/extension registration per client.

- **macOS `.pkg` installs a working daemon** — the GUI setup assistant now runs
  `mootx01 install` (the single source of truth) instead of reimplementing it,
  so the resident daemon and management console are registered, not just the
  clients wired.
- **`moot-mgr` placement fixed** — `copyResourceBundles` self-destructed when
  the source and destination were the same dir (the `.pkg` layout); the console
  now installs.
- **`mootx01 status` is honest** — added a TCP port-liveness fallback so it no
  longer reports "not running" while the daemon is serving 4242.
- **Integration-depth choice in the GUI** — Server only / Skills / Full plugin,
  matching the CLI's `--mode`.
- **Claude Code plugin is registered as a local marketplace** — `installPlugin`
  writes `.claude-plugin/marketplace.json` and merges `extraKnownMarketplaces`
  + `enabledPlugins` into `~/.claude/settings.json`, so `/plugin` lists it.
- **Claude Desktop extension** — `mootx01 install` now registers mootx01 as a
  Desktop extension (unpacked manifest + registry entry + enabled flag), macOS
  (Swift) and Windows (Rust). Shares the extension name so it dedups with the
  raw MCP wiring.
- **Candidate CI hardening** — builds the unsigned `.pkg` as a testable
  pre-release artifact and `install-verify` now runs `mootx01 install` and
  asserts the daemon/console register (not just `--version`).

## v1.0.10 — 2026-07-03

First non-beta release of the 1.0 line. Security-fix sweep from the codex audit (import
isolation, at-rest fail-closed, resource caps), recall/lens correctness fixes,
and the candidate-branch CI pipeline.

- **Security — import shard isolation (MEDIUM)** — bulk-import shard files are
  now estate-stamped and created exclusive-create instead of remove-and-open,
  so two estates sharing a directory (or a racing import) can no longer
  delete or contaminate each other's live shards; stale shards from a crashed
  import are swept by estate prefix at import entry. Rust additionally bounds
  the import fan-out to the machine's parallelism — one worker, one shard —
  instead of one thread + one shard file per 2,500-item slice. Both ports.
- **Security — encryption key fail-closed (MEDIUM, Rust)** — a present but
  wrong-length `db.key` now fails closed when opening private sidecar stores
  (BM25 index, import shards). Previously the malformed key was silently
  ignored and a FRESH sidecar was created plaintext — tokenized user content
  at rest without encryption.
- **Security — bulk import windowing (MEDIUM)** — palace bulk import now
  submits capture batches in 125,000-row transaction windows instead of one
  unbounded BEGIN..COMMIT over the entire source, bounding memory and SQLite
  write-lock hold time on very large palaces. At or under the window is
  byte-identical to prior behavior. Both ports.
- **Security — reembed thread cap (MEDIUM, Rust)** — `reembed_chunks` (the
  post-import reindex tail) now runs at most `embed_concurrency_cap` persistent
  workers instead of one OS thread per 3,000-chunk batch; output stays
  byte-identical to the serial path.
- **Security — distilled recall hydration (Rust)** — distilled recall now
  hydrates NN matches by id through the policy-enforcing frame path instead of
  intersecting with a newest-N recall window, so an older distilled factoid
  can no longer be pushed out of results by newer benign rows. Sensitivity
  ceilings unchanged.
- **Security — audit-log entry forgery (codex a477800)** — the unified audit
  log now recomputes every entry's SHA-256 content id from its wire encoding
  on every ingress path (add, merge, decode) and rejects entries whose id
  does not match — a forged (same-id, different-content) entry supplied by a
  peer can no longer overwrite an honest entry in the CRDT G-Set. Both
  ports, with forged-entry regression tests; the dormant federation
  `GSetAuditLog` scaffold carries boundary notes requiring the same defence
  when it is wired.
- **Security — fact-search probe trace writes (LOW, Swift)** — the dense-lane
  status probe inside `moot_fact_search` is now internal-origin: a read-only
  fact search no longer persists recall-trace rows for the probe's incidental
  hits.
- **Security — loopback MCP impersonation: accepted (documented)** — the
  fixed unauthenticated `127.0.0.1:4242` endpoint is a recorded, accepted CE
  limitation (launchd owns the port continuously; a same-user attacker can
  already read estate files directly). Real endpoint auth lands with EE v1.1
  off-localhost hosting. Disposition comments at the transport and installer
  seams, both ports; no behavior change.
- **Temporal matrix incremental correctness** — two fixes restoring the
  "incremental update == full rebuild, cell for cell" invariant for the
  temporal recall-scoring matrix: the incremental prune boundary no longer
  drops sources the fold would legitimately pair, and a backdated eventTime
  (the bulk-historical-import case) now falls back to a full temporal rebuild
  instead of silently emitting no deltas. Both ports, bit-identical.
- **Import — exportability relabel honored** — reimporting unchanged content
  whose exportability changed (e.g. public → private) now supersedes the
  drawer instead of being skipped as idempotent, so private-relabeled content
  stops riding the default public-only vault export scope. Both ports.
- **Audit write atomicity (Rust)** — single-item capture, mutation, and gated
  column writes now wrap the projection write and the sealed audit append in
  one transaction (rollback on any error), closing the unaudited-state gap the
  bulk path had already closed. Swift already wrapped; regression tests added
  both ports.
- **Node-motion HLC dedup** — mutation moments now dedup on the full HLC
  identity (physical, logical, node) rather than physical milliseconds alone,
  so same-millisecond writes under bulk import no longer collapse into one
  volatility event and skew `moot_lens_node_motion` verdicts. Both ports.
- **NMF empty-reduction reset (Rust)** — finalizing into an empty reduced
  vocabulary now fully resets prior factor state, fixing a serialize →
  deserialize panic on the stale basis.
- **CI — candidate pre-release builds** — pushes to `candidate/1.0.x` now
  build unsigned artifacts for all six platform targets behind a `make test`
  gate and publish a `candidate-<version>-<run>` GitHub pre-release (last 4
  kept). Stable release builds still cut only from `v*` tags. Plus: the CLA
  signing secret renamed to `CLA_BOT_TOKEN`, and stale `audit-flags` /
  `audit-clear` Make targets removed.
- **QueueKit — progress-based drain deadline** — `awaitDrain` (global and
  stream-scoped, both ports) now times out on *no progress* rather than total
  wall-clock: the deadline resets whenever the outstanding count drops below
  its lowest observed value, so an incrementally-progressing drain never
  false-times-out while a genuinely stuck worker still fails within the
  timeout. (`QUEUEKIT_INTERFACE.md` 1.4.0.)
- **Install — macOS artifacts now ship the SPM resource bundles (crash)** —
  the v1.0.9 macOS tarballs carried only the binaries, but the Swift
  binaries hard-crash on their first resource touch (any classify/search
  path) without the `LatticeLib`/`EideticLib`/`swift-crypto` resource
  bundles beside them. All tarball paths (local `make release`, candidate
  and release CI) now package the bundles, and `install.sh` places them
  next to the installed binaries. The `.pkg` installer already carried
  them.
- **Install — PATH entries are exec wrappers, not symlinks (crash)** — the
  runtime resolves resource bundles from the directory of the path the
  binary was *invoked* as, without following a symlink there, so the
  `~/.local/bin` symlinks crashed the CLI even with bundles correctly
  installed. `install.sh` and `mootx01 install`/`upgrade` now write a
  two-line `exec` wrapper instead; legacy symlinks are replaced on the
  next install or upgrade.
- **Test harness — NT-P0 Merkle contract recovered into the harness** — the
  bakeoff's Merkle/commitment byte contract was deleted from
  SubstrateKernel as a spike (correctly — the production Merkle is
  SubstrateLib's NT-F2 implementation) but its two harness consumers were
  never chased, leaving the validation-harness package uncompilable since
  June 21 in both editions. The contract is recovered from history as
  harness-local support code, mirroring the Rust harness's layout, with
  minimal adaptation to the current `MerkleRoot`/`ContentHash` API.
- **Test suite — assertions realigned with shipped decisions** — seven
  installer tests still asserted the reverted stdio client wiring (the
  unauthorized flip) instead of the accepted resident-daemon loopback
  posture; the moot-bridge live acceptance "skipped" by throwing (a
  failure in Swift Testing) and its binary probe never resolved under the
  modern test runner; a host-matrix count test froze at nine after the
  matrix grew to ten. All updated to assert current, ruled behavior.
- **QueueKit — telemetry data race (Swift, crash)** — the drain-latency
  telemetry window was mutated without a lock under a stale single-drainer
  assumption; two concurrent stream drainers (a live capture's encode racing
  a bulk import, with monitoring enabled) could corrupt it and crash the
  process. The window is now lock-guarded, matching the Rust port, with a
  concurrent-hammer regression test.
- **Test harness — GLK latency suites isolated** — the encode near-realtime
  acceptance suites assert wall-clock latency bounds over CPU-bound embed
  work; they false-failed whenever the full GeniusLocusKit suite ran in
  parallel and saturated the cores. They now self-skip on a bare `swift test`
  and run in a dedicated serial pass inside `make test`
  (`GLK_LATENCY_TESTS=1`), where their latency assertions are measured on a
  quiet machine. Full-suite runs are green at every entry point; the
  acceptance line is still enforced by the gate.
- `--version` now reports `1.0.10 (2026-07-03)` identically from both ports.

## v1.0.9-beta — 2026-07-02

Tenth beta of the 1.0 line. Import correctness + speed to semantic-live, a
parallel SVD kernel, and two HIGH security fixes.

- **Import → semantic-live, end to end** — the post-import basis retrain now
  runs at the tail of the import cycle (dense/RAG recall is query-ready on
  completion, no re-serve), the reindex loop drains through a single
  lease-holding worker (no synchronous-pump nested-transaction stall), and
  bulk-imported semantic hits now hydrate through the full candidate frame
  instead of a capture-time-capped locus window. Measured on a 50k MemPalace
  import: ~17.7 min → ~6.4 min import→semantic-live.
- **Parallel tournament Jacobi SVD** — LSA's basis retrain factorization now
  walks a round-robin tournament schedule whose column-disjoint rounds fan
  across all cores with bit-identical output (thread-count-independent; the
  n=512 schedule is pinned by a shared cross-port hash). The retrain's serial
  single-core wall drops ~8.5 min → ~4.5 min. Kernels and all conformance
  fixtures regenerated and cross-port verified byte-for-byte.
- **Security — contradiction lens (HIGH)** — `moot_lens_contradiction` no
  longer prints source-drawer or tunnel-endpoint IDs that point at
  Restricted/Secret drawers, matching the existing `moot_fact_search` /
  `moot_fact_timeline` source gating. Both ports.
- **Security — PostgreSQL TLS (HIGH)** — the Swift PostgreSQL backend now
  honors the DSN `sslmode=` parameter and fails closed: the effective TLS is
  the stronger of the DSN value and `ARIA_MCP_POSTGRES_TLS`, so
  `?sslmode=require` / `verify-ca` / `verify-full` can no longer open a
  plaintext connection (Rust already enforced this).

## v1.0.8-beta — 2026-07-02

Ninth beta of the 1.0 line. Agent-skills adapter surface and lifecycle hooks.

- **Claude Code lifecycle hooks** — context meter, compaction-recovery, and a
  writeback gate, plus an update-availability check hook.
- **Gemini CLI adapter** — added to the agent-skills adapter surface; install
  map and hook/reference docs trued up across adapters.
- **Codex Stop hook** — emits a JSON `systemMessage` (plain stdout is ignored
  on Stop).

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
  milliseconds; temporal matrix folds keyed on event time with full-precision
  HLC; shared IDF-reduced vocabulary for LSA/NMF;
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

- **Vault security posture** — vault is open in 1.0.x-beta (trust at
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
- **Federation signature** — ECDSA P-256 is used at the FIPS-validated module
  boundary. Apple uses SQLCipher at rest with the approved port divergences.

## v1.0.1-beta — 2026-06-17

Second beta of the 1.0 line. 60 changes since `v1.0.0-beta` (37 features, 7
fixes, 1 performance, 1 refactor, 4 test-hardenings, 4 spec/doc updates, 6
README/ABOUT touch-ups). The headline is the fusion-based semantic recall
stack and the substrate/kit hardening sweep; both the Swift and Rust ports
move together, conformance-gated.

### Recall — classical-fusion semantic recall

- **Recall architecture** — classical-fusion semantic recall with ARIA recall
  steering, full fusion including LSA/SVD, and CoreML-encoder readiness for 1.1.
- **Substrate primitive** — float-vector ops (l2Norm / l2Normalize / dot /
  cosine), Swift+Rust conformance-gated.
- **Distributional embedding providers** (Swift+Rust):
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
- **GLK parity** — GraphCache/PreferenceStore recall surface ported to Rust GLK;
  matrix/graph/preference recall lanes wired into
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
- Schema `ext` forward-compat slot extended to the 5 remaining entity tables.
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
