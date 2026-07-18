---
mission: MX-TAB-3
title: ContentKind dataset=7 blast radius
date: 2026-07-11
status: complete
---

# Blast Radius Report — MX-TAB-3

Adding `ContentKind.dataset = 7` (Swift) / `ContentKind::Dataset = 7` (Rust) to the
LocusKit operational-bitmap content_kind field (bits 6–11).

---

## Step 0 — Baseline

LocusKit Swift suite at mission start: 799 tests, **3 pre-existing
failures** introduced at commit `39c274fe` (files last touched there;
unrelated to ContentKind — verified by Adams post-flight). The mission's
pass criterion is therefore "no NEW failures," with the 3 known failures
carried unchanged. All other touched packages started green.

Post-flight amendments (Adams findings, applied same-day): stale
`content_kind (contiguous raw 0…6)` range comments updated to `0…7` in
`packages/kits/LocusKit/Sources/LocusKit/EstateVerbs.swift` and
`packages/kits/LocusKit/rust/src/estate_verbs.rs` (two sites) — these
files switch over `MutationKind`, not `ContentKind`, so they carried no
code change, only the bitmap-layout comment.

## Files Modified

### Enum definition — both legs

| File | Site | Arm Behavior |
|---|---|---|
| `packages/kits/LocusKit/Sources/LocusKit/DrawerOperational.swift` | `ContentKind` enum definition | Add `case dataset = 7` with comment; update doc counts (7→8 used, 57→56 reserved) |
| `packages/kits/LocusKit/rust/src/drawer_operational.rs` | `ContentKind` enum + `from_raw()` | Add `Dataset = 7`; add `7 => ContentKind::Dataset` arm; update reserved comment 7–63 → 8–63 |

### Vocabulary write-gate

| File | Site | Arm Behavior |
|---|---|---|
| `packages/kits/LocusKit/rust/src/vocabulary.rs` | `content_kind` FieldSlot valid values | `&[0,1,2,3,4,5,6]` → `&[0,1,2,3,4,5,6,7]` |

### Exhaustive label/value helpers — Swift

| File | Site | Arm Behavior |
|---|---|---|
| `packages/kits/CognitionKit/Sources/CognitionKit/AssociationRules.swift` | `contentKindLabel(_:)` exhaustive switch (line ~255) | `case .dataset: return "kind:dataset"` |
| `packages/kits/CognitionKit/Sources/CognitionKit/FormalConcepts.swift` | `contentKindValue(_:)` exhaustive switch (line ~320) | `case .dataset: return "dataset"` |

### Exhaustive label/value helpers — Rust

| File | Site | Arm Behavior |
|---|---|---|
| `packages/kits/CognitionKit/rust/src/association_rules_recipe.rs` | `content_kind_label()` exhaustive match | `ContentKind::Dataset => "kind:dataset"` |
| `packages/kits/CognitionKit/rust/src/formal_concepts_recipe.rs` | `content_kind_value()` exhaustive match | `ContentKind::Dataset => "dataset"` |
| `packages/kits/CognitionKit/rust/src/latent_themes_recipe.rs` | `kind_label()` exhaustive match | `ContentKind::Dataset => "dataset"` |

### Lens tool decoders (MCP surface)

| File | Site | Arm Behavior |
|---|---|---|
| `packages/kits/AriaMcpKit/Sources/AriaMCP/LensTools.swift` | `decodeContentKind(_:)` non-exhaustive switch | Add `case "dataset": return .dataset`; add rejection guard at `moot_lens_anticipate` call site with MX-TAB-6 message |
| `packages/kits/AriaMcpKit/rust/src/lens_tools.rs` | `decode_content_kind()` non-exhaustive match | Add `"dataset" => Some(ContentKind::Dataset)`; add rejection guard at `moot_lens_anticipate` arm with MX-TAB-6 message |
| `packages/kits/AriaMcpKit/rust/src/tool_list.rs` | `moot_lens_anticipate` `targetKind` schema description | Add "dataset" to the enumerated kinds — mirrors the `LensTools.swift` schema-description update for cross-leg tool-schema parity |

### Conformance parity anchors

| File | Site | Arm Behavior |
|---|---|---|
| `packages/kits/LocusKit/Tests/LocusKitTests/DrawerOperationalTests.swift` | `contentKindRawValues()` test | Add `#expect(ContentKind.dataset.rawValue == 7)`; update test description |
| `packages/kits/LocusKit/Tests/LocusKitTests/OperationalBitmapConformanceTests.swift` | `contentKindTable` | Add `(.dataset, 7)` entry |
| `packages/kits/LocusKit/rust/tests/operational_bitmap_conformance.rs` | `CONTENT_KIND_TABLE` | Add `(ContentKind::Dataset, 7)` entry |

### Cookbook

| File | Site | Arm Behavior |
|---|---|---|
| `docs/engineering/GENIUSLOCUS_ENGINEERING_COOKBOOK.md` | §2.4 `content_kind` field | Add `7=dataset (NEW, MX-TAB-3)`, change `7–63 reserved` → `8–63 reserved`; bump version 1.1.0 → 1.2.0 |

---

## Defaulted Switches Inspected

| File | Site | Verdict |
|---|---|---|
| `packages/kits/AriaMcpKit/Sources/AriaMCP/ToolDispatch.swift` | `decodeContentKind()` for `moot_file_memory` — `default: throw "Unknown content kind: ..."` | INTENTIONALLY_LEFT — dataset drawers cannot be created via `moot_file_memory`; error arm is correct behavior at this stage |
| `packages/kits/AriaMcpKit/rust/src/interface_tools.rs` | `decode_content_kind_arg()` for `moot_file_memory` — `other => Err(...)` | INTENTIONALLY_LEFT — same rationale; error arm is correct for dataset |

---

## Cookbook Decision

The CE repo carries `docs/engineering/GENIUSLOCUS_ENGINEERING_COOKBOOK.md` at a bare
filename (per the CE versioning convention — no version suffix in filename). The
substrate-reference versioned path does not exist in this repo. §2.4 updated in this
file with the `dataset` row and a minor version bump (1.1.0 → 1.2.0, additive change).

---

## MUST_UPDATE Resolution

All sites are resolved in this mission. No deferrals.

Binary `== Code` comparison paths in FDC intake:
- `packages/kits/GeniusLocusKit/Sources/GeniusLocusKit/EncodeIntake.swift` — uses
  `frame.kind == .code` binary comparison; `dataset` falls to `FdcContentKind::text`.
  This is correct per spec: the FDC classifier never emits dataset, and `moot_reclassify_fdc`
  passes dataset handles through untouched. No switch; no modification needed.
- `packages/kits/GeniusLocusKit/rust/src/intake.rs` and `coordinator.rs` — same pattern,
  same verdict.

VaultKit paths:
- `packages/kits/VaultKit/rust/src/palace_bridge.rs` — direct `ContentKind::Prose`
  assignment, no switch; no modification needed.
- `packages/kits/VaultKit/rust/src/drawer_mapping.rs` — `content_kind().raw_value()`
  accessor call, no switch; no modification needed.

---

## Parity Constraint

Every Swift change in this report has a corresponding Rust change. Both legs ship
together per the Swift/Rust parallel implementation contract. No Swift-only deliverable.
