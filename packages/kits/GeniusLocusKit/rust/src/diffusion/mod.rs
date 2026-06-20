// diffusion — the time-axis peer of distillation (ADR-DIFFUSION-001).
//
// Per-layer motion models, folded from the audit log with a per-layer decay
// constant (the noise schedule across the zoom hierarchy: node fast → estate
// slow). Built bottom-up: the node layer first.

pub mod node_anomaly;
pub mod node_motion;
