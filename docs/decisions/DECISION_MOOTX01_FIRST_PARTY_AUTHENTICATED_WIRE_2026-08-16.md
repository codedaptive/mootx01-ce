---
status: decided
question: How does a first-party MOOTx01 application prove it is talking to the genuine resident daemon, and the daemon prove the caller is a genuine first-party client?
authors: MOOTx01 maintainers
date: 2026-08-16
relates_to:
  - docs/reference/ARIA_MCP_SPEC.md
  - docs/reference/ARIA_MCP_INTERFACE.md
  - docs/reference/vectors/ARIA_MCP_FIRST_PARTY_AUTH_V1.json
supersedes: none
context:
  - MACD-1 shipped a dark readiness client bound by assertion, not proof
  - MACD-2a proved cross-install App Group and data-protection Keychain custody
  - The resident daemon's existing HTTP lane is unauthenticated by design for CE
  - Production routing still runs through the embedded bridge and is unchanged
---

# First-party authenticated wire

## Context

The resident daemon serves one loopback HTTP lane, unauthenticated. That is a
deliberate and documented posture for the Community third-party lane: the
clients are Cursor, Claude Code, and similar MCP hosts, none of which can verify
a server's identity, and the residual attacker — same-user code execution — can
already read the estate directly.

The first-party applications are a different case. They are signed by the same
team as the daemon, they can hold a shared credential in the data-protection
Keychain, and they are about to be asked to route *all* estate traffic through
the daemon rather than an embedded bridge. Before that conversion, the app must
be able to tell the genuine daemon from anything else that manages to hold port
4242, and the daemon must be able to tell a first-party caller from any other
same-user process that can open a socket.

MACD-1 built the readiness client but bound gates 2 and 3 by **assertion**: the
authenticator stated that it had authenticated, and the daemon stated its own
instance and estate identifiers. Anything able to answer on the endpoint could
therefore claim whatever the descriptor named. MACD-1 stayed dark precisely so
that gap lived in unrouted infrastructure.

MACD-2a then established the missing premise empirically: bundles from different
install channels, provisioned by the same team, resolve the identical App Group
container and can exchange data through the same fully expanded
data-protection-Keychain access group. A shared installation root is therefore
available to both halves.

## Decision

Add a **second HTTP lane**, at exactly `http://127.0.0.1:4242/mcp/first-party`,
carrying mutual authentication and per-message integrity. The existing
third-party lane is untouched.

Eight choices carry the argument. Each is recorded with the alternative it
rejects, because the rejected option is in every case the one that looks
simpler.

### 1. A hand-rolled length-prefixed binary encoding, not JSON

A MAC is only as strong as the agreement on what was MACed. JSON specifies no
canonical key order, number form, or string escaping, so two conforming
serializers can agree on meaning and disagree on bytes — and a MAC computed over
one then fails against the other.

**Rejected:** canonical JSON (JCS). It exists, but it would add a dependency and
a second specification to conform to, in a place where a 40-line encoder is
fully determined by the field list.

**Rejected:** delimiter concatenation. `"a" ‖ "bc"` and `"ab" ‖ "c"` produce
identical bytes, so a MAC over the concatenation authenticates neither field.
An attacker controlling two adjacent fields could move the boundary between them
without changing the MAC input. A UInt32 length before every variable-length
field removes the boundary from attacker control.

### 2. A three-rung derivation ladder, not the installation root directly

`K_install` is long-lived. Using it to authenticate individual requests would
make its exposure window the lifetime of the install, and would mean one
compromised operation yields the credential for all of them.

Instead: `K_descriptor` (descriptor integrity, salt = the RFC 5869 omitted-salt
value, because it must be derivable *before* any descriptor is verified — it is
what verifies them); `K_auth` (handshake, salt = descriptor digest, so a proof
cannot be replayed against a different descriptor); `K_session` (per-session
request and response MACs, salt = SHA-256 of the transcript, so no two
handshakes share a session key). Each rung has a distinct HKDF `info` domain, so
no two can collide.

**Rejected:** the audit's original proposal of using the installation key
directly for request MACs. Kong's binding decision 1 refused it, and this
implements that refusal.

### 3. The request MAC covers method, path, and content type — not just the body

A MAC over the body alone authenticates the payload but not the operation. A
signed body could be replayed against a different verb or a different route.
The body is included as a SHA-256 digest rather than inline so the MAC input
stays bounded regardless of payload size.

Responses are MACed too, over the status, content type, request sequence, and
body digest. Without that, a peer could downgrade an authenticated 200 to a 401,
or replay one response as the answer to a different request.

**Rejected:** the audit's session-id + sequence + body MAC. Incomplete on both
counts.

### 4. Distinct domains on every keyed operation

Server proof, client proof, establishment proof, request MAC, and response MAC
each carry a distinct domain prefix. Without this, one construction's output is
a valid input to another — which is exactly the reflection attack: a peer echoes
the server's proof back and it authenticates as the client's.

### 5. A replay window, not a strict counter

A strict "must exceed the last" counter is simpler and cannot tolerate
concurrency: two requests issued in order can arrive out of order, and the
later-arriving earlier sequence would be refused as a replay. The window is a
highest-seen value plus a 128-bit history, so genuine out-of-order arrivals
inside a bounded history are admitted while duplicates and anything too old to
adjudicate are refused.

**Replay state is committed only after the request MAC verifies.** Admitting a
sequence on an unverified request would let an unauthenticated peer burn a
legitimate client's sequence numbers and lock it out — a denial of service
reachable without any credential at all.

Sequence exhaustion revokes the session rather than wrapping. Wrapping would
restart inside the window and make every subsequent request look like a
duplicate: a session that silently stops working instead of failing cleanly.

### 6. Bounded tables that refuse rather than evict

At most 128 outstanding challenges and 64 live sessions. Expired entries are
removed before capacity is judged, so a table full of dead entries never refuses
a live peer. At genuine capacity the server **refuses** rather than evicting.

**Rejected:** LRU eviction. Eviction under load lets an attacker flush a
legitimate peer's session by flooding — the table's bound becomes an attack
primitive rather than a defence.

The descriptor digest is verified *before* any challenge state is allocated, so
a peer that cannot name the active descriptor cannot consume a bounded slot.

### 7. A private strict parser for the authenticated lane

`LoopbackHTTP.HTTPRequest` is lossy in two ways: duplicate header lines collapse
last-wins, and values are trimmed with Unicode whitespace rather than the ASCII
SP/HTAB the grammar allows. Both are fine for the third-party lane. Neither is
acceptable where a header carries a MAC: a duplicated authentication header
becomes invisible rather than refusable, and the value a consumer compares is not
necessarily the value that arrived.

The first-party lane therefore parses its own requests with a strict, lossless,
duplicate-preserving parser that also refuses obsolete line folding, bare LF
line endings, `Content-Length`/body mismatch, duplicate `Content-Length`, and
`Transfer-Encoding` — the request-smuggling primitives, which matter precisely
when two parsers disagree.

**Rejected:** changing `LoopbackHTTP`. It is shared with the third-party lane and
with moot-mgr, and the risk of a subtle regression there outweighs the
convenience.

**Rejected:** accepting the collapse and documenting that the MAC authenticates
the resulting values. That argument is *true* — every MAC-covered field is bound
by value, and with a single parser and no proxy there is no smuggling-style
disagreement to exploit. It was rejected anyway, because it would make the
duplicate-header check assert a condition the live path can never produce: a
test that passes for a reason unrelated to the property it names.

### 8. Fail-closed compatibility with honest user-facing states

Schema, auth protocol, contract revision, and MCP version must match exactly and
are never negotiated down: security properties do not degrade gracefully. The
daemon binary version must lie in `[1.0.0, 2.0.0)` and must equal the
authenticated `serverInfo.version`.

Outside the range the client produces an **action**, not a refusal: below it,
Update Daemon; at or above it, Update App. The client never stops, downgrades, or
works around a newer daemon — it presumes the daemon correct and itself stale.
Reporting "incompatible" when the real answer is "update the daemon" is a
readiness state that lies by omission.

The endpoint is compared **whole**. A URL can satisfy scheme, host, and port
individually while carrying a query, a fragment, userinfo, or a different path,
and each of those reaches something other than the contracted endpoint. The IPv6
loopback alternate is refused for the same reason: the lane pins one spelling so
a peer cannot pick another and still pass every component check.

The client follows **no redirects**. `URLSession` follows them by default, which
would let a peer answer the one contracted endpoint with a 3xx and have the
request re-issued elsewhere — immediately after the URL check passed, which is
the one moment the pin is supposed to matter.

## What this decision does NOT do

- It does not mint a production installation root. MACD-2c supplies the
  exclusive provider lock; a root minted before an arbiter exists is a
  credential with no owner.
- It does not publish a descriptor, elect a provider, or register a service.
- It does not route any production traffic. The 14 `GatewayRuntime.shared.bridge()`
  call sites are unchanged, and no shipping build configures the lane — with the
  authenticator nil, the entire subtree 404s and the capability is never
  advertised.
- It does not implement the protocol in Rust. Per the parity boundary, Rust
  verifies the golden vectors and must not advertise or partially implement the
  runtime protocol; a full port is a separate parity mission against the frozen
  vectors.

## Empirical results

- Swift: 27 protocol cases, 30 server-lane cases, 9 socket-level cases, 9
  client cases, plus the descriptor and readiness suites.
- Rust: 8 cases, recomputing every published vector from the field inputs with
  hand-written RFC 2104 and RFC 5869 implementations over `sha2`. RFC test
  vectors are asserted first so a primitive fault is diagnosed as itself.
- Cross-language agreement on every byte of the canonical descriptor, the
  transcript, all three derived keys, all three proofs, every request MAC, and
  every response MAC, including the negative one-bit mutations.

## Status

Decided and implemented, dark. Production routing awaits MACD-2c (signed daemon
artifact, provider arbiter, descriptor publication, estate migration) and MACD-3
(atomic routing conversion).
