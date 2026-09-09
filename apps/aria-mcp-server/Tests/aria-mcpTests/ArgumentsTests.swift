import Testing
@testable import aria_mcp

/// The `aria-mcp` command line: what it accepts, what it refuses, and with
/// which exit code. Twin of the Rust `main.rs` `parse_arguments` tests — the
/// same table in the same order, so a change to one port that is not made to
/// the other shows as a missing test rather than a silent divergence.
///
/// Argument parsing needs no catalog and no estate, so these stay hermetic:
/// nothing here touches the machine's `estatecatalog.json`.
@Suite("aria-mcp arguments")
struct AriaMCPArgumentsTests {

    @Test func noArgumentsSelectsTheActiveEstate() throws {
        let parsed = try AriaMCPMain.Arguments([])
        #expect(parsed.db == nil)
        #expect(!parsed.inMemory)
        #expect(!parsed.help)
    }

    @Test func dbTakesARegisteredName() throws {
        let parsed = try AriaMCPMain.Arguments(["--db", "work"])
        #expect(parsed.db == "work")
        #expect(!parsed.inMemory)
    }

    @Test func dbTakesADirectoryAndName() throws {
        let parsed = try AriaMCPMain.Arguments(["--db", "/tmp/scratch/bench"])
        #expect(parsed.db == "/tmp/scratch/bench")
    }

    @Test func inMemoryComposesWithDB() throws {
        let parsed = try AriaMCPMain.Arguments(["--db", "/tmp/scratch/bench", "--in-memory"])
        #expect(parsed.db == "/tmp/scratch/bench")
        #expect(parsed.inMemory)
    }

    @Test func helpIsAcceptedInBothSpellings() throws {
        #expect(try AriaMCPMain.Arguments(["--help"]).help)
        #expect(try AriaMCPMain.Arguments(["-h"]).help)
    }

    @Test func dbWithoutAValueIsRefused() {
        #expect(throws: AriaMCPMain.Arguments.UsageError("--db requires a value")) {
            _ = try AriaMCPMain.Arguments(["--db"])
        }
    }

    @Test func dbFollowedByAFlagIsRefused() {
        // Without this guard `--db --in-memory` names an estate "--in-memory".
        #expect(throws: AriaMCPMain.Arguments.UsageError(
            "--db requires an estate name, got the flag '--in-memory'")) {
            _ = try AriaMCPMain.Arguments(["--db", "--in-memory"])
        }
    }

    @Test func repeatedDBIsRefused() {
        #expect(throws: AriaMCPMain.Arguments.UsageError("--db given twice")) {
            _ = try AriaMCPMain.Arguments(["--db", "a", "--db", "b"])
        }
    }

    @Test func anUnknownArgumentIsRefused() {
        // `--frozen` and `--http` are `mootx01 serve` flags; aria-mcp has neither.
        #expect(throws: AriaMCPMain.Arguments.UsageError("unexpected argument '--frozen'")) {
            _ = try AriaMCPMain.Arguments(["--frozen"])
        }
    }

    @Test func usageExitCodeIsOneInBothPorts() {
        #expect(AriaMCPMain.Arguments.usageExitCode == 1)
    }
}
