---
title: Localization Guide
version: 1.0.0
status: implementation-grade specification
author: "MOOTx01 maintainers"
date: 2026-06-15
description: Localization rules for MOOTx01 view code — how display chrome is expressed through the localization system versus how runtime data is handled verbatim.
relates_to:
  - docs/reference/ARIA_LEXICON_SPEC.md
  - VERSIONING.md
---

# Localization Guide

This guide covers the localization contract for MOOTx01 view and UI code.
All display chrome goes through the localization system; runtime data content
stays verbatim.

---

## The Rule: String(localized:) for display chrome

Every user-visible string literal produced by a View or ViewModel that
constitutes display chrome — labels, button titles, placeholder text, section
headers, status descriptors — MUST be expressed through `String(localized:)`
in Swift (or the equivalent `tr!()` / locale-aware binding in Rust UI targets).

English is used as the key. No `.strings` catalog ships in the initial release,
but the infrastructure is in place so that adding a catalog later requires no
code changes.

```swift
// Correct — display chrome through localization:
Text(String(localized: "Recall"))
Button(String(localized: "Submit"), action: submit)

// Wrong — bare string literal in display position:
Text("Recall")
Button("Submit", action: submit)
```

---

## What counts as display chrome

Display chrome is any text the user reads as part of the application's own
UI — not content the user or the substrate produced. Examples:

- Tab bar labels
- Button titles
- Section and group headers
- Empty-state placeholders ("No results yet.")
- Error labels and status descriptors

---

## What does NOT go through localization

Model-driven text — results returned by the substrate, wire JSON, mapping
data, identifiers, log output — is content, not display chrome. It stays
verbatim. Wrapping substrate output in `String(localized:)` would corrupt
its meaning.

```swift
// Correct — substrate result is content, not a display literal:
Text(call.responseJSON)

// Wrong — would attempt to look up JSON as a locale key:
Text(String(localized: call.responseJSON))
```

---

## Ordinals, plurals, and dates

- All ordinals via `NumberFormatter` with `numberStyle = .ordinal`.
- All plural forms via `.stringsdict` entries (never manual `"\(n) item\(n == 1 ? "" : "s")"`).
- All dates via `DateFormatter` or `FormatStyle` — never raw ISO8601 strings
  in display positions.

---

## Layout direction

All layout uses semantic directions (`.leading`, `.trailing`). Geometric
directions (`.left`, `.right`) are forbidden in view code; they break RTL
layouts.

---

## AI prompts producing UI-visible text

When an AI prompt produces text that surfaces in the UI, the prompt must
include the target locale as a parameter. The substrate must not silently
assume English output.

---

## Changelog

| Version | Date | Description |
|---------|------|-------------|
| 1.0.0 | 2026-06-15 | Initial public guide, promoted from internal agent rule. |
