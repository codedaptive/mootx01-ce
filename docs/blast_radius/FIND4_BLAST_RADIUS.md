# Blast Radius Report — FIND4

**Baseline:** swift test pass counts at mission start:
- LocusKit Swift: 806
- AriaMcpKit Swift: 495
- LocusKit Rust: 875
- AriaMcpKit Rust: 413

**Mission:** Fix confirmed finding #4 — tunnel lifecycle model not enforced
on active-read + MCP disclosure paths (proposed/withdrawn/superseded tunnels
leak to AI clients as if active).

**Symbols being changed:**

## Symbol 1: DrawerStore.allActiveTunnels (Swift)

**Change class:** semantic — filter currently excludes only `isRetired`; adding
`lifecycle == .active` requirement  
**Scope:** public  

**Caller audit:**

All callers want only confirmed-active (lifecycle==.active) tunnels. The method
name "allActiveTunnels" already implies lifecycle==active; the existing filter
was incomplete.

Callers:
1. `Estate.allActiveTunnels()` — pass-through wrapper, passes the stronger
   semantics to its callers (class is MUST_UPDATE for comment/docstring update)
2. `GeniusLocusKit.DreamingReads.allActiveTunnels(in:)` — pass-through to
   estate; used by `EstateDreamingReader.dreamedActiveTunnels()` which
   fetches dreamed tunnels for OMEGA retirement evaluation. OMEGA must only
   retire confirmed-active tunnels (lifecycle==active), not pending-proposed
   or withdrawn ones. Adding the lifecycle filter is semantically correct here.
3. `NeuronKit.EstateDreamingReader.dreamedActiveTunnels()` — calls
   `allActiveTunnels` then filters to `isDreamed == true`. No call-site
   change needed; benefits from the stronger filter in the callee.

**Decision: Option (a) — add lifecycle==active filter INSIDE allActiveTunnels.**

Justification: every caller semantically wants only lifecycle==active tunnels.
The dreaming pipeline's OMEGA retirement path should never retire a proposed or
withdrawn tunnel. The name "allActiveTunnels" implies lifecycle==active. Adding
the filter here corrects the contract without requiring per-caller fixes.

### Call sites

| File | Line | Source | Classification | Justification (if INTENTIONALLY_LEFT) |
|---|---|---|---|---|
| LocusKit/Sources/LocusKit/DrawerStore.swift | 2112 | grep | MUST_UPDATE | The filter line |
| LocusKit/Sources/LocusKit/Estate.swift | ~line near allActiveTunnels | grep | MUST_UPDATE | Docstring update to state lifecycle==active |
| GeniusLocusKit/Sources/GeniusLocusKit/Brain/DreamingReads.swift | near allActiveTunnels(in:) | grep | MUST_UPDATE | Docstring update |
| NeuronKit/Sources/NeuronKit/Dreaming/EstateDreamingReader.swift | ~78 | grep | INTENTIONALLY_LEFT | Caller — no change needed; benefits from callee's stronger filter |

### Summary
- MUST_UPDATE: 3 sites (DrawerStore filter + 2 docstring updates)
- INTENTIONALLY_LEFT: 1 (EstateDreamingReader — caller only)
- RESCOPE_REQUIRED: 0

---

## Symbol 2: DrawerStore.all_active_tunnels (Rust, default impl)

**Change class:** semantic — same as Swift counterpart  
**Scope:** public (trait default method)  

Callers mirror the Swift callers exactly (parity requirement):
1. `estate_verbs.rs all_active_tunnels` — pass-through
2. `coordinator.rs all_active_tunnels` — pass-through
3. `estate_dreaming_reader.rs new()` — uses `all_active_tunnels` in the
   `dreamed_active` snapshot; same OMEGA reasoning as Swift applies

**Decision: Option (a) — add lifecycle==Active filter inside the default impl.**

### Call sites

| File | Line | Source | Classification | Justification (if INTENTIONALLY_LEFT) |
|---|---|---|---|---|
| LocusKit/rust/src/drawer_store.rs | 771-777 | grep | MUST_UPDATE | Filter body |
| LocusKit/rust/src/estate_verbs.rs | callers | grep | INTENTIONALLY_LEFT | Pass-through; no change needed |
| GeniusLocusKit/rust/src/coordinator.rs | callers | grep | INTENTIONALLY_LEFT | Pass-through; no change needed |
| NeuronKit/rust/src/estate_dreaming_reader.rs | ~83 | grep | INTENTIONALLY_LEFT | Caller only; benefits from callee's stronger filter |

### Summary
- MUST_UPDATE: 1 site
- INTENTIONALLY_LEFT: 3 (pass-throughs / callers)
- RESCOPE_REQUIRED: 0

---

## Symbol 3: ToolDispatch.runConnectionSearch / runConnectionMap (Swift)

**Change class:** semantic — filter does not gate on lifecycle; adding
`lifecycle == .active` requirement at MCP disclosure boundary  
**Scope:** internal (ToolDispatcher extension)  

These two functions call `estate.allTunnels()` (not allActiveTunnels) and
filter manually. The lifecycle gate must be added to each filter expression.

### Call sites

| File | Line | Source | Classification | Justification (if INTENTIONALLY_LEFT) |
|---|---|---|---|---|
| AriaMcpKit/Sources/AriaMCP/ToolDispatch.swift | 1959-1962 | grep | MUST_UPDATE | runConnectionSearch filter |
| AriaMcpKit/Sources/AriaMCP/ToolDispatch.swift | 1980-1983 | grep | MUST_UPDATE | runConnectionMap filter |

### Summary
- MUST_UPDATE: 2 sites
- INTENTIONALLY_LEFT: 0
- RESCOPE_REQUIRED: 0

---

## Symbol 4: run_connection_search / run_connection_map (Rust, interface_tools.rs)

**Change class:** semantic — same as Swift counterpart  
**Scope:** crate-private (fn)  

### Call sites

| File | Line | Source | Classification | Justification (if INTENTIONALLY_LEFT) |
|---|---|---|---|---|
| AriaMcpKit/rust/src/interface_tools.rs | 1497-1504 | grep | MUST_UPDATE | run_connection_search filter |
| AriaMcpKit/rust/src/interface_tools.rs | 1553-1558 | grep | MUST_UPDATE | run_connection_map filter |

### Summary
- MUST_UPDATE: 2 sites
- INTENTIONALLY_LEFT: 0
- RESCOPE_REQUIRED: 0

---

## DO NOT TOUCH — LensTools.swift contradiction path

The contradiction lens at LensTools.swift lines 495-498 ALREADY gates lifecycle
correctly: it passes `lifecycle == .active || lifecycle == .proposed` (showing
both confirmed and agent-proposed contradictions). Regressing this would be a
bug. This path is INTENTIONALLY_LEFT unchanged.

---

## Global Summary

- MUST_UPDATE: 8 sites (DrawerStore.swift, drawer_store.rs, ToolDispatch.swift ×2,
  interface_tools.rs ×2, Estate.swift docstring, DreamingReads.swift docstring)
- INTENTIONALLY_LEFT: 5 (EstateDreamingReader Swift/Rust, pass-throughs, LensTools)
- RESCOPE_REQUIRED: 0

allActiveTunnels caller audit decision: **(a) — filter added inside allActiveTunnels**.
All callers semantically want lifecycle==active; the method name already implies it.
