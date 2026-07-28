# COMPLETION: FIX-HARNESS-20260727

Status: COMPLETE

Two coordinator-ordered harness fixes on stream/fix-bench (fast-forwarded to
develop/1.0.x @ 6e320455 before work), scope apps/mcp-benchmarker only,
both twins.

## What Was Done

- Part 0: Blast Radius Report — 5dd317a6
  (docs/blast_radius/FIX-HARNESS-20260727_BLAST_RADIUS.md; grep-only,
  codegraph unavailable this session; MUST_UPDATE ~30 sites / 16 files;
  RESCOPE_REQUIRED: 0)
- Part 1 (Swift twin): plaintext scratch estates + drain-barrier lane
  evidence — a2f139c7 (18 files, +875/−104)
- Part 2 (Rust twin): same, twin-symmetric — b52a15d0 (11 files, +918/−79)

### Fix 1 — plaintext scratch estates (keychain prompt flood)

Marker contract verified in product source (SPEC-BEFORE-REALITY):
- `EstateKeyProvider.encryptionOptOutMarkerName == "no-encrypt"`
  (apps/mootx01/Sources/MootInstallerCore/EstateOpenPosture.swift:98)
- Marker location: estate file's PARENT dir. Runners use the default estate
  (`<dataDir>/estate.sqlite` via MootPaths.estateURL), so the marker path is
  `<scratchDir>/no-encrypt`.
- Consulted ONLY on the absent-file branch of `resolveOpenPosture` →
  posture `newPlaintextByOptOut` → estate created plaintext, zero keychain
  contact. Marker must pre-date first serve — runners write it at
  scratch-dir creation.

Implementation: new ScratchPosture.swift / scratch_posture.rs; all six
scratch creators (lmeScratchDir, loCoMoScratchDir, lmebScratchDir +
rust twins) take an explicit `posture` param (no default — compiler finds
every call site); `--no-plaintext-scratch` CLI flag on all three subcommands
both twins (default absent = plaintext); posture is a run-key component of
the estate cache (plaintext vs encrypted estates are different bytes);
restore asserts marker-presence matches expected posture (mismatch = warned
miss, restored copy deleted); run-level report key `estate_encryption`
("plaintext-optout" | "encrypted-default") in all three reports both twins.

### Fix 2 — drain-barrier fresh-estate race

Ground truth (GeniusLocusKit DrainStatus.swift): `corpus_encode` lane is
present iff `corpusKits[handle]` is wired, and never deregisters. A first
poll that beats wiring sees `"drains: none"` — truthfully parseable but NOT
completion evidence.

Implementation: `DrainParseResult` splits `.idle` (Shape B, lane listed,
all idle → trusted immediately) from `.noLanes` (Shape A → accepted only
after grace: ≥4 consecutive noLanes polls AND ≥2.0 s elapsed, both
required); post-lane noLanes is anomalous → keep polling to timeout;
unparseable still aborts exit(1); transport-death abort retained; RPC
errors reset the consecutive-noLanes chain. Pure state machine
(DrainBarrierState) extracted for unit-testability. Barrier returns
DrainBarrierOutcome {converged, laneObserved}; per-unit report key
`drain_lane_observed` (nullable) threaded exactly like `cache_hit` through
all three runners/scorers both twins.

## Test Verification Log

### Baseline (mission start, after ff to 6e320455)
- swift test (apps/mcp-benchmarker): exit 0, 265 Swift Testing tests passed
- cargo test (apps/mcp-benchmarker/rust): exit 0, all suites ok

### Final (post-commit)
- Command: `nice -n 19 swift test` — exit 0
  - Swift Testing: "Test run with 269 tests in 56 suites passed"
  - XCTest: "Executed 95 tests, with 0 failures (0 unexpected)"
  - Log: scratchpad final-swift.log (session)
- Command: `nice -n 19 cargo test` — exit 0
  - 219 passed, 0 failed across all suites
- Baseline delta: Swift +4 net Swift Testing (+ new XCTest classes:
  ScratchPostureTests 10, DrainBarrierStateTests 11); Rust +28.

## Probe (--limit 1, fix-bench binaries)

- Built mootx01 in the fix-bench worktree (nice -n 19, exit 0).
- `mcp-benchmarker longmemeval --limit 1 --arm exact` against the synthetic
  sample corpus: exit 0. Barrier observed the lane draining
  (`corpus_encode: draining — pending: 1, in_flight: 1`) before idle —
  the exact pre-fix race window, now correctly waited out.
- Report JSON contains `"estate_encryption": "plaintext-optout"` and
  per-question `"drain_lane_observed": true`.
- Direct serve probe against a marker'd scratch dir logged verbatim:
  `mootx01 serve: creating estate UNENCRYPTED — opt-out marker present at
  /tmp/lme-bench-probeserve/no-encrypt. Run \`mootx01 upgrade\` to encrypt.`
  Zero keychain prompts.
- Note: the serve stderr line does not surface in benchmarker logs
  (MCPClient does not forward child stderr) — verified via direct launch.

## Discoveries

- MCPClient (both twins) swallows the spawned server's stderr; serve-side
  posture logging is invisible to harness logs. Fine for now (report JSON
  is the record), worth knowing for future serve-side diagnostics.
- The guard refused the 1-question synthetic sample probe (tiny-estate
  degeneracy) — pre-existing sample-corpus behavior, unrelated to either fix.
- Cache-key format change (posture component) invalidates existing cache
  entries once; acceptable since binary-fingerprint invalidation happens on
  every rebuild anyway.

## Outstanding

- None in scope. Existing estate caches from prior runs will cold-miss once
  due to the new key component.
