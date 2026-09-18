---
status: accepted
version: v0.4
description: Decides where the CLI family and the app family each store their estate catalog and how the two take over from each other without losing estate data.
question: Where does each install family keep its estate catalog, and how does one family take over an install from the other without losing the estate?
authors: MOOTx01 maintainers
date: 2026-09-09
relates_to:
  - docs/reference/GENIUSLOCUSKIT_SPEC.md  (§ ESTATE_CATALOG, § ESTATE_OPEN_POSTURE)
  - docs/reference/INSTALLER_INTERFACE.md  (census dispositions, migration receipt, arbiter state)
  - docs/decisions/DECISION_MOOTX01_FIRST_PARTY_AUTHENTICATED_WIRE_2026-08-16.md  (provider arbiter, descriptor, migration grant)
supersedes: none
context:
  - The estate catalog (2026-09-08) computes the configuration directory from the process home. A sandboxed app and its nested daemon helper have different per-app containers, so they could not share a catalog; the shared space of a signed family is its group container.
  - The daemon provider's census already names the group container canonical and keeps its lock and descriptor there; its resident mode has refused with exit 4 until estate routing lands (MACD-3). The catalog is that routing.
  - Both editions of the macOS app (Community and Pro) are sandboxed with the group entitlement whichever way they are downloaded; the CLI and the direct provider shell are not.
---

# Install takeover between the CLI family and the app family

## Decision

**Two homes, one rule.** The configuration directory is
`<home>/Library/Application Support/com.mootx01.ce`, where the home is the
user's home for an unsandboxed process and the group container
(`~/Library/Group Containers/<team>.group.com.codedaptive.mootx01`) for a
sandboxed one. The choice is a fact about the running process, read from the
sandbox, never a build flag and never an environment value. Each install has
exactly one catalog, and every member of a family resolves the same one.

**Who lives where.**

| Family | Members | Sandbox | Home |
|---|---|---|---|
| CLI | `mootx01`, its `serve` resident, moot-mgr, the direct Developer ID provider shell | no | the user's Library |
| App | the Community or Pro app and its nested provider helper, from the App Store or a signed download | yes, group entitlement | the group container |

**Source builds are unsandboxed by configuration** (Bob, 2026-09-08). The
project's Debug configuration, what a clone builds by default, turns App
Sandbox off and signs with an empty entitlements file, so a source-built app
is a member of the CLI family and shares `~/Library` with a CLI the same
person built. The Release configuration, what the release scripts and the
GitHub workflow build and Codedaptive signs, turns the sandbox on with the
group, Keychain group and iCloud entitlements, so the shipped app is a
member of the app family. No code detects who signed a build; the catalog
reads the sandbox fact at run time and the configuration decides the fact.
A fork that keeps the sandbox on signs with its own team and gets its own
group container; the identity library's constants are the vendor's and a
fork changes them once.

**The mover.** Membership in the group is an entitlement on a signed binary,
and current macOS prompts or denies a non-member that touches a group
container. The bare CLI is a non-member. The direct Developer ID provider
shell is both a group member and an unsandboxed citizen of the user's
Library: it is the only process that can see both homes, so it performs
every move between them. The CLI delegates the move to it exactly as the
ownership probe already delegates the group's Keychain and MAC work to the
signed bundle. The sandboxed side never reaches outside its container.

**The move.** One capsule, the general form of the catalog's declared
`moveDefault`: relocate the configuration directory from one home to the
other; rewrite the catalog's absolute paths for every record under the
default location; relocate each estate's Keychain key to the account of its
new path (`EstateOpenPosture.relocateKey`, key before file, as the layout
capsules do); verify the destination opens; then remove the source. Refuses
when both homes hold a catalog. Interruptible and resumable at any point.
Registered estates outside the default location are records only and do not
move.

**Forward takeover** (an app installed over a CLI install): the takeover
coordinator authenticates the standalone daemon's descriptor, warns the user
that the install is changing families, registers the nested helper, writes
the ownership preference; the standalone shell moves the home as its last
act and exits; the helper opens the catalog's active record in the group
container. The CLI's launch agents are left registered but the resident
finds no catalog in its home and reports the takeover instead of creating
an empty estate.

**Reverse takeover** (`mootx01 install` over an app install): the installer
reads the census, warns that the install is changing families, delegates
the move to the signed provider shell, registers the resident, and writes
the migration receipt. The app, on next launch, finds no catalog in the
group container and reports the takeover.

**Warnings.** Both installers detect the other family from the census and
warn before anything moves. Neither proceeds without the user's confirmation.

## The move, step by step

The home move is one capsule in the GeniusLocusKit migrations umbrella
(`GLKMigrationHomeMove`, beside the flat-layout and app-container capsules;
same trait floors, same retirement). It moves the configuration directory
`com.mootx01.ce` from a source home to a destination home. Only the direct
Developer ID provider shell runs it. It never runs while any server holds an
estate open: the caller stops the source family's resident first.

Inputs: the source home, the destination home. Both computed by the shell
(`MootProductIdentity.Storage.applicationSupportDirectory(homeDirectory:)`
over the user's home and over the group container its own entitlement
names), never from an argument or an environment value.

1. **Refuse ambiguity.** If the destination already holds
   `estatecatalog.json`, refuse and report both paths. Two catalogs is the
   user's decision, never a guess. If the source holds none, there is
   nothing to move; report that and stop.
2. **Load the source catalog.** Every record whose directory lies under the
   source's default location moves; a registered record outside it (an
   estate on another volume) is a path in the catalog and stays where it is.
3. **Relocate the keys first.** For every moving SQLite record whose file is
   ciphertext, `EstateOpenPosture.relocateKey(from: old databaseURL, to: new
   databaseURL)`: the key is stored under the account of the new path and
   only then removed from the old. Idempotent, so a run interrupted here
   resumes without loss. A plaintext estate has no key and nothing moves.
4. **Move the estate directories.** For each moving record, rename its
   directory into `<destination>/databases/<name>/`. Same volume, so each
   rename is atomic and no bytes are copied. A record already at the
   destination (an interrupted run) is skipped.
5. **Write the destination catalog.** `estatecatalog.json` at the
   destination with the default location and every record path rewritten
   under it; unmoved outside records keep their paths; the active record is
   unchanged. Written atomically.
6. **Verify.** Open every moved record's manifest through the catalog (name
   match, files inside the directory, regular files) and classify each
   database file; a ciphertext file must find its key under the new account.
   Any failure stops before step 7 with both catalogs intact and the report
   naming the record.
7. **Retire the source.** Move the daemon's sidecar state
   (`community-daemon/`) and moot-mgr's store (`moot-mgr/`) across the same
   way, then remove the source's `estatecatalog.json` and, if now empty, the
   source `com.mootx01.ce` directory. The source's launch agents stay
   registered; a resident that starts there finds no catalog and reports
   the takeover instead of creating an empty estate.
8. **Receipt.** The migration receipt (`MOOTX01-MIGRATION-RECEIPT-v1`) in
   the provider directory records the source and destination homes, every
   record moved, and the time.

Interruption at any step is resumed by running the capsule again: steps 3,
4 and 5 skip what is already done, step 1 sees a half-written destination
catalog only after step 5 has completed atomically, and the source catalog
is removed last.

**Forward takeover, in order.** The app's takeover coordinator authenticates
the standalone daemon's descriptor, warns the user that the install is
changing families, registers the nested helper and writes the ownership
preference. The standalone shell, on seeing the preference, stops serving,
runs the capsule from the user's Library to the group container, writes the
receipt and exits. The helper opens the catalog's active record in the group
container.

**Reverse takeover, in order.** `mootx01 install` reads the census, sees the
app family's catalog in the group container, warns the user, and delegates to
the signed provider shell, which runs the capsule from the group container to
the user's Library and writes the receipt. The installer then registers the
resident. The app, on next launch, finds no catalog in the group container
and reports the takeover.

## Consequences

- The community daemon's two private databases and hand-computed paths
  retire: it opens the catalog's active record once through GeniusLocusKit
  (effort 3 on the estate-catalog line).
- `mootx01 install` stops treating a flat 1.0.x estate as the only legacy
  layout; the census classes and the receipt remain the record of what moved.
- iCloud sync is gated by signing, not by the store or the sandbox: both
  editions of the signed app sync; the CLI family has no sync.
- Out of scope, recorded elsewhere: one Obsidian vault per wing (1.3
  roadmap, OPEN_ITEMS).

## Changelog

- v0.4 (2026-09-09): front matter gains the `description` field required by VERSIONING.md; no change to the decision.
- v0.3 (2026-09-08): the move written out step by step (refuse, load, keys first, rename, write, verify, retire, receipt), its resumption rule, and both takeover orders.
- v0.2 (2026-09-08): source builds unsandboxed by configuration; Release sandboxed and signed; the configuration, not a signer check, decides the family.
- v0.1 (2026-09-08): accepted shape from the estate-catalog line. Implementation is the fourth effort on that line; the installer interface and spec and the provider contract gain their sections when it lands.
