---
title: MOOTx01-App Interface
version: 1.0.0
status: accepted-1.1-target
date: 2026-09-11
description: Platform-boundary contract for the native app's embedded and resident-provider routes.
spec_type: protocol
authors: MOOTx01 maintainers
relates_to:
  - MOOTX01_APP_SPEC.md
  - FIRST_PARTY_PROVIDER_SPEC.md
  - FIRST_PARTY_PROVIDER_INTERFACE.md
---

# MOOTx01-App Interface

## 1. Scope

This interface defines how the Apple app reaches an estate. It does not define
the first-party provider's operation catalog, JSON schemas, discovery record,
or authentication protocol; those remain canonical in
[`FIRST_PARTY_PROVIDER_SPEC.md`](FIRST_PARTY_PROVIDER_SPEC.md) and
[`FIRST_PARTY_PROVIDER_INTERFACE.md`](FIRST_PARTY_PROVIDER_INTERFACE.md).

## 2. Platform routes

On macOS, the Pro app uses one authenticated resident daemon through
`MootBridge`. App Intents, Widget and Share adapters, and LAN management use
that same client route. A caller is usable only after it has verified the
exact `FirstPartyProvider` 1.1.0 / ARIA v2 discovery tuple, including its
ordered capabilities and digest. Every stable call carries the verified
three-field compatibility record required by the provider interface.

iOS and iPadOS retain the embedded owner. Their `MootBridge` route invokes the
in-process ARIA dispatcher and they never acquire a macOS resident provider.

The frozen 35-operation Community contract, including
`moot_community_estate_inspect`, `moot_community_estate_create`,
`moot_community_estate_open`, `moot_community_estate_migrate`,
`moot_community_estate_recover`, and `moot_community_estate_cancel`, is
composed only on the verified authenticated first-party endpoint. Community
calls use their established grammar and do not carry the stable provider tuple.
The ordinary selected-v2 public MCP lane remains the 80-operation surface: it
neither lists Community names nor calls them, returning JSON-RPC
`methodNotFound` (`-32601`) for a Community name.

## 3. Recovery and authority

After a macOS transport failure, the client re-runs authenticated admission and
provider compatibility verification. A declared read retries once on the
replacement caller. A write whose response was lost returns the structured
ambiguous outcome `daemon-result-ambiguous` and is never replayed.

On macOS, `PortableServerController` owns the app-hosted `MootLANServer`
listener, its Bonjour advertisement, and its owner-presence bearer gate.
Permitted requests pass through `GatewayRuntime.lanBridge` to the
daemon-authenticated exportable-only session. The resident daemon owns the
default estate, `ProductDock`, and canonical execution authority; it does not
own the app listener or its bearer credential. The embedded iOS/iPadOS owner
may serve only while its app is active.

## 4. Activation gate

Before macOS helper activation, the app prepares and migrates its app-private
legacy estate into the canonical provider record. The readiness marker is
published atomically only after that preparation succeeds. Helper activation
must therefore not create an empty default estate in place of a migratable
app-private estate.

## 5. Validation boundary

This contract records focused authenticated HTTP composition and named
unit-test evidence in this checkout; it does not establish a general
source-wide validation result, a signed GUI, `SMAppService`, App Group, or
Keychain live smoke. Shipping iOS validation remains unproven: the latest
`SecTask` check has no retained transcript.
