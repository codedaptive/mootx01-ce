// EstateFixtureEmit — regenerate the checked-in twenty-row estate artifact.
//
// WHY THIS TOOL EXISTS
// The Rust tests open a CHECKED-IN copy of the twenty-row estate rather than
// generating their own (see the Part 3 justification in the CE-1.0.35-04
// completion report: the Swift generator's output cannot be reproduced
// byte-for-byte by a second implementation, because capture stamps wall-clock
// time, mints an estate UUID, and folds a Merkle rollup — so "the same fixture"
// can only mean "the same bytes").
//
// A checked-in binary with no way to rebuild it is how fixtures rot. This tool
// is that way. It is an executableTarget with no library product, so it ships in
// nothing; it exists to be run by hand when the estate schema changes:
//
//   swift run EstateFixtureEmit <output-directory>
//
// It writes two files:
//   estate.sqlite  — the fixture, plaintext
//   manifest.json  — the counts and tier row ids, so the Rust test asserts
//                    against the manifest instead of magic numbers
//
// The production-path guard in the generator applies here too: this tool cannot
// be pointed at the real data directory.

import Foundation
import LocusKitEstateFixture

// Sorted-key output so a regenerated manifest.json diffs cleanly instead of
// reordering on every run.
func encodeManifest(_ manifest: TwentyRowEstateFixture.Manifest) throws -> Data {
    // Hand-built rather than Codable: the tier map is keyed by an enum, and the
    // Rust side wants plain lowercase tier names as JSON keys.
    var tierObject: [String: String] = [:]
    for (tier, id) in manifest.drawerIDsByProvenanceTier {
        tierObject["\(tier)"] = id
    }
    let object: [String: Any] = [
        "drawer_count": manifest.drawerCount,
        "fact_count": manifest.factCount,
        "tunnel_count": manifest.tunnelCount,
        "wings": manifest.wings,
        "rooms": manifest.rooms,
        "drawer_ids_by_provenance_tier": tierObject,
        "drawer_ids": manifest.drawerIDs,
        "fact_ids": manifest.factIDs,
        "tunnel_ids": manifest.tunnelIDs,
        "precedes_tunnel_id": manifest.precedesTunnelID,
    ]
    return try JSONSerialization.data(
        withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let outputPath = arguments.first else {
    FileHandle.standardError.write(Data("""
        usage: swift run EstateFixtureEmit <output-directory>

        Regenerates the checked-in twenty-row estate fixture artifact. Point it at
        packages/kits/LocusKit/rust/tests/fixtures to refresh what the Rust tests read.

        """.utf8))
    exit(2)
}

let outputDirectory = URL(fileURLWithPath: outputPath, isDirectory: true)
let estateURL = outputDirectory.appendingPathComponent("estate.sqlite")
let manifestURL = outputDirectory.appendingPathComponent("manifest.json")

do {
    // Refuse the real data directory BEFORE any filesystem side effect —
    // directory creation and cleanup included. generate(at:) runs the same
    // guard, but by then cleanup would already have deleted files; the tool
    // must fail before it touches anything.
    try TwentyRowEstateFixture.assertNotProductionPath(estateURL)

    try FileManager.default.createDirectory(
        at: outputDirectory, withIntermediateDirectories: true)

    // Regenerating over a previous artifact must start clean: capture appends,
    // so writing into an existing estate would produce forty rows, not twenty.
    TwentyRowEstateFixture.cleanup(estateURL)

    let manifest = try await TwentyRowEstateFixture.generate(at: estateURL)
    try encodeManifest(manifest).write(to: manifestURL, options: .atomic)

    let bytes = (try? FileManager.default.attributesOfItem(atPath: estateURL.path)[.size]
        as? Int) ?? 0
    print("wrote \(estateURL.path) (\(bytes) bytes)")
    print("wrote \(manifestURL.path)")
    print("drawers=\(manifest.drawerCount) facts=\(manifest.factCount) tunnels=\(manifest.tunnelCount)")
} catch {
    FileHandle.standardError.write(Data("EstateFixtureEmit failed: \(error)\n".utf8))
    exit(1)
}
