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

The application directory is an `EDITION-SURFACE`, never a byte-for-byte shared
path: each edition owns the app it ships, and neither is derived from the other
file by file. What Community carries is stated here, in this record, rather than
inferred from what Enterprise happens to contain.

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

## What a Community release contains

A Community release carries the Community application surface and nothing
beyond it: no Enterprise source, entitlements or identifiers, no maintainer
documentation or agent artifacts. Its dependency pins are the reviewed ones and
it builds and tests against an exact substrate revision rather than resolving
packages afresh, so a release is reproducible from what it ships.

The same division runs through `packages/apple`: the Enterprise App Intents and
Foundation Models code is Enterprise-only, `MootIntentCore` is shared, and each
edition owns the package manifest describing what it actually ships.

No change to the CE repository is part of this decision's implementation.
