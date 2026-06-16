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

## What this does not defend against

Limits as plainly as possible.

**Your machine is the boundary.** An estate is a local database file
owned by your user account. Any process running as you can read that
file directly: a malicious app, a compromised tool, a person at your
unlocked keyboard. None of the application controls (sensitivity
tiers, export gates, receipts) defend against code already running on
your machine. At that level the protections are the operating
system's: file permissions, FileVault, and your own judgment about
what you install. The committed exception is encryption at rest for
`secret` rows under a key only you hold, scheduled for the v1.x
series. That is the one layer built to survive a hostile local
process. Until it ships, `secret` means excluded from recall and from
every bulk channel. It does not mean unreadable on disk.

**The AI reads what you let it recall.** This is a knowledge engine.
Anything the AI can recall can leave through a conversation, slowly
and one context at a time. No memory product can prevent that and
remain useful. What the substrate controls is the bulk path: mass
export is gated by tier, private content requires its owner present,
and every bulk operation writes a receipt. The goal is that fast,
lossless, silent egress is impossible. A slow trickle is the cost of
having a useful engine, and the audit trail is how you see one.

**The gates protect the owner's front door.** Export gating, owner
key prompts, and receipts exist to stop a legitimate install from
being driven into bulk egress by a compromised agent, a bad
configuration, or an accident. They are not a defense against someone
who already owns the machine. Seatbelts, not armor plate.

## Verifying your binary

This is open source. Anyone can build a version with the locks
removed, and a modified build sees only the data on machines where
someone chooses to run it. What you can verify is that the build you
installed is the one we shipped:

- Release artifacts publish SHA-256 checksums in `checksums.txt`
  alongside each release. The installer verifies them before
  extraction. You can check by hand with `shasum -a 256`.
- macOS binaries are Developer ID signed and notarized. Verify with
  `codesign --verify` and `spctl --assess`.

If the checksum or signature does not match, the binary is not ours.
Nothing in this document applies to it.

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

This project is in beta (pre-1.0). The security review gate in the
[README](README.md) status tables has not yet run on any kit: build
status reflects functionality only, and nothing here has been hardened
or audited. The invariants above describe what the substrate is built
to guarantee; until the gate runs, evaluate them as designed and
claimed, not as certified.

## Supported versions

Only the tip of `stable/1.0.x` (the default branch) is supported. There
are no other maintained release branches during the beta.


