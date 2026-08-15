# Decision: MOOTx01-App product levels and repository ownership

**Status:** Accepted

**Date:** 2026-08-15

## Decision

MOOTx01-App remains coupled to the MOOTx01 source tree. It is not split into a
separate repository.

There are two source-repository editions and three application product levels:

- The public CE repository owns **MOOTx01 Community**, the open desktop app for
  macOS and the future Windows implementation.
- The private EE repository owns **MOOTx01 Pro**, the advanced personal Apple
  app for macOS, iPhone, and iPad.
- The private EE repository owns **MOOTx01 Enterprise**, the organizational
  deployment and assurance product.

EE remains the canonical, noisy agent-development workshop. Community changes
are built and security-tested in an EE worktree, then published through the
declarative Community replacement contract. The ordinary SHARED backporter is
not part of application publication. CE does not ingest EE history and the app
directory is an `EDITION-SURFACE`, never a byte-for-byte shared path.

## Capability ownership

Community owns the complete single-owner desktop loop: local encrypted estate,
Capture, Recall, Review, Quick Capture, ARIA/MCP, Product Dock, portable LAN,
individual import/export, and transparent engine/tool/edge diagnostics.

Pro adds the personal Apple layer: iPhone and iPad, on-device Intelligence,
Apple system surfaces, iCloud sync, personal federation, attended miners, and
work packets.

Enterprise adds organizational identity, managed policy and federation, remote
administration, managed deployment, audit/compliance assurance, and certified
integrations. A named Enterprise capability is not a claim that its UI has
shipped; absent surfaces remain absent until their implementation passes its
own release gates.

## Enforcement

The app target selects an immutable `MootAppEdition`. A central capability
policy controls navigation and lifecycle activation. Advanced Mode only reveals
additional destinations already allowed by that product; it cannot cross the
product boundary. Community has its own macOS build product without CloudKit,
mobile extensions, Calendar/Contacts mining purpose strings, or federation
Bonjour declarations.

The capability hierarchy is monotonic and test-locked:

```text
Community ⊂ Pro ⊂ Enterprise
```

The edition is not read from UserDefaults, an environment variable, a remote
claim, or user-controlled data.

## Publication rule

All implementation work lands in EE first. A CE publication must:

1. start from a reviewed EE commit;
2. select only the Community application surface;
3. contain no Pro/Enterprise source, entitlements, identifiers, internal docs,
   agent artifacts, or private history;
4. preserve the reviewed dependency pins and build/test against the exact CE
   substrate revision without automatic package resolution;
5. record the EE source commit and the resulting CE commit.

The same rule extends through `packages/apple`: Pro App Intents and Foundation
Models code are EE-only, `MootIntentCore` is SHARED, and the package manifest is
an edition-owned surface installed by the Community replacement contract.

No change to the CE repository is part of this decision's implementation.
