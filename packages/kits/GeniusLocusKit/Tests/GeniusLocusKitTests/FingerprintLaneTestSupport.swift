// FingerprintLaneTestSupport.swift
//
// Test scaffold for the structural fingerprint lane. Production populates the
// `distillation-features-v1` lane from the encode rider (one entry per drained
// drawer) and from the hint-seeding path; tests that capture without draining
// a corpus queue call this helper to reach the same populated state.

import Foundation
import LocusKit
@testable import GeniusLocusKit

extension GeniusLocusKit {

    /// Write the structural fingerprint lane entry for every active drawer of
    /// `handle` with non-empty content — the rider's per-drawer work, applied
    /// estate-wide. Returns the count of lane entries written (drawers whose
    /// content yields a zero fingerprint write nothing and are not counted).
    func fingerprintAllDrawers(handle: EstateHandle, now: Date) async throws -> Int {
        let estate = try estate(for: handle)
        var written = 0
        for drawer in try await estate.allDrawers() where !drawer.content.isEmpty {
            if try await writeStructuralFingerprint(
                handle: handle, drawerID: drawer.id, content: drawer.content, now: now) {
                written += 1
            }
        }
        return written
    }
}
