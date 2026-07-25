// WorkPacketKit — durable agentic work-packet schema and drawer-backed store.
//
// Public surface (re-exported from this module umbrella):
//   WorkPacket            — schema v1, Codable, unknown-field-preserving
//   WorkPacketSource      — evidence record within a packet
//   WorkPacketClaim       — conclusion with confidence + source refs
//   WorkPacketProvenance  — model / agent / timestamps
//   LineageLink           — typed antecedent pointer (derivesFrom | respondsTo)
//   LineageLinkKind       — closed vocabulary for lineage relationship kinds
//   WorkPacketEstateClient — protocol for estate injection (testable seam)
//   EstateAdapter         — production adapter over LocusKit.Estate
//   WorkPacketStore       — actor: encode → drawer, lineage → tunnel
//   LineageGraph          — breadth-first lineage traversal
//   WorkPacketKitError    — kit-local errors

// All types are declared in their own files; this file exists to provide
// a landing point for module-level documentation.
