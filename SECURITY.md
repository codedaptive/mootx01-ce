# Security Policy

MOOTx01 holds a person's memory and, in federated configurations,
mediates what one estate shares with another. If you find a problem
that touches that trust, please report it privately.

## Security by construction

This substrate does not bolt security on at the perimeter. The
properties that matter are carried by the atoms of the data model:

- **Every row is classified.** Sensitivity (`normal` through `secret`)
  and exportability (`private` or `public`) are adjectives bitmapped
  onto every row at write time, not labels applied by a layer above.
  Recall is constrained by them on every read.
- **Forbidden states are unreachable, not discouraged.** The substrate
  rejects forbidden adjective combinations at the write gate. A row
  that is `secret` and `public` is not a policy violation to be caught
  later; it is a state the system cannot represent.
- **The audit log is the substrate, not a sidecar.** Nothing is
  silently overwritten. Every change is an immutable event; audit rows
  can be tombstoned but never modified. State that cannot be replayed
  from the log is state the substrate refuses to produce.
- **Private by locality.** Memory lives where its owner puts it. There
  is no required cloud, no vendor account, and no server that sees the
  data unless the owner runs one.
- **Federation is bounded.** Cross-estate handshakes share what the
  grant names and nothing else, and aggregate queries carry formally
  bounded noise.

Understand the shape of the promise. This is a vault, not a cloak.
The substrate's job is to honor its owner's intention and not leak:
what you mark `secret` stays secret, what you mark `private` does not
cross the perimeter, and everything that happens is on the record. It
is not designed to obfuscate, anonymize, or conceal that information
exists. A system with those goals could be built on top of this
substrate, but that is not the purpose of this project. If your
deployment needs hardened, certified cryptography, ask about the
Enterprise Edition.

These are design invariants, not marketing. They are enumerated and
tracked in the [claims ledger](docs/validation/CLAIMS_LEDGER.md), and
the caveat in [Current posture](#current-posture) applies to all of
them.

## Reporting a vulnerability

**Do not open a public issue for a security problem.**

Use GitHub's
[Report a vulnerability](https://github.com/codedaptive/mootx01-ce/security/advisories/new)
form under this repository's Security tab, or email
<security@codedaptive.com>.

A useful report names the kit or lib affected, the version or commit,
and enough detail to reproduce what you observed.

## What counts

Anything touching the guarantees described above: data integrity, the
access perimeter (sensitivity, exportability, forbidden adjective
combinations), the federation trust boundary, and chain of custody.

## What to expect

This is a community edition maintained on a best-effort basis. We read
security reports, we work confirmed problems privately, and we disclose
once a fix has shipped. We are glad to credit reporters. There is no
bug bounty and no response-time guarantee.

## Current posture

This project is pre-1.0. The security review gate in the
[README](README.md) status tables has not yet run on any kit: build
status reflects functionality only, and nothing here has been hardened
or audited. The invariants above describe what the substrate is built
to guarantee; until the gate runs, evaluate them as designed and
claimed, not as certified.

## Supported versions

Only the tip of `main` is supported. There are no maintained release
branches before 1.0.
