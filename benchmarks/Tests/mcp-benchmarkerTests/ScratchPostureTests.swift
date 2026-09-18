import XCTest
import MootProductIdentity
@testable import mcp_benchmarker

// ScratchPostureTests.swift — the scratch-estate grammar the harness hands the
// product, and the posture vocabulary the reports record.
//
// Contract under test (the product's estate catalog): a scratch estate is
// `serve --db <scratchDir>`, a transient record at that directory whose file
// is `<scratchDir>/estate.sqlite`, plaintext by rule; `--in-memory` selects the
// RAM shape. No marker file and no environment value select the posture.

final class ScratchPostureTests: XCTestCase {

    func testServeCommandSelectsTheScratchRecord() throws {
        let command = try mootServeCommand(
            binary: "/tmp/mootx01", scratchDir: URL(fileURLWithPath: "/tmp/lme-bench-x"),
            environment: ["MOOTX01_VAULT=1"])
        XCTAssertEqual(command, "MOOTX01_VAULT=1 /tmp/mootx01 serve --db /tmp/lme-bench-x")
    }

    func testServeCommandAppendsInMemoryForTheRAMShape() throws {
        let command = try mootServeCommand(
            binary: "/tmp/mootx01", scratchDir: URL(fileURLWithPath: "/tmp/lme-bench-x"), inMemory: true)
        XCTAssertEqual(command, "/tmp/mootx01 serve --db /tmp/lme-bench-x --in-memory")
    }

    func testCreatorsWriteNoPostureFile() throws {
        // The posture travels with the record kind, not with a file: every
        // scratch creator leaves the directory empty for the product to fill.
        for (url, teardown) in [
            (try lmeScratchDir(posture: .plaintextTransient), lmeGuardedTeardown),
            (try lmeScratchDir(posture: .encryptedEphemeral), lmeGuardedTeardown),
            (try loCoMoScratchDir(posture: .plaintextTransient), loCoMoGuardedTeardown),
            (try lmebScratchDir(posture: .plaintextTransient), lmebGuardedTeardown),
        ] {
            defer { try? teardown(url) }
            let contents = try FileManager.default.contentsOfDirectory(atPath: url.path)
            XCTAssertEqual(contents, [], "a fresh scratch dir carries no posture file: \(contents)")
        }
    }

    func testMootServePathContainsWhitespaceDetectsSpaces() {
        // The helper is the testable face of the precondition guard in
        // mootServeCommand. The guard fires on the same predicate.
        XCTAssertTrue(mootServePathContainsWhitespace("/tmp/lme bench x"),
                      "path with space must be detected")
        XCTAssertTrue(mootServePathContainsWhitespace("/tmp/lme\tbench"),
                      "path with tab must be detected")
        XCTAssertFalse(mootServePathContainsWhitespace("/tmp/lme-bench-x"),
                       "path with no whitespace must pass")
        XCTAssertFalse(mootServePathContainsWhitespace("/tmp/lme-bench-0000000000000001"),
                       "normal scratch path must pass")
    }

    func testScratchServeEnvironmentGoldenString() throws {
        // Both MOOTX01_VAULT=1 and MOOTX01_SUBJECT_RIDER=0 must appear in
        // every main-runner serve command. This is the canonical golden string
        // that documents and guards the standard env pair.
        let command = try mootServeCommand(
            binary: "/tmp/mootx01", scratchDir: URL(fileURLWithPath: "/tmp/lme-bench-x"),
            environment: scratchServeEnvironment)
        XCTAssertEqual(
            command,
            "MOOTX01_VAULT=1 MOOTX01_SUBJECT_RIDER=0 /tmp/mootx01 serve --db /tmp/lme-bench-x"
        )
    }

    func testBenchClockEpochTokenPrependedInReplayCommand() throws {
        // MOOT_BENCH_EPOCH_NOW travels as the first KEY=VALUE token so
        // /usr/bin/env sees it before the standard env pair.
        let epochToken = "\(mootBenchEpochNowEnvKey)=2026-01-01T00:00:00Z"
        let command = try mootServeCommand(
            binary: "/tmp/mootx01", scratchDir: URL(fileURLWithPath: "/tmp/lme-bench-x"),
            environment: [epochToken] + scratchServeEnvironment)
        XCTAssertEqual(
            command,
            "MOOT_BENCH_EPOCH_NOW=2026-01-01T00:00:00Z MOOTX01_VAULT=1 MOOTX01_SUBJECT_RIDER=0 /tmp/mootx01 serve --db /tmp/lme-bench-x"
        )
    }

    func testMootServeDirUnderProductConfigDetectsAppSupportPath() {
        // The helper is the testable face of the precondition guard in
        // mootServeCommand. Pinned against MootProductIdentity.Storage.configurationDirectory —
        // the same source the production code uses — so a wrong directory in
        // that library would produce a failing test rather than a self-consistent
        // but incorrect passing one.
        let configDir = MootProductIdentity.Storage.configurationDirectory
        // Guard: if the platform returns the fallback "." directory (HOME absent),
        // the check is inoperative — skip rather than test a degenerate fixture.
        guard configDir.path != "." else { return }
        let underConfig = configDir.appendingPathComponent("estates/default")
        XCTAssertTrue(mootServeDirUnderProductConfig(underConfig),
                      "path under product config directory must be detected")
        // The config dir itself is also refused.
        XCTAssertTrue(mootServeDirUnderProductConfig(configDir),
                      "the config dir itself must be detected")
        // A path with the same prefix but a different suffix (evil-twin attack) must NOT match.
        let evilTwin = configDir.deletingLastPathComponent()
            .appendingPathComponent(configDir.lastPathComponent + "-evil")
        XCTAssertFalse(mootServeDirUnderProductConfig(evilTwin),
                       "a path with the same prefix but different suffix must not match")
        // Scratch and artifact paths under /tmp are allowed.
        XCTAssertFalse(mootServeDirUnderProductConfig(URL(fileURLWithPath: "/tmp/lme-bench-x")),
                       "/tmp scratch path must not be detected as product config")
        // Artifact paths on external volumes are allowed.
        XCTAssertFalse(mootServeDirUnderProductConfig(URL(fileURLWithPath: "/Volumes/benchmark_dbs/lmeb-v1")),
                       "artifact path on external volume must not be detected as product config")
    }

    // MARK: - Per-guard discriminated refusal tests
    //
    // Each test exercises exactly one guard so that deleting guard 1 makes
    // the whitespace test fail while the registered-path test stays green,
    // and deleting guard 2 makes the registered-path test fail while the
    // whitespace test stays green.
    //
    // The injectable `productConfigDir` parameter on `mootServeCommand` is the
    // seam that makes both guards independently testable. The whitespace test
    // uses a scratch path that contains a space but does NOT lie under the
    // injected config dir, so guard 1 fires and guard 2 never runs. The
    // registered-path test uses a scratch path WITHOUT whitespace that lies
    // under the injected config dir (a no-whitespace temp directory), so guard 1
    // passes and guard 2 fires.

    func testServeCommandRefusesWhitespaceInPath() {
        // Guard 1 (whitespaceInPath) — must fire exactly, guard 2 must not run.
        // scratchDir: a path with a space. productConfigDir: a no-whitespace
        // temp directory that the spacey path does NOT lie under, so only
        // guard 1 fires.
        let noSpaceConfigDir = URL(fileURLWithPath: "/tmp/bench-config-nosp")
        let spaceyPath = URL(fileURLWithPath: "/tmp/lme bench x")
        XCTAssertThrowsError(
            try mootServeCommand(
                binary: "/tmp/mootx01", scratchDir: spaceyPath,
                productConfigDir: noSpaceConfigDir),
            "guard 1 must fire for a path with whitespace"
        ) { error in
            switch error {
            case ScratchPostureError.whitespaceInPath:
                break  // expected
            case ScratchPostureError.registeredEstatePath:
                XCTFail("guard 2 must not fire when scratchDir has whitespace and is not under productConfigDir")
            default:
                XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testServeCommandRefusesRegisteredEstatePath() {
        // Guard 2 (registeredEstatePath) — must fire exactly, guard 1 must not run.
        // productConfigDir: a no-whitespace temp directory. scratchDir: a path
        // under that temp directory, also without whitespace. Guard 1 passes,
        // guard 2 fires and returns .registeredEstatePath.
        let tmpConfigDir = URL(fileURLWithPath: "/tmp/bench-registered-guard2")
        let underConfig = tmpConfigDir.appendingPathComponent("estates/bench-test")
        XCTAssertThrowsError(
            try mootServeCommand(
                binary: "/tmp/mootx01", scratchDir: underConfig,
                productConfigDir: tmpConfigDir),
            "guard 2 must fire for a path under the injected product config directory"
        ) { error in
            switch error {
            case ScratchPostureError.registeredEstatePath(let msg):
                XCTAssertTrue(msg.contains("registered product estate"),
                              "registeredEstatePath error must mention the estate: \(msg)")
            case ScratchPostureError.whitespaceInPath:
                XCTFail("guard 1 must not fire: scratchDir has no whitespace")
            default:
                XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testBenchClockEpochISOGoldenString() {
        // seed=0 → offset 0 % 86400 = 0 → base 2026-01-01T00:00:00Z.
        // This is the golden string both ports must produce for seed 0.
        // Change only if the derivation formula changes; update the Rust twin
        // (bench_clock_epoch_iso_seed_zero_matches_swift) simultaneously.
        XCTAssertEqual(benchClockEpochISO(for: 0), "2026-01-01T00:00:00Z")
    }

    func testRawValuesAreTheReportVocabulary() {
        // These strings are the report JSON "estate_encryption" values and
        // cache-key components; downstream analysis scripts key on them, so the
        // plaintext value keeps the name of the retired marker mechanism.
        XCTAssertEqual(ScratchEstatePosture.plaintextTransient.rawValue, "plaintext-optout")
        XCTAssertEqual(ScratchEstatePosture.encryptedEphemeral.rawValue, "encrypted-ephemeral")
    }
}
