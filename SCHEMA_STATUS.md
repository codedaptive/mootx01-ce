# Schema status

**Status: versioned, with a migration for every change. Current line: 1.1.**

The schema is stable and safe to build against. It is not frozen — it moves
when the product needs it to — but it never moves without carrying existing
data with it.

## The commitment

From 1.0 onward, any change to the schema ships with the migration path that
carries existing data forward. There is no "breaking change and figure it out
later." A change lands one of two ways:

- **Inline migration** — the application detects an older schema on open and
  upgrades it in place, transparently, before use.
- **Upgrade utility** — where a change is too large to migrate silently, a
  dedicated upgrade tool performs the conversion as an explicit, reviewable
  step.

Either way, data created under any released version has a defined, supported
route to every later version. You will not be left to hand-edit stored data or
rebuild it from scratch.

## What that means in practice

- Existing fields are not removed or redefined in place without a migration.
- Additive changes (new fields, new capabilities) remain allowed and do not
  require migration to keep older data readable.
- Any change that alters the meaning or storage of existing data is gated on
  shipping its migration — inline or via the upgrade utility — in the same
  release.
- An estate that needs a migration is not served until it has had one. The
  runtime refuses rather than reading it with the wrong assumptions.

## The 1.0 to 1.1 move

1.1 exercised the commitment rather than suspending it. Storage changed, and
the migration shipped in the same release. A 1.0 estate opened by 1.1 is
migrated before use; until it has been, `serve` refuses it.

Migration steps live in `packages/kits/GeniusLocusKit` as individually
compiled capsules — seven version steps from v1.0 through v1.10, plus two
layout steps that move older estates onto the catalog layout. Each is behind
its own package trait, and a consumer selects a migration floor rather than
naming steps one at a time; the floor enables every step that floor requires.
A step is historical code that never changes once shipped, which is what makes
an old estate still openable years later.
