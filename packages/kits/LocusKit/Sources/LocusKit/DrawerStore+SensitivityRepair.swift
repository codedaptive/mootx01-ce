// DrawerStore+SensitivityRepair.swift
//
// Tunnel adjective-bitmap repair accessor used by the consolidation sweep
// repair prologue (§D.6 #4). Kept in a separate file so the main
// DrawerStore.swift is not rewritten during this mission.
//
// Sensitivity tier for tunnels lives at adjective bits 6–11 (shift 6,
// width 6) per cookbook §2.3. The consolidation sweep repair prologue
// computes the promoted bitmap value and calls this method to overwrite
// the tunnel row directly. No audit event is recorded — the drawer-level
// audit events (via repairVagueAdjectiveBitmap / repairVagueProvenance)
// are the canonical change records for the repair pass.

import Foundation
import PersistenceKit

extension DrawerStore {

    /// Overwrite adjectiveBitmap on a tunnel directly (bits 6–11 carry the
    /// sensitivity tier per cookbook §2.3). Used by the consolidation repair
    /// prologue (§D.6 #4) to restamp _consolidated_from tunnels that were
    /// written before sensitivity inheritance shipped. No audit event —
    /// correction write only.
    ///
    /// Returns silently when tunnelId does not exist; a missing tunnel is not
    /// an error during a batch repair pass (the tunnel may have been expunged
    /// after consolidation ran).
    public func updateTunnelAdjBitmap(id tunnelId: String, adjBitmap: Int64) async throws {
        _ = try await storage.rowStore.update(
            table: "tunnels",
            values: ["adjectiveBitmap": .bitmap(adjBitmap)],
            where: .eq(Column(table: "tunnels", name: "id"), .text(tunnelId))
        )
    }
}
