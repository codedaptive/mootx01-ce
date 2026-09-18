// SharedVectorsPath.swift
//
// Test-target copy of the shared-vectors locator (the CorpusKitTests helper
// is not visible from this target). Both resolve Tests/SharedVectors relative
// to this source file.

import Foundation

/// Resolve a file in Tests/SharedVectors relative to this source file.
/// The fixture lives two directories up from Tests/CorpusKitTests.
func sharedVectorsURL(for name: String) -> URL {
    // #filePath → .../Tests/CorpusKitTests/<thisFile>.swift
    let thisFile = URL(fileURLWithPath: #filePath)
    return thisFile
        .deletingLastPathComponent()          // CorpusKitTests/
        .deletingLastPathComponent()          // Tests/
        .appendingPathComponent("SharedVectors")
        .appendingPathComponent(name)
}
