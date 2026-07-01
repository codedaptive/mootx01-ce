# Schema status

**Status: locked for 1.0.**

As of the 1.0 line, the schema is locked. It is stable, versioned, and safe
to build against — the shape of the data will not shift underneath you.

## The commitment

From 1.0 onward, any change to the schema ships with the migration path that
carries existing data forward. There is no "breaking change and figure it out
later." A change lands one of two ways:

- **Inline migration** — the application detects an older schema on open and
  upgrades it in place, transparently, before use.
- **Upgrade utility** — where a change is too large to migrate silently, a
  dedicated upgrade tool performs the conversion as an explicit, reviewable
  step.

Either way, data created under 1.0 has a defined, supported route to every
later version. You will not be left to hand-edit stored data or rebuild it
from scratch.

## What "locked" means in practice

- Existing fields are not removed or redefined in place.
- Additive changes (new fields, new capabilities) remain allowed and do not
  require migration to keep older data readable.
- Any change that alters the meaning or storage of existing data is gated on
  shipping its migration — inline or via the upgrade utility — in the same
  release.
