# MOOTx01 Community 1.1 frozen contract

This directory is the immutable integration input shared by the Community macOS application and the resident daemon. It freezes the observable wire required by `CONTRACT-01` through `CONTRACT-09` in `docs_internal/engineering/Version_1.1_Finalization_Assignments.MD`.

The contract does not assign storage algorithms, manager structure, watcher implementation, UI layout, or release packaging. It defines only what crosses the authenticated first-party MCP boundary and what both implementations must prove.

## Identity

- Contract identifier: `com.simple-machines.mootx01.community`
- Contract version: `1.1.0`
- Transport: authenticated first-party MCP `tools/call`
- Payload: JSON arguments and structured JSON result
- Fixture digest: SHA-256 over the canonical contract and fixture sources
- Compatibility: exact contract-version and fixture-digest equality

The resident daemon exposes `moot_community_contract_identity`. The application calls it after the existing descriptor, authentication, MCP initialize, initialized-notification, and ping gates, but before it attaches any Community feature port. A mismatch blocks all Community feature calls. Neither side negotiates down or installs a compatibility shim.

The pre-authentication readiness carrier remains the signed first-party daemon descriptor. The Community application projects that ceremony into these user-visible states: `unavailable`, `starting`, `ready`, `migrating`, `recovering`, `blocked`, `shuttingDown`, and `incompatible`. `ready` is not established until the identity method returns the exact version and digest in `fixture-bundle.sha256` and an estate identifier matching the authenticated descriptor.

## Files

- `contract.json` is the machine-readable endpoint, type, invariant, and scenario catalog.
- `fixtures/*.json` are deterministic request/result exchanges. They are examples and conformance vectors, not a fake implementation script.
- `fixture-bundle.sha256` is the frozen identity of `contract.json` and every JSON file under `fixtures/`.
- `verify_contract.py` validates the catalog, every fixture payload, mandatory scenario coverage, and the stored digest using only the Python standard library.

## Wire rules

1. Requests and results are JSON objects. Integers must be exactly representable as signed 64-bit values. Counts are non-negative.
2. UUIDs use the canonical hyphenated textual form. Dates use UTC RFC 3339/ISO 8601 with a trailing `Z`. URLs are absolute. Bookmarks are base64 strings and are opaque to the application.
3. Every object rejects unknown fields unless its type explicitly opts into additional fields. Unknown methods are MCP method-not-found errors. Unknown enum values, missing required fields, malformed values, or structurally invalid combinations fail closed.
4. `reason` values are bounded codes from `reasonCodes` in `contract.json`. They are safe for user-facing mapping and logs. Raw SQL, paths not deliberately selected by the user, keys, credentials, arbitrary exception text, and database contents never cross this boundary.
5. IDs and tokens are opaque. The application may compare them for equality and preserve them across reconnects; it must not parse or regenerate them.
6. Mutating retries use the same request, action, session, plan, or job identity. Exact retry is idempotent. A conflicting retry returns a typed refusal and never applies a second mutation.
7. Plan-before-mutation is structural. Import/export planning performs no estate mutation or final export write. Execute accepts only a current daemon-issued `planToken` whose plan said `executionPermitted: true`.
8. Privacy is canonical daemon state. `sensitivity`, `exportEligible`, and `lanEligible` are independent inputs, but the daemon may only narrow them. Export, Obsidian, and LAN paths re-evaluate current policy and never expose ineligible material.
9. A daemon-level MCP error is reserved for transport/protocol failure. An understood Community request returns the typed result shape for its endpoint, including refusals and failures.

## Shape grammar

`contract.json` uses a deliberately small schema language so Swift, Rust, shell, and model-driven work can consume the same file without a generator dependency.

- A primitive is named by a string such as `uuid`, `date-time`, `nonempty-string`, `boolean`, or `nonnegative-integer`.
- `TypeName[]` is an array of a named or primitive type.
- A `record` declares exact fields. A key ending in `?` is optional.
- An `enum` declares its complete string vocabulary.
- A `union` declares a discriminator and the exact fields for each discriminator value. `commonFields` apply to every variant.
- Endpoint `arguments` and `result` refer to named types. Empty argument objects are the `Empty` type.

The verifier is the executable definition of this grammar.

## Cross-field invariants

The type grammar validates shape; these invariants define semantic validity:

- An estate or daemon identity in a result must match the authenticated descriptor and the request where an identity was supplied.
- Migration `completedUnits` is between zero and `totalUnits`, inclusive, and both values refer to the same plan and operation across refreshes.
- Capture choices contain the default destination and sensitivity. A capture receipt contains the daemon's full effective destination and policy. Exact retry of a request ID returns the original receipt; a different payload with that ID is refused as `request-conflict`.
- Review dashboards contain each of `morning`, `endOfDay`, and `weekly` exactly once. Session kind matches the request. Session, action, duplicate-group, and receipt identities are stable. Section and item arrays retain daemon order. Reversal is accepted only while `reversalAvailable` is true.
- Obsidian `pendingCount` and `totalCount` either both appear or both do not. `pendingCount <= totalCount`. Checkpoint fields may accompany every state and remain independently queryable; absence is not converted to a zero checkpoint. Retry succeeds only when the prior state was retryable.
- Transfer plan and count fields are non-negative. `estimatedTransferCount + policyExclusionCount <= candidateCount`. Returned job ID equals the queried ID. Progress satisfies `processed <= total`. A completed job has a non-empty receipt. Cancellation counts describe committed work and are never presented as complete success.
- LAN counts are non-negative. An active state and a successful start contain the actual endpoint and authentication state. `stopped` is returned only after serving has ceased. Ineligible material is absent from every serving response path, not merely hidden from counts.

## Ownership

The contract branch owns only `contracts/community/1.1/**`. Apple implementation branches consume it while modifying only Apple-owned paths. Daemon implementation branches consume it while modifying only daemon/core-owned paths. A contract change requires a new version and fixture digest; it is never folded silently into an implementation branch.

## Verification

From the repository root:

```sh
python3 contracts/community/1.1/verify_contract.py
```

The command prints the contract version, endpoint count, fixture count, scenario coverage, and verified digest. It performs no network or estate mutation.
