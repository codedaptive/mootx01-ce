# Blast Radius Report — ce-installer-ci

**Baseline:** N/A — CI-only mission; no Swift/Rust kit tests to baseline.
**Mission:** Add installer-build path to CE's `.github/workflows/release.yml`
**Change class:** Purely additive to existing workflow YAML + CHANGELOG

---

## Scope classification: PURELY ADDITIVE

This mission touches only:
1. `.github/workflows/release.yml` — additive YAML steps added to existing jobs
2. `CHANGELOG.md` — new bullet under the existing `develop/1.0.x` section
3. `docs_internal/analysis/blast_radius/ce-installer-ci_BLAST_RADIUS.md` — this report

No Swift symbols are modified. No Rust symbols are modified. No kit source files are touched. No schema is changed. No public API is altered.

---

## Symbols / surfaces being changed

### Surface 1: `.github/workflows/release.yml`

**Change class:** Additive — new steps appended to existing jobs; existing steps preserved untouched.  
**Scope:** CI configuration only (no code)

#### Call sites / blast radius

| Location | What changes | Classification | Justification |
|---|---|---|---|
| `release.yml` → `build-macos-arm64` job | New step: build `Mootx01Setup` binary + run `build-pkg.sh` + upload `macos-arm64-pkg` artifact | MUST_UPDATE (additive) | Core deliverable |
| `release.yml` → `build-macos-x86_64` job | Same as arm64 job, `--arch x86_64` | MUST_UPDATE (additive) | Core deliverable |
| `release.yml` → `build-windows-x86_64` job | New steps: install Inno Setup, compile `.iss`, upload `windows-x86_64-setup` artifact | MUST_UPDATE (additive) | Core deliverable |
| `release.yml` → `build-windows-arm64` job | Same as x86_64 job, arm64 arch | MUST_UPDATE (additive) | Core deliverable |
| `release.yml` → `release` job | Download new installer artifacts + include in `flat/` for checksums + publish | MUST_UPDATE (additive) | Required to surface installers in the GitHub release |

#### Files read (not modified) by the new steps

| File | Purpose | Classification |
|---|---|---|
| `distribution/macos/build-pkg.sh` | Invoked by new macOS .pkg step | INTENTIONALLY_LEFT — source unchanged; only invoked |
| `distribution/macos/Info.plist` | Read by `build-pkg.sh` at runtime | INTENTIONALLY_LEFT — source unchanged |
| `distribution/macos/distribution.xml` | Read by `build-pkg.sh` at runtime | INTENTIONALLY_LEFT — source unchanged |
| `distribution/macos/scripts/` | Invoked by `pkgbuild` | INTENTIONALLY_LEFT — source unchanged |
| `distribution/macos/resources/` | Bundled by `productbuild` | INTENTIONALLY_LEFT — source unchanged |
| `distribution/windows/mootx01-setup.iss` | Compiled by Inno Setup | INTENTIONALLY_LEFT — source unchanged |
| `apps/Mootx01-Setup/Package.swift` | Built by new `swift build` step | INTENTIONALLY_LEFT — source unchanged |

---

## Setup-assistant investigation (Part 1)

**Finding: `apps/Mootx01-Setup` IS a buildable target — NOT a blocker.**

- Product name: `Mootx01Setup` (matches `CFBundleExecutable` in `distribution/macos/Info.plist`)
- Package path: `apps/Mootx01-Setup`
- The `Package.swift` declares `.executableTarget(name: "Mootx01Setup", ...)`
- Depends on `MootInstallerCore` from `apps/mootx01` via local path dependency
- Build command: `swift build -c release --package-path apps/Mootx01-Setup --product Mootx01Setup`
- Binary output path (arm64): `apps/Mootx01-Setup/.build/release/Mootx01Setup`
- Binary output path (x86_64): `apps/Mootx01-Setup/.build/x86_64-apple-macosx/release/Mootx01Setup`

Setup assistant is RESOLVED — build step wired, arg 5 to `build-pkg.sh` is the above path.

---

## Summary

- MUST_UPDATE: 5 job sections (all additive — new steps only)
- INTENTIONALLY_LEFT: 7 files (consumed at runner runtime, not modified)
- RESCOPE_REQUIRED: 0

No rescope required. Blast radius is contained to the workflow file and CHANGELOG.
