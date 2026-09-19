import Testing
import Foundation
@testable import mcp_benchmarker

// DumpSeedParentDirTests.swift — gates the --dump-seed parent-directory
// creation fix across three CLI lanes.
//
// Prior to the fix each lane called bare `Data.write(to: URL(...))` which
// does not create intermediate directories. A nested dump path like
// "out/new-dir/seed.json" would fail ENOENT when the parent was absent.
//
// Suite map:
//
//   DumpSeedParentDir
//     journeyDumpSeedCreatesParentDir   — --dump-seed path with absent parent
//     supersessionDumpSeedCreatesParentDir — same for supersession lane
//     factLayerDumpSeedCreatesParentDir — same for fact-layer variant
//
// What makes each test go red: removing the `createDirectory` call before the
// write in the corresponding lane causes the write to fail ENOENT, so the
// function throws and the `#expect(data.count > 0)` assertion is never reached.
// The test would also fail if the file is not created at all.

@Suite("DumpSeedParentDir")
struct DumpSeedParentDirTests {

    /// Returns a fresh temp directory that does NOT contain the target subdir.
    private func makeTempBase() throws -> URL {
        let dir = URL(fileURLWithPath:
            "/tmp/dump-seed-parent-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Journey lane

    @Test("journey --dump-seed creates parent dir when absent")
    func journeyDumpSeedCreatesParentDir() async throws {
        let base = try makeTempBase()
        defer { try? FileManager.default.removeItem(at: base) }

        let dumpPath = base
            .appendingPathComponent("new-subdir")
            .appendingPathComponent("journey-fixture.json").path

        // The parent ("new-subdir") does not exist yet.
        #expect(!FileManager.default.fileExists(atPath: base.appendingPathComponent("new-subdir").path),
                "precondition: parent subdir must be absent before the call")

        try await runJourney(["--dump-seed", dumpPath])

        let data = try Data(contentsOf: URL(fileURLWithPath: dumpPath))
        #expect(data.count > 0, "dump file must exist and be non-empty")
    }

    // MARK: - Supersession lane

    @Test("supersession --dump-seed creates parent dir when absent")
    func supersessionDumpSeedCreatesParentDir() async throws {
        let base = try makeTempBase()
        defer { try? FileManager.default.removeItem(at: base) }

        let dumpPath = base
            .appendingPathComponent("new-subdir")
            .appendingPathComponent("supersession-seed.json").path

        #expect(!FileManager.default.fileExists(atPath: base.appendingPathComponent("new-subdir").path),
                "precondition: parent subdir must be absent before the call")

        try await runSupersession(["--dump-seed", dumpPath])

        let data = try Data(contentsOf: URL(fileURLWithPath: dumpPath))
        #expect(data.count > 0, "dump file must exist and be non-empty")
    }

    // NOTE — the two ports answer `--fact-layer --dump-seed` differently.
    //
    // Swift runSupersession tests --dump-seed at CLI.swift:4688 and returns at
    // 4705, before the --fact-layer block at 4725. Rust run_supersession tests
    // --fact-layer first, at main.rs:4558, and handles --dump-seed inside that
    // branch at 4577.
    //
    // So the same flag pair writes the supersession seed on the Swift leg and
    // the fact-layer corpus on the Rust leg: different artifacts, same command.
    // The cross-leg dump diff named at CLI.swift:4685 as the leg-agreement
    // proof cannot hold while that is true. Which ordering is correct is an
    // open ruling; neither port was changed here, because changing either one
    // silently changes what a published dump contains.
    //
    // One consequence is local: the Swift fact-layer dump at CLI.swift:4748 is
    // unreachable from the argument surface, so it has no gate here. The Rust
    // path IS reachable and is gated by
    // dump_seed_parent_dir_tests::fact_layer_dump_seed_creates_parent_dir.
}
