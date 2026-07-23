---
version: 1.4.0
status: active
date: 2026-07-23
description: Defines versioning standards for code releases and specification documents across all mootx01 repositories.
---

# Versioning and Document Standards

## 1. Semantic Version Numbering

All code releases and specification documents follow Semantic Versioning: `MAJOR.MINOR.PATCH`.

### 1.1 MAJOR Version

Increment when a change breaks backwards compatibility. Consumers must modify their integration or migrate their data before upgrading.

Triggers:

- API surface changes that invalidate existing client code
- Schema changes requiring manual migration by the consumer
- Removal of fields, endpoints, or behaviors previously guaranteed stable
- Redesign of core interfaces

Example: `1.4.2` to `2.0.0`

### 1.2 MINOR Version

Increment when new functionality is added that does not break existing integrations. Consumers can upgrade without changing their code.

Triggers:

- New API capabilities, optional parameters, or endpoints
- Schema changes that are self-migrating (the system detects legacy data and upgrades it automatically with no consumer action required)
- New optional features layered onto a stable surface

Example: `1.0.3` to `1.1.0`

### 1.3 PATCH Version

Increment for bug fixes only. No new features. No API or schema surface changes visible to the consumer.

Triggers:

- Corrections to incorrect behavior
- Internal implementation changes invisible to consumers
- Performance fixes with no behavioral change

Example: `1.1.0` to `1.1.1`

### 1.4 Schema Change Classification

Schema changes are classified by consumer impact, not by internal complexity.

| Change Type | Consumer Impact | Version Bump |
|---|---|---|
| New optional fields | None | MINOR |
| Self-migrating schema upgrade | None (system handles it) | MINOR |
| Schema change requiring consumer migration | Consumer must act | MAJOR |
| Internal restructure, same API surface | None | PATCH |

The governing question: does the consumer have to do anything? If yes, it is a MAJOR bump. If no, it is MINOR or PATCH depending on whether new capability was added.

### 1.5 Pre-Release Designation

The development channel carries an explicit SemVer pre-release version.

- `develop/1.1.x` uses `1.1.0-beta-YY`.
- `YY` is the zero-padded count of pushes to `candidate/1.1.x`, starting with
  the branch-creation push as `01`. The field expands beyond two digits when
  necessary.
- The current value is `1.1.0-beta-03`: the creation push on 2026-07-15 plus
  two later pushes on 2026-07-20.
- CE and EE source, binary, plugin, and embedded-installer stamps use the same
  beta version.
- Candidate artifacts use the source version verbatim, without a leading `v`.
- Release-candidate tags may use `v1.1.Z-rcN`.
- Stable releases use `v1.1.Z`.

The exact commit still identifies the code under test between candidate
promotions. Before the next push to `candidate/1.1.x`, increment `YY` once
across both repositories and all generated artifacts so the pushed candidate,
its tag, and both binaries report the same version.

Zero-point releases (`0.x.y`) explicitly signal no backwards compatibility guarantee. mootx01 does not ship production releases under `0.x.y`. The first public release is `1.0.0`.

---

## 2. Branch Naming and Lifecycle

### 2.1 Branch Structure

| Branch Pattern | Purpose |
|---|---|
| `develop/X.Y.x` | **Default branch and fast-moving source beta.** Feature work and pull requests land here; the daily regression suite (`make test`) runs here; security scanning targets it. |
| `candidate/X.Y.x` | Test-build line. Every push produces an automatic **unsigned pre-release** whose installers are verified in CI (see 2.3). |
| `stable/X.Y.x` | Release staging / last-known-good. Merges sit inert here; a `vX.Y.Z` tag on this branch is what cuts the **signed** production release. |

All three branches of a release line (`develop`, `candidate`, `stable`) exist
permanently and concurrently for the lifetime of that line. `develop` is the
repository default branch (not `stable`): contributions and PRs target the
active line, and released binaries are obtained from tagged releases, not by
cloning.

For the active minor line, the development branch is a source beta rather than
a supported binary channel. Testers pin the commit they evaluate and use
disposable or backed-up data. The public plugin and normal installer continue
to track the stable line until a candidate or stable artifact is deliberately
published.

Per-branch automation:

- **develop** — daily `make test` (regression backstop; runs only when develop
  moved that day). Not a build.
- **candidate** — on every push, build all platforms UNSIGNED, publish a
  GitHub pre-release tagged with the source beta version
  (`X.Y.Z-beta-YY`), then verify the installers by installing that exact
  pre-release. No signing here.
- **stable** — no automation on push. Only a pushed `vX.Y.Z` tag triggers the
  signed, notarized release build.

### 2.2 Stable Branch Lifecycle

Each stable branch is permanent for the lifetime of that minor version. The branch name does not change. Individual releases on that line are marked with git tags.

Example for the `1.0.x` line:

```
stable/1.0.x (branch, permanent)
  tag: 1.0.0  -- initial stable release
  tag: 1.0.1  -- first bug fix
  tag: 1.0.2  -- second bug fix
```

Multiple stable lines run concurrently. Users on `stable/1.0.x` receive bug fixes independently from users on `stable/1.1.x`.

### 2.3 Release Promotion Within a Line

Every release moves through the three branches of its line in one direction.
Promotion is strictly linear; development never reaches stable directly:

```
develop/X.Y.x  --merge-->  candidate/X.Y.x  --merge-->  stable/X.Y.x
 (daily work)              (build + validate)           (published)
```

1. Development lands on `develop/X.Y.x`.
2. When preparing a release, `develop` is merged into `candidate`. That push
   automatically builds every platform and publishes an unsigned pre-release
   (`X.Y.Z-beta-YY`); CI then installs it via the product installers
   to prove they work. Deeper hardware testing (e.g. the Windows VM harness)
   runs against that same pre-release before promotion.
3. On a passing candidate, `candidate` is merged into `stable`. This does NOT
   build anything — `stable` is a staging area. When ready, a `vX.Y.Z` tag is
   pushed on `stable`, and that tag alone triggers the signed, notarized
   release.
4. Fixes for problems found on candidate land on `develop`, then re-merge to
   `candidate` for a fresh pre-release. Commits are never made directly on
   `candidate` or `stable`.
5. After a release ships, `stable` is merged back into `develop` so the two
   stay in sync (the promotion merge-commits live only downstream otherwise).
   This is a no-content merge and keeps the branches even.

Because nothing originates on `candidate` or `stable`, every line that ships
was authored and reviewed on `develop` first — so scanning/testing `develop`
covers everything downstream.

### 2.4 Line Promotion Flow

When a development line stabilizes and ships as a new minor version:

1. `develop/1.1.x` is promoted through `candidate/1.1.x` to `stable/1.1.x`
   per section 2.3.
2. A new `develop/1.2.x` branch is cut immediately, with its
   `candidate/1.2.x` alongside.
3. `stable/1.0.x` continues receiving backported bug fixes as long as it is
   supported; backports flow through `candidate/1.0.x` like any release.

### 2.5 Tagging Rules

Every production release must be tagged in git at the exact commit that shipped,
on `stable`. The tag push is the sole trigger for the signed release build.

Tag format: `vMAJOR.MINOR.PATCH` (e.g. `v1.0.0`, `v1.0.10`, `v1.1.0`). A
pre-release qualifier is allowed on a signed release when applicable
(`v1.0.0-beta`). **Only organization admins may create `v*` tags** (enforced by
a repository tag ruleset), since a `v*` tag creates a Codedaptive-signed
release.

Candidate pre-release tags are a **separate namespace**: `X.Y.Z-beta-YY`
with **no leading `v`**. This is deliberate — a `v*` tag would trigger the
signed release pipeline, so candidate builds must stay clear of it. The
installers normalize a bare `X.Y.Z` to its `vX.Y.Z` tag but leave
pre-release tags untouched, so a candidate installs with
`MOOTX01_VERSION=X.Y.Z-beta-YY`.

Tags are immutable. A tagged release is never altered. If a critical fix is
required, a new PATCH tag is created.

---

## 3. Document Front Matter

Every specification, standards document, and process document in this repository must include YAML front matter as the first block in the file. The document filename never includes a version number.

### 3.1 Front Matter Schema

```yaml
---
version: MAJOR.MINOR.PATCH
status: draft | review | active | deprecated | superseded
date: YYYY-MM-DD
description: One sentence describing the document's purpose.
superseded_by: path/to/replacement.md   # required when status is superseded
---
```

All fields are required. `superseded_by` is required only when status is `superseded` and is omitted otherwise.

### 3.2 Status Definitions

| Status | Meaning |
|---|---|
| `draft` | Work in progress. Not yet reviewed. Do not treat as authoritative. |
| `review` | Complete draft under active review. Not yet approved. |
| `active` | Current authoritative version. This is the governing document. |
| `deprecated` | Still valid but scheduled for removal. A replacement exists or is in progress. |
| `superseded` | Archived. Replaced by the document identified in `superseded_by`. Do not use for new work. |

### 3.3 Document Version Bump Rules

Specification documents follow the same MAJOR.MINOR.PATCH logic applied to their content.

| Change Type | Bump |
|---|---|
| Removes or redefines an existing requirement | MAJOR |
| Adds new requirements that do not invalidate existing ones | MINOR |
| Clarification, correction, or formatting with no substantive change | PATCH |

### 3.4 Archiving a Superseded Document

When a document is replaced:

1. Set `status: superseded` in the old document's front matter.
2. Set `superseded_by:` to the relative path of the replacement document.
3. Update `date:` to the date of supersession.
4. Do not delete the file. Move it to `docs/archive/` if clutter is a concern.
5. Add a changelog entry at the bottom of the old document noting supersession.

---

## 4. Changelog

Every document governed by this standard maintains a changelog section at the bottom of the file. Code repositories maintain a root-level `CHANGELOG.md`.

### 4.1 Document Changelog Format

```markdown
## Changelog

### 1.1.0 -- 2026-06-14
Added schema change classification table. Clarified self-migrating schema as MINOR bump.

### 1.0.0 -- 2026-06-14
Initial release.
```

### 4.2 Code Changelog Format

```markdown
## Changelog

### 1.1.0 -- 2026-06-14
- Added VaultJobRegistry async import/export (VLT-01).
- Added EstateCache with LRU eviction and provenance gate (PK-CACHE-A through PK-CACHE-C2).

### 1.0.1 -- 2026-06-14
- Fixed targeted uninstall unconditionally running full teardown.

### 1.0.0 -- 2026-06-14
- Initial stable release.
```

---

## 5. Agent and Mission Rules

Any mission that modifies a document governed by this standard must comply with the following rules or it will be rejected.

1. The front matter `version` field must be incremented. A mission that touches a spec without bumping the version is invalid.
2. The front matter `date` field must be updated to the date of the mission.
3. A changelog entry must be appended at the bottom of the document describing the change.
4. The version bump magnitude must match the nature of the change as defined in section 3.3.
5. A mission may not change `status` from `active` to `superseded` without also setting `superseded_by` to a valid path.

---

## Changelog

### 1.4.0 -- 2026-07-23
Made the 1.1 development version explicit as `1.1.0-beta-YY`, defined `YY` as
the `candidate/1.1.x` push count, synchronized the value across CE and EE
product/plugin stamps, and made candidate artifact tags equal the source beta
version.

### 1.3.0 -- 2026-07-23
Defined `develop/X.Y.x` as the fast-moving source beta for its minor feature
line. Distinguished the branch channel from candidate and stable artifact
versions, and documented the stable installer/plugin boundary.

### 1.2.0 -- 2026-07-03
Documented the branch model as actually operated: `develop` is the repository
default branch; `candidate` auto-builds unsigned pre-releases
(`X.Y.Z-prerelease.<run>`) and verifies the installers in CI; `stable` stages
inertly until a `vX.Y.Z` tag cuts the signed release; daily `make test` runs on
`develop`; `stable` is merged back to `develop` after each release; and `v*`
tag creation is restricted to organization admins. Additive (2.1, 2.3, 2.5).

### 1.1.0 -- 2026-07-02
Added the `candidate/X.Y.x` branch and documented the three-branch
develop -> candidate -> stable promotion flow, with the release-line branches
now permanent. Additive per section 3.3 (adds the candidate tier). Line
promotion and tagging renumbered to 2.4 and 2.5.

### 1.0.0 -- 2026-06-14
Initial release.
