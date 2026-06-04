# Completion Report — DEPENDENCY_AND_WARNING_HYGIENE_001

**Mission:** Reconcile shared dependency pins; clear BNNS + ConvergenceKit warnings
**Stream:** hyg · **Branch:** stream/hyg-dependency-warning-hygiene · **Base:** develop
**Agent:** Bilby · **Date:** 2026-06-03 · **Status:** READY FOR MERGE

---

## 1. Mission summary

Build/dependency hygiene, no behavior change. Three independent cleanups:
1. Reconcile shared transitive dependency pins (swift-crypto, swift-nio)
   to one version across the workspace.
2. Clear the BNNS deprecation in PortableKernel-BNNS.swift.
3. Clear the ConvergenceKit async / unused-storage warnings.

**Delivered:** swift-crypto and swift-nio unified to **4.5.0 / 2.100.0**
across all resolvable roots; the BNNS deprecation contained to a single
documented site (2 scattered → 1 isolated); all three cited ConvergenceKit
warnings cleared (ConvergenceKit now builds with zero warnings). No
behavior change; all touched suites green.

**Key decision:** swift-crypto spans a MAJOR gap (3.x→4.x) on the
federation identity signing surface. This was escalated to Bob (the
mission's #1 Known Ambiguity). Bob chose **Unify UP to 4.x now** with a
Perkins security review. Smythe verified the bump needs **no source
changes**; Perkins confirmed it is **security-safe** (Ed25519 key format
wire- and persistence-stable).

---

## 2. Changes made

| File | Change | Δ |
|---|---|---|
| packages/kits/ConvergenceKit/Package.swift | swift-crypto floor `from: "3.0.0"` → `from: "4.0.0"` | 1 line |
| packages/kits/CorpusKit/Package.swift | swift-crypto floor `from: "3.0.0"` → `from: "4.0.0"` | 1 line |
| 9 × Package.resolved (ConvergenceKit, CorpusKit, PersistenceKit, VectorKit, NeuronKit, CognitionKit, GeniusLocusKit, apps/ARIA_MCP, Installer) | re-resolved to crypto 4.5.0 / nio 2.100.0 | mechanical |
| packages/libs/SubstrateKernel/Sources/SubstrateKernel/PortableKernel-BNNS.swift | isolate both deprecated `BNNS.applyMatrixMultiplication` calls (300, 443) behind one documented private wrapper `bnnsApplyMatMul`; thorough containment comment | +~30 / -10 |
| packages/kits/ConvergenceKit/Sources/ConvergenceKitFederation/FederationSyncEngine.swift | drop 2 spurious `await` on `localIdentity` (Sendable actor `let`) | 2 lines |
| packages/kits/ConvergenceKit/Sources/ConvergenceKitCloudKit/CloudKitSyncEngine.swift | push(): `let storage` (unused) → `storage != nil` guard + explanatory comment | +4 / -1 |
| docs/_internal/workhistory/analysis/blast_radius/…_BLAST_RADIUS.md | Blast Radius Report | new |

---

## 3. Commits

| Hash | Message |
|---|---|
| 33b6e181 | docs(hyg): blast radius report for dependency/warning hygiene |
| 120688f9 | chore(hyg): unify swift-crypto/swift-nio pins across packages |
| 8d8e7742 | chore(hyg): contain BNNS deprecation in PortableKernel-BNNS |
| 8ed041ef | chore(hyg): clear ConvergenceKit async/unused-storage warnings |
| 779f57d4 | chore(hyg): drop inert @available on BNNS matmul wrapper (self-review) |
| a2a49aa0 | docs(hyg): address Adams punch list — BRR audit trail + comment readability |

---

## 4. Deviations from mission

1. **Part 0 (fmt sweep) skipped — justified.** Repo has no `.swift-format`
   config and swift-format is not in its toolchain/CI. Defaults produce
   50–757 lines of churn per touched file (measured). A fmt sweep is only
   safe against an established formatter; running it would bury the
   mission's changes and break the BRR diff-match gate. Adams accepted this
   (noted it is the established correct behavior for this repo, 3rd
   recurrence).
2. **QueueKit/Package.swift not edited.** Mission's "known set" listed it,
   but it declares no swift-crypto/swift-nio directly; nothing to edit. Its
   Package.resolved was already at target (no-op).
3. **BNNS: second call site (443) also handled.** Mission cited only :300;
   blast-radius discipline brought :443 (same symbol) into scope.
4. **CloudKitSyncEngine.swift added to scope.** It is the "unused-storage"
   peer source (mission: "+ any peer source emitting the cited warnings").
5. **examples/Sidecar_Demo_macOS not unified.** Pre-existing breakage: its
   Package.swift:55 references `../ARIA_MCP` (= examples/ARIA_MCP), which
   does not exist (ARIA_MCP is at apps/ARIA_MCP). `swift package resolve`
   fails, so it stays at crypto 3.15.1. Out of scope; see Discoveries.
6. **BNNS not fully cleared to 0 — one contained warning remains.** The
   only non-deprecated replacement is BNNSGraph (a compute-engine rewrite
   on a conformance-gated kernel, requiring Newton four-way re-validation —
   out of scope for no-behavior-change hygiene). Mission verify line
   explicitly permits "(or the justified suppression is in place)."

---

## 5. Test results

Baseline (mission start) and final, all `swift test` exit 0:

| Package | Baseline | Final | Notes |
|---|---|---|---|
| SubstrateKernel | 38/38, 8 suites | 38/38, 8 suites | cross-kernel bit-identity (conformance) green → BNNS behavior unchanged |
| ConvergenceKit | 26/26, 8 suites | 26/26, 8 suites | federation pairing + identity signing green on crypto 4.5.0 |
| CorpusKit | 47/47, 9 suites | 47/47, 9 suites | Insecure.SHA1 content-ID green on crypto 4.5.0 |

Build verification (all touched roots, `swift build` exit 0): PersistenceKit,
VectorKit, NeuronKit, CognitionKit, GeniusLocusKit, apps/ARIA_MCP, Installer.

Warning classes:
- ConvergenceKit `swift build` warnings: **8 baseline → 0 final** (all cited classes cleared).
- SubstrateKernel BNNS deprecation: **2 baseline → 1 final** (contained in the documented wrapper).

---

## 6. Smythe pre-flight report

Verdict: **YELLOW** (advisory, not blocking; mission may proceed).

| Smythe finding | Resolution |
|---|---|
| (a) swift-crypto gap safe to unify UP to 4.x with no source changes (only Curve25519.Signing + Insecure.SHA1 used, API-stable) | Confirmed by build+test on 4.5.0. Bob authorized the UP unification. |
| (b) Blast radius is 12 Package.resolved, not 3 — WARNING, not RESCOPE (mechanical regenerations) | Enumerated all in BRR; 9 actually changed (QueueKit/LocusKit already at target; Sidecar broken). |
| (c) BNNS deprecated on macOS 15+; replacement is BNNSGraph; suppression acceptable | Chose documented containment (engine migration out of scope). |
| (d) No conflicting prior art; obs-owned files correctly off-limits | InMemoryObserver + federation tests untouched (verified). |

---

## 7. Adams post-flight report

Post-flight #1: **PASS** with 1 WARNING + 2 INFO. Verification pass #2: **PASS** ("Clean. Ship it.").

| Adams finding | Severity | Resolution |
|---|---|---|
| BRR listed 12 resolved files; diff has 9; missing 3 lacked INTENTIONALLY_LEFT entries | WARNING | Added INTENTIONALLY_LEFT entries (QueueKit/LocusKit no-op already-at-target; Sidecar broken manifest). Verified RESOLVED. |
| Sidecar dangling `../ARIA_MCP` path (pre-existing) | INFO | Documented as follow-on mission in BRR. |
| BNNS wrapper comment lacked blank line between paragraphs | INFO | Blank `//` line added. Verified RESOLVED. |
| Crypto bump = exactly 2 manifest line changes, no source edits; identity signing tests pass on 4.5.0 | (verify) | Confirmed clean. |
| Prohibited patterns (bridge/shim/orphan-deprecation/TODO) | (verify) | None in final diff (the briefly-added @available was self-removed in 779f57d4). |
| MUST_NOT_MODIFY (InMemoryObserver, federation tests) | (verify) | Zero stream commits touch them (two-dot diff noise is pre-existing develop changes). |

---

## 8. Perkins security review

Verdict: **CLEAN — no blocking, no advisory findings.**

| Area | Finding |
|---|---|
| Ed25519 key wire/persistence format across crypto 4.x | Stable (RFC 8410/8032 32-byte rawRepresentation, library-independent). Persisted keys survive the bump; no migration. |
| Signature determinism / verification semantics | Unchanged (deterministic Ed25519, no RNG). |
| Part 3 dropped `await` | No isolation weakening; correct Swift 6 immutable-actor-`let` access. |
| CloudKit push() guard `storage != nil` | Configuration check preserved; no unconfigured-push path. |
| Insecure.SHA1 content-ID | Non-security content addressing; unchanged in 4.x. |

---

## 9. Self-review

- Diff matches BRR MUST_UPDATE (9 resolved + 2 manifests + BNNS + 2 CK sources + BRR + report). No surprise files.
- Scope: within mission boundary; obs-owned files untouched.
- Anti-patterns: none (bridge/shim/orphan-deprecation/same-symbol TODO all absent). The inert `@available` added mid-stream was removed on self-review.
- Secrets: none introduced.
- Orphan code: none. The BNNS wrapper is live (called by both batch methods).
- Comment fidelity: BNNS containment comment rewritten to describe current behavior exactly (no stale "no warning" claim).

---

## 10. Discoveries / follow-ups

1. **Broken example (suggested follow-up mission):**
   `examples/Sidecar_Demo_macOS/Package.swift:55` declares
   `.package(name: "ARIA_MCP", path: "../ARIA_MCP")` — wrong relative path
   (ARIA_MCP is at `apps/ARIA_MCP`). The example cannot resolve and stays
   at swift-crypto 3.15.1, leaving it as the lone non-unified root. Fix the
   path (or drop the dep) in a separate mission to complete workspace-wide
   unification.
2. **BNNSGraph migration (tech debt):** the one remaining BNNS deprecation
   warning is contained in `bnnsApplyMatMul`. Clearing it requires
   migrating the conformance-gated kernel to BNNSGraph — a Newton
   four-way-conformance mission, not hygiene.
3. **Crypto baseline moved:** swift-crypto 4.5.0 is now the workspace
   baseline. Future kits should declare `from: "4.0.0"` (not 3.x) to stay
   consistent.

---

## 11. Final state

- Build: all touched roots build clean (exit 0).
- Tests: SubstrateKernel 38, ConvergenceKit 26, CorpusKit 47 — all green.
- Warnings: ConvergenceKit 0; SubstrateKernel 1 contained+documented BNNS deprecation.
- Agents: Smythe (YELLOW→proceed), Adams (PASS, verified), Perkins (CLEAN).
- Ready for merge.
