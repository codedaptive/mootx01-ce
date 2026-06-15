---
version: 1.0.0
status: active
date: 2026-06-14
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

Releases in active development append a qualifier before tagging stable.

- `1.1.0-dev` during development
- `1.1.0-rc1`, `1.1.0-rc2` during release candidate review
- `1.1.0` upon promotion to stable

Zero-point releases (`0.x.y`) explicitly signal no backwards compatibility guarantee. mootx01 does not ship production releases under `0.x.y`. The first public release is `1.0.0`.

---

## 2. Branch Naming and Lifecycle

### 2.1 Branch Structure

| Branch Pattern | Purpose |
|---|---|
| `stable/X.Y.x` | Production stable release line |
| `develop/X.Y.x` | Active development for next minor release |
| `develop/X.0.x` or `develop/2.0` | Major version development, potentially experimental |

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

### 2.3 Promotion Flow

When a development branch stabilizes and ships:

1. `develop/1.1.x` is promoted to `stable/1.1.x`.
2. `develop/1.1.x` is deleted or archived.
3. A new `develop/1.2.x` branch is cut immediately.
4. `stable/1.0.x` continues receiving backported bug fixes as long as it is supported.

### 2.4 Tagging Rules

Every production release must be tagged in git at the exact commit that shipped.

Tag format: `vMAJOR.MINOR.PATCH`

Example: `v1.0.0`, `v1.0.1`, `v1.1.0`

Tags are immutable. A tagged release is never altered. If a critical fix is required, a new PATCH tag is created.

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

### 1.0.0 -- 2026-06-14
Initial release.
