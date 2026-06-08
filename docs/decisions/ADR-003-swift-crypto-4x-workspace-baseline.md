# ADR-003 — swift-crypto 4.x is the Workspace Dependency Baseline

- Status: Accepted — unified 2026-06-03 (mission DEPENDENCY_AND_WARNING_HYGIENE_001)
- Date: 2026-06-03
- Deciders: Bob (Commander)
- Scope: All Swift packages in mootx01-ee that pull swift-crypto (directly or via vapor/postgres-nio); the shared transitive-dependency pin policy
- Evidence: DEPENDENCY_AND_WARNING_HYGIENE_001 change-impact report + completion report (dependency version map; security review of the federation identity signing surface). Companion to the C-1 zero-external-dependency doctrine and DECISION_LIFT_PACKAGE_SWIFT_RULE_2026-05-28.

## Context

swift-crypto was pinned at divergent versions across the workspace: 3.15.1 in
the roots whose dependency tree was capped below the next major (ConvergenceKit
and CorpusKit each declared `.package(url: swift-crypto, from: "3.0.0")`, which
SPM resolves as `< 4.0.0`), and 4.5.0 in roots that pull it only transitively
through `vapor/postgres-nio` (declared in PersistenceKit). swift-nio diverged
similarly as a minor gap (2.99.0 vs 2.100.0), purely from stale lockfiles.

A split crypto version across a federation-critical dependency surface is a
provenance/auditability liability under the EDITIONS standard: the federation
identity signing path (Ed25519 via `Curve25519.Signing`) must be pinnable and
consistent.

Unifying swift-crypto means crossing a **major** version boundary (3.x → 4.x) on
the federation identity signing surface. That is not a decision an automated
hygiene mission should make silently. It was escalated to Bob.

## Decision

**swift-crypto 4.x (currently 4.5.0) is the single workspace baseline; swift-nio
unifies to 2.100.0.** The two direct declarers (ConvergenceKit, CorpusKit) now
declare `from: "4.0.0"`; all resolvable roots re-resolve to crypto 4.5.0 /
nio 2.100.0.

Future kits that depend on swift-crypto MUST declare `from: "4.0.0"` (or higher),
never a 3.x floor, to keep the workspace on one version.

## Why the major bump is safe (no source migration)

- The only swift-crypto APIs used are `Curve25519.Signing.PrivateKey/PublicKey`
  (+ `.signature(for:)`, `.isValidSignature(_:for:)`, `.rawRepresentation`) in
  ConvergenceKit federation, and `Insecure.SHA1.hash` (content addressing) in
  CorpusKit. All are API-stable across 3.x→4.x. The bump required **zero source
  changes**; all touched packages build and test green on 4.5.0.
- Security review: the Ed25519 raw key encoding is the RFC 8410/8032
  fixed 32-byte representation — library-independent and wire/persistence stable.
  Keys already persisted (as `rawRepresentation` blobs in the PersistenceKit
  estate audit-log metadata) survive the bump with no migration. Ed25519
  signatures are deterministic; verification semantics are unchanged.

## Consequences

- Single, auditable crypto/nio version across the workspace.
- One root remains un-unified: `examples/Sidecar_Demo_macOS` cannot re-resolve
  because its `Package.swift` references a non-existent `../ARIA_MCP` path
  (pre-existing breakage). A follow-on mission must fix that path to complete
  workspace-wide unification.
- This ADR does not alter the C-1 zero-external-dependency constraint:
  swift-crypto and postgres-nio remain the pre-existing, approved external
  dependencies; no new third-party dependency is introduced.

## Status note

This convention was previously recorded only in the (gitignored) mission BRR and
completion report. This ADR is its canonical, discoverable home so the baseline
does not drift silently.
