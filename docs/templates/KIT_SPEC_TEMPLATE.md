---
title: <PackageName> Specification
version: MAJOR.MINOR.PATCH
status: draft | review | active | deprecated | superseded
date: <YYYY-MM-DD>
description: One-sentence statement of what <PackageName> is and the contract this spec defines.
spec_type: kit | protocol | encoder
authors: MOOTx01 maintainers
relates_to:
  - docs/reference/<PACKAGE>_INTERFACE.md   # the API surface this spec contracts
  - docs/engineering/<MASTER>.md            # cross-cutting rules this package obeys
superseded_by: docs/reference/<replacement>.md   # only when status: superseded
---

# <PackageName> Specification

<!--
TEMPLATE INSTRUCTIONS (delete this block when filling in):

This is the behavioral contract for <PackageName>. It says what
the package promises to callers, what invariants it enforces,
and what an implementation must do to be conforming. It does NOT
contain type signatures or per-language code — those live in the
companion INTERFACE document.

Filling this stub:
1. Replace placeholders:
   - <PackageName> → CamelCase identifier (e.g., LocusKit)
   - <PACKAGE>     → UPPERCASE filename stem (e.g., LOCUSKIT)
   - <Kit | Lib>   → Kit or Lib (matches frontmatter `kind:`)
   - <kits|libs>   → kits or libs (matches the Packages/ subdir)
2. Fill in each § N section. Keep the section numbers; an agent
   walking the code uses them as anchors.
3. Cite SPEC sections from INTERFACE by number ("see SPEC § 4.2").
4. Behavioral claims belong here. Function signatures do not.
5. If a section genuinely does not apply, leave a one-line note
   saying so rather than deleting the section. The shape of the
   document is itself part of the contract.

Source of truth at fill time:
  packages/<kits|libs>/<PackageName>/Sources/<PackageName>/
-->

## § 1 — What this package is

<!-- One or two prose paragraphs. Who calls this kit, what it
does for them, where it sits in the kit graph. -->

This package is a **<Kit | Lib>**: <one-line reason — managed
state and lifecycle / pure functions, no managed state>.

## § 2 — Scope

This specification defines:

- <bulleted list of what is in scope>

This specification does NOT define:

- API signatures — those live in `<PACKAGE>_INTERFACE.md`
- <other excluded concerns, with pointers to where they live>

## § 3 — Position in the kit family

<!-- Show dependencies (what this package imports) and consumers
(who imports this package). A small diagram or a bulleted list. -->

```
<dependency tree fragment showing where this package sits>
```

**Depends on:** <list of upstream packages>

**Consumed by:** <list of downstream packages>

## § 4 — Invariants

<!-- Constitutional rules. Things that must hold for every
conforming implementation, every call, every state. Numbered so
they can be cited from elsewhere. -->

**I-1:** <Statement.>

**I-2:** <Statement.>

## § 5 — Behavioral contracts

<!-- Promises the package makes to callers beyond signatures.
Things like ordering, idempotency, atomicity, performance
guarantees, side-effect rules. -->

**B-1:** <Statement.>

**B-2:** <Statement.>

## § 6 — Error model (conceptual)

<!-- The categories of errors the package raises and what they
signal. Describe the *meaning* of each category. The concrete
enum cases and their per-language shapes live in INTERFACE. -->

| Category | Trigger | Recovery posture |
|---|---|---|
| <category-name> | <what causes it> | <retry / abort / surface> |

## § 7 — Conformance requirements

<!-- What an implementation must satisfy to be conforming. These
are the testable propositions. They become entries in the
conformance harness. -->

**C-1:** <Statement.>

**C-2:** <Statement.>

## § 8 — Out of scope

<!-- Things that look like they might belong here but live
elsewhere. Each entry points at where the concern actually
lives. -->

- <concern> → see `<OTHER_PACKAGE>_SPEC.md`

## § 9 — Open questions

<!-- Optional. List unresolved questions and link to the open-
questions doc if applicable. Delete this section if there are no
open questions. -->

- <question>

---

*End of <PackageName> Specification.*
