---
title: FAB5-B1 Completion Report
version: v0.1
stream: b1
status: COMPLETE
date: 2026-07-24
mission: FAB5-B1
worker: bilby (SARC-1)
---

# Completion Report: FAB5-B1
# 1.1.0-beta.1 Release Engineering + ROADMAP Superset Amendment

Status: **COMPLETE**

---

## Mission Summary

Stamped the first internal beta (`1.1.0-beta-04`) for the Wave-1 / FAB5
feature set and amended ROADMAP.md to reflect shipped sensitive-tier behavior.
Tier 2, docs+config only — zero Swift/Rust feature code edits.

---

## Smythe Pre-flight

**Verdict: GREEN**

- Beta-04 version confirmed correct: candidate/1.1.x push count = 3 at start → next push = #4.
- Tree consistent at `1.1.0-beta-03` (`verify_version.py` clean).
- ROADMAP amendment target confirmed at line 142.
- All four 1.1 superset items (Obsidian, Review Center, Work Packet, moot-mgr) confirmed present.
- All 6 plugin.json mirrors at `1.1.0-beta-03` (parity confirmed).
- All 9 FAB5 completion reports present in `docs/status/`.
- Tree clean (git status clean, no in-flight conflicts).
- No blockers; two advisories (Cargo.lock gitignore inconsistency; EE side not bumped — both noted).

---

## Commits

| SHA | Part | Message |
|---|---|---|
| `299eb52b` | 1 | `chore(release): stamp 1.1.0-beta-04 and changelog` |
| `587d6f56` | 2 | `docs(roadmap): sensitive-tier opt-in language; 1.1 superset confirmed` |
| `dba41576` | 3 | `chore(release): plugin parity check + beta checklist` |
| `e387153d` | 3-fix | `fix(release): update remaining beta-03 prose refs to beta-04` |

---

## Files Modified

| File | Change |
|---|---|
| `apps/mootx01/rust/Cargo.toml` | version: `1.1.0-beta-03` → `1.1.0-beta-04` |
| `apps/mootx01/rust/Cargo.lock` | version: `1.1.0-beta-03` → `1.1.0-beta-04` |
| `apps/mootx01/Sources/mootx01/MootMain.swift` | `currentVersion` + `releaseDate` updated |
| `apps/mootx01/rust/src/lib.rs` | `RELEASE_DATE` updated |
| `apps/mootx01/rust/src/embedded/install-bundle.json` | version tokens updated (all occurrences) |
| `apps/mootx01/Sources/MootInstallerCore/Generated/EmbeddedArtifacts.swift` | version tokens updated (all occurrences) |
| `distribution/plugin/plugin.json` | version → `1.1.0-beta-04` |
| `distribution/plugin/.claude-plugin/plugin.json` | version → `1.1.0-beta-04` |
| `distribution/plugin/.codex-plugin/plugin.json` | version → `1.1.0-beta-04` |
| `distribution/plugin/.cursor-plugin/plugin.json` | version → `1.1.0-beta-04` |
| `distribution/plugin/.plugin/plugin.json` | version → `1.1.0-beta-04` |
| `distribution/plugin/gemini-extension.json` | version → `1.1.0-beta-04` |
| `distribution/plugin/README.md` | version reference updated |
| `distribution/plugin/CHANGELOG.md` | version reference updated |
| `CHANGELOG.md` | new `1.1.0-beta-04` section (9 FAB5 missions) |
| `ROADMAP.md` | sensitive-tier sentence amended; frontmatter date updated |
| `VERSIONING.md` | §1.5 current-value updated; version 1.4.0→1.4.1; changelog entry added |
| `AI_START_HERE.md` | version prose references updated |
| `README.md` | version channel notice updated (Adams finding) |
| `SECURITY.md` | version reference updated (Adams finding) |
| `docs/README.md` | version channel notice updated (Adams finding) |
| `llms.txt` | version note updated (Adams finding) |
| `scripts/release/README.md` | current-version + next-bump runbook updated (Adams finding) |
| `scripts/release/bump_version.py` | docstring example updated (Adams finding) |
| `docs/status/RELEASE_CHECKLIST_1_1.md` | Section 6 added (beta.1 state, net-new lines only) |

---

## Version Stamp Locations (Part 1 record)

All version stamps managed by `scripts/release/bump_version.py`. Three groups:

**Group 1 — Binary stamps:**
- `apps/mootx01/rust/Cargo.toml` — `[package] version`
- `apps/mootx01/rust/Cargo.lock` — `mootx01-cli` version
- `apps/mootx01/Sources/mootx01/MootMain.swift` — `currentVersion`, `releaseDate`
- `apps/mootx01/rust/src/lib.rs` — `RELEASE_DATE`

**Group 2 — Plugin manifests:**
- `distribution/plugin/plugin.json`
- `distribution/plugin/.claude-plugin/plugin.json`
- `distribution/plugin/.codex-plugin/plugin.json`
- `distribution/plugin/.cursor-plugin/plugin.json`
- `distribution/plugin/.plugin/plugin.json`
- `distribution/plugin/gemini-extension.json`
- `distribution/plugin/README.md`
- `distribution/plugin/CHANGELOG.md`

**Group 3 — Embedded installer copies:**
- `apps/mootx01/rust/src/embedded/install-bundle.json`
- `apps/mootx01/Sources/MootInstallerCore/Generated/EmbeddedArtifacts.swift`

**Prose documentation (not in bump_version.py, updated manually):**
- `VERSIONING.md` §1.5, `AI_START_HERE.md`, `README.md`, `SECURITY.md`,
  `docs/README.md`, `llms.txt`, `scripts/release/README.md`,
  `scripts/release/bump_version.py` docstring

---

## Part 2: ROADMAP Amendment

**Change made (ROADMAP.md line 142):**

Before:
> Sync will be off by default. Restricted and Secret memories stay on device.

After:
> Sync will be off by default. Restricted and Secret memories stay on device
> **by default**; keychain-authorized per-tier opt-in available.

**Superset ruling confirmed:** continuous Obsidian (line 106), Review Center
(line 72), Work Packet (line 119), moot-mgr (line 151) all present in Version
1.1 section. iPadOS listed at line 67 (FAB5-L1 intact). No restructure performed.

---

## Part 3: Plugin Parity

All 6 plugin.json mirrors confirmed at `1.1.0-beta-04` post-bump:
- `distribution/plugin/plugin.json` ✓
- `distribution/plugin/.claude-plugin/plugin.json` ✓
- `distribution/plugin/.codex-plugin/plugin.json` ✓
- `distribution/plugin/.cursor-plugin/plugin.json` ✓
- `distribution/plugin/.plugin/plugin.json` ✓
- `distribution/plugin/gemini-extension.json` ✓

Parity gate: PASS. No hand edits to generated tree.

**Note:** The `distribution/plugin/` tree is EE-generated. The bump was applied
via the coordinated `bump_version.py` script (standard CE release process), not
by hand editing. The EE packager will regenerate on its next sync; the version
field will be overwritten then. This is the expected workflow per the script's
own comments.

---

## Test Verification Log

### Baseline (mission start)
This is a Tier 2 docs+config mission — zero Swift/Rust code changes. Baseline
equals final.

### Final
- Command: `swift test --package-path apps/Mootx01-App 2>&1 | tail -10`
- Exit code: 0
- Pass count: **34 tests in 7 suites**
- Tail output (verbatim):
```
Test "startSession throws sessionAlreadyActive when a session is in progress (real manager)" started.
Test "startSession throws sessionAlreadyActive when a session is in progress (real manager)" passed after 0.002 seconds.
Test "all posture card text fields are non-empty" started.
Test "all posture card text fields are non-empty" passed after 0.001 seconds.
Test "posture raw values are stable (no key drift)" started.
Test "posture raw values are stable (no key drift)" passed after 0.001 seconds.
Test "endSession updates lastSession timestamp on the known peer (real manager)" started.
Test "endSession updates lastSession timestamp on the known peer (real manager)" passed after 0.002 seconds.
Suite "FederationPanel — state transitions and F1 invariants (FED-OD-6b)" passed after 0.026 seconds.
Test run with 34 tests in 7 suites passed after 0.027 seconds.
```

---

## Adams Post-flight

**Verdict: CLEAN-WITH-FOLLOWUPS → resolved → PASS**

Finding #1 (WARNING — resolved): Four files still referenced `1.1.0-beta-03`:
`README.md:27`, `SECURITY.md:185`, `docs/README.md:4`,
`scripts/release/README.md:23-24`. Fixed in commit `e387153d`. Also updated
`llms.txt` and `scripts/release/bump_version.py` docstring found in sweep.

No CRITICAL findings. No scope violations. No bridge helpers, orphan
deprecations, or secret leaks.

VERSIONING.md and AI_START_HERE.md scope expansion (prose docs not in declared
file list): Adams classified within declared blast radius (docs only) — not blocking.

---

## Out-of-Scope Items (noted for coordination)

- **EE beta bump:** VERSIONING.md §1.5 requires CE and EE to be bumped together.
  EE is explicitly out of scope for this CE-only mission. EE must run
  `bump_version.py 1.1.0-beta-04` before the candidate push. See Section 6
  of `docs/status/RELEASE_CHECKLIST_1_1.md` for Bob's next steps.

---

## Success Criteria

- ✅ Version stamped to `1.1.0-beta-04` — all stamps consistent via `verify_version.py`
- ✅ CHANGELOG.md — `1.1.0-beta-04` section lists all 9 FAB5 missions
- ✅ ROADMAP.md — sensitive-tier language updated; 1.1 superset confirmed
- ✅ Plugin parity — all 6 mirrors at `1.1.0-beta-04`
- ✅ Beta checklist — Section 6 added with stamp results and Bob's next steps
- ✅ Tests pass — 34 tests, exit 0
- ✅ Beta.1 is one `git merge develop→candidate` + EE bump + TestFlight upload away
