# Kit / Lib documentation templates

Two templates that define the canonical shape of per-package
documentation in `docs/reference/`. Every Kit and Lib in
`packages/` is documented by a pair of files:

- **`<PACKAGE>_SPEC_v<X.Y>.md`** — the behavioral contract.
  Invariants, conformance requirements, error categories, the
  *what* and *why*. Language-agnostic. Stable across Swift and
  Rust ports.
- **`<PACKAGE>_INTERFACE_v<X.Y>.md`** — the API surface. Type
  signatures, method shapes, error enums, the *how to call it*.
  Per-language code blocks. Tracks the implementation.

The split exists so that an agent given a scoped task ("implement
X in KitY") can load only KitY's two files instead of the whole
substrate, and so the Rust port can be authored against the same
SPEC without re-deriving the contract.

## Templates

- [`KIT_SPEC_TEMPLATE.md`](KIT_SPEC_TEMPLATE.md) — copy this
  when starting a new SPEC document.
- [`KIT_INTERFACE_TEMPLATE.md`](KIT_INTERFACE_TEMPLATE.md) — copy
  this when starting a new INTERFACE document.

## Authoring rules

**SPEC owns:** the contract. Every behavioral promise, invariant,
and conformance requirement. The substantive content. If two
implementations of the same package both pass the SPEC, they are
interchangeable for callers.

**INTERFACE owns:** the syntax. Type signatures and method shapes
per language. Error enum cases. Test entry points. If the SPEC is
the law, INTERFACE is the courthouse — same content, formal
shape.

**No duplication.** Behavioral content lives in SPEC and is
referenced from INTERFACE by section number ("see SPEC § 4.2").
Signatures live in INTERFACE; SPEC may name a function but not
reproduce its signature. If the two disagree, SPEC wins and
INTERFACE is fixed in the same edit.

**Version coupling.** SPEC version drives INTERFACE version. When
SPEC bumps from v0.1 to v0.2, INTERFACE bumps in lockstep even
if the API surface is unchanged. This keeps the pair readable as
a unit.

## Naming conventions

| Pattern | Use |
|---|---|
| `<PACKAGE>_SPEC_v<X.Y>.md` | SPEC for a package |
| `<PACKAGE>_INTERFACE_v<X.Y>.md` | INTERFACE for a package |

PACKAGE is uppercase, matching the package directory name in
`packages/` (e.g., `LOCUSKIT_SPEC_v0.1.md`).

Cross-cutting specs that are not per-package (the protocol spec,
the architecture spec, the encoder spec) keep their existing
shapes and do not need an INTERFACE companion.
