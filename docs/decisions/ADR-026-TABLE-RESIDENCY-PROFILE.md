---
version: v0.1
status: proposed
date: 2026-07-06
description: Per-table RAM vs disk residency decision, controlled by the application layer
---

# ADR-026 — Table Residency Profile

## Context

MOOTx01 estates range from 500-item personal collections on an iPad to
50k+ (growing to 20M) resident daemon estates on a server. The v1.0.x
release shipped with multiple index structures held entirely in RAM
(BM25 posting lists, audit log G-Set, centrality scores, Bradley-Terry
preference weights) regardless of deployment size. On a 50k estate this
consumed ~3GB and caused query timeouts when structures were rebuilt
per-query instead of served from persistent indexes.

The v1.0.21 remediation moves all of these to on-disk persistence as the
default. But a 500-item iPad estate genuinely benefits from RAM-resident
BM25 and vector indexes — the dataset fits in a few MB and
microsecond-level reads matter for UI responsiveness. A blanket "never
use RAM" policy penalises small deployments to protect large ones.

The design question: who decides which tables are RAM-resident, and how
does that decision flow to PersistenceKit?

## Decision

### 1. The application layer declares a ResidencyProfile

The top-level binary (`mootx01 serve`, `moot-mgr`, an iPad app target)
constructs a `ResidencyProfile` and passes it through
`EstateConfiguration` at estate-open time. The profile is a per-table
override map:

```swift
public enum TableResidency: Sendable {
    /// SQLite on disk. Page cache handles hot data automatically.
    /// This is the default for every table.
    case disk

    /// Loaded into an in-memory SQLite attached database at open.
    /// Reads are RAM-speed. Writes go through to the durable file
    /// via triggers so a crash never loses committed data.
    case ramMirrored

    /// No disk backing. InMemoryStorage behaviour. Tests only.
    case ramOnly
}

public struct ResidencyProfile: Sendable {
    /// Per-table overrides. Absent tables use the kit's default (disk).
    public let overrides: [String: TableResidency]

    /// Resident daemon hosting a large estate. All disk.
    public static let server = ResidencyProfile(overrides: [:])

    /// Mobile app with a small personal estate. Selective RAM for
    /// hot-path indexes where the dataset fits in single-digit MB.
    public static let mobile = ResidencyProfile(overrides: [
        "iix_postings": .ramMirrored,
        "iix_doclens": .ramMirrored,
        "vectors": .ramMirrored,
    ])

    /// Unit tests use InMemoryStorage — this profile is unused.
    public static let test = ResidencyProfile(overrides: [:])
}
```

### 2. Kits declare default residency per table

Each kit registers its tables with a default residency. Today, every
table defaults to `.disk`. A kit MAY request `.ramMirrored` as its
default for a table that is always small (e.g. a 10-row config table),
but the application's profile overrides always win.

### 3. PersistenceKit honours the profile at open time

When `SQLiteStorage` opens a table, it checks the profile:

- **`.disk`** (default): normal SQLite. The OS page cache handles hot
  data. No application-level caching.

- **`.ramMirrored`**: after schema setup, PersistenceKit executes
  `ATTACH DATABASE ':memory:' AS ram_<table>`, creates a mirror table
  in the attached database, bulk-copies the on-disk rows, and installs
  write-through triggers (INSERT/UPDATE/DELETE on the RAM table
  propagate to the durable table). All reads route to the RAM table;
  all writes go to both. Crash safety: the durable table is always
  current because triggers execute in the same transaction.

- **`.ramOnly`**: the existing `InMemoryStorage` backend, unchanged.

### 4. The profile flows through EstateConfiguration

```swift
public struct EstateConfiguration {
    // ... existing fields ...
    public var residencyProfile: ResidencyProfile = .server
}
```

`GeniusLocusKit.openEstate(configuration:)` passes the profile to each
sub-kit's storage open. Each sub-kit passes per-table hints to
PersistenceKit.

### 5. The default is always disk

No table is RAM-resident unless the application explicitly opts in via
the profile. The server profile is empty overrides — everything on disk.
This is the safe default for estates of any size.

### 6. Justification bar for RAM residency

A table qualifies for `.ramMirrored` only when ALL of:

- The table is bounded in size for the target deployment (< 10MB)
- The table is on the hot query path (read on every search/recall)
- RAM residency provides ≥10× latency improvement over SQLite page cache
- The application has measured both paths and confirmed the improvement

"It might be faster" is not sufficient. Measure first, opt in second.

## Consequences

- Server deployments use zero application-level RAM for index data. All
  reads go through SQLite. The 3GB RAM problem is structurally prevented.
- Mobile deployments can opt specific small tables into RAM for
  sub-millisecond reads without architectural changes.
- The same codebase serves both deployment profiles — no conditional
  compilation, no feature flags. The difference is one configuration
  value at app startup.
- New tables default to disk. A developer adding a table must explicitly
  justify RAM residency and add it to the mobile profile.
- PersistenceKit's `ATTACH ':memory:'` mechanism is a standard SQLite
  feature, not a custom cache layer. No cache invalidation logic —
  the triggers handle consistency.

## Changelog

- v0.1 (2026-07-06): Initial proposal arising from RAM index audit.
