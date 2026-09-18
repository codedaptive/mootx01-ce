import Foundation
import Testing

// MARK: - Human-language source guard — MootCommunityUI (MA-MOOT-UI-CENSUS)
//
// Enforces the human-language acceptance law on the Community UI sources:
// default visible UI must contain zero enum rawValue output, UUID strings,
// debug descriptions, or internal error strings. This guard scans the
// PRODUCTION sources of Sources/MootCommunityUI for the token patterns that
// produce those leaks and compares every hit against an ENUMERATED baseline.
//
// The baseline is explicit debt, not permission: each display-reaching entry
// maps to a RED item in apps/Mootx01-App/docs/UI_ACCEPTANCE_CENSUS.md (§5),
// and the non-display entries (wire-argument encoding, init(rawValue:)
// parsing, Identifiable conformances, private OSLog lines) are enumerated so
// that ANY new occurrence of a token — display or not — fails this test and
// forces a human decision. Removing a violation makes the baseline stale,
// which also fails: the baseline can never drift from the sources silently.
//
// Readback-evidence rule compliance: the guard cannot pass vacuously. It
// asserts a nonzero scanned-file count, and it proves its own detector on
// seeded fixtures — a fixture containing a violation MUST be flagged and a
// clean fixture MUST NOT be. If the scanner regresses, the fixture test
// fails closed.

@Suite("Human-language source guard — MootCommunityUI")
struct CommunityHumanLanguageSourceGuard {

    // MARK: Scanner

    /// Token substrings whose appearance in a UI-module source line marks a
    /// potential raw-internal-value leak into the visible product.
    static let forbiddenTokens = [
        "rawValue",
        "uuidString",
        "debugDescription",
        "String(describing:",
        "localizedDescription",
    ]

    struct ScanResult {
        var fileCount = 0
        /// Key = "<relative path>|<trimmed line>", value = occurrence count.
        var hits: [String: Int] = [:]
    }

    /// Scan one source text. Comment-only lines (trimmed prefix "//") are
    /// skipped; every other line containing a forbidden token is a hit.
    static func scanSource(_ source: String, relativePath: String, into result: inout ScanResult) {
        result.fileCount += 1
        for rawLine in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("//") else { continue }
            guard forbiddenTokens.contains(where: { trimmed.contains($0) }) else { continue }
            let key = "\(relativePath)|\(trimmed)"
            result.hits[key, default: 0] += 1
        }
    }

    /// Scan every .swift file under `root` (recursive, name-sorted).
    static func scan(root: URL) throws -> ScanResult {
        var result = ScanResult()
        let files = try swiftFiles(under: root)
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            let relative = file.path.replacingOccurrences(of: root.path + "/", with: "")
            scanSource(source, relativePath: relative, into: &result)
        }
        return result
    }

    static func swiftFiles(under root: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil
        ) else { return [] }
        var files: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            files.append(url)
        }
        return files.sorted { $0.path < $1.path }
    }

    /// Sources/MootCommunityUI, located relative to this test file so the
    /// guard runs from any checkout without configuration.
    static var sourcesRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/CommunityBoundaryTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // apps/Mootx01-App
            .appendingPathComponent("Sources/MootCommunityUI")
    }

    // MARK: Baseline
    //
    // Every entry below is one line of production source that contains a
    // forbidden token TODAY. Display-reaching entries carry their census RED
    // id. Non-display entries are wire encoding / parsing / Identifiable
    // conformance and never reach a Text/Label. Update this table ONLY as
    // part of a change that resolves (or knowingly adds to) the census.
    static let baseline: [String: Int] = [
        // Identifiable conformance — non-display.
        #"Capture/CommunityCaptureModel.swift|public var id: String { rawValue }"#: 1,
        // Wire-argument encoding — non-display.
        #"Capture/DaemonCommunityCaptureService.swift|"requestID": .string(request.requestID.uuidString),"#: 1,
        #"Capture/DaemonCommunityCaptureService.swift|"sensitivity": .string(request.policy.sensitivity.rawValue),"#: 1,
        // Wire-response parsing — non-display.
        #"Capture/DaemonCommunityCaptureService.swift|let defaultSensitivity = CommunityCaptureSensitivity(rawValue: defaultSensitivityRaw),"#: 1,
        #"Capture/DaemonCommunityCaptureService.swift|let field = CommunityCaptureRefusedField(rawValue: fieldRaw),"#: 1,
        #"Capture/DaemonCommunityCaptureService.swift|let recordID = UUID(uuidString: recordRaw),"#: 1,
        #"Capture/DaemonCommunityCaptureService.swift|let sensitivity = CommunityCaptureSensitivity(rawValue: sensitivityRaw),"#: 1,
        #"Capture/DaemonCommunityCaptureService.swift|value.stringValue.flatMap(CommunityCaptureSensitivity.init(rawValue:))"#: 1,
        // Accessibility identifier derivation — non-display (identifier, not label).
        #"CommunityContentView.swift|"community.destination.\(rawValue.lowercased())""#: 1,
        // Census com.shell.sidebar.labels (AMBER): rawValue used as the
        // localization key; English display text equals the rawValue.
        #"CommunityContentView.swift|Label(String(localized: String.LocalizationValue(destination.rawValue)),"#: 1,
        // Identifiable conformance — non-display.
        #"CommunityContentView.swift|var id: String { rawValue }"#: 1,
        // Wire-argument encoding — non-display.
        #"Integration/DaemonCommunityFeaturePorts.swift|"actionID": .string(actionID.uuidString),"#: 1,
        #"Integration/DaemonCommunityFeaturePorts.swift|"choiceID": .string(choiceID.uuidString),"#: 1,
        #"Integration/DaemonCommunityFeaturePorts.swift|"groupID": .string(groupID.uuidString),"#: 1,
        #"Integration/DaemonCommunityFeaturePorts.swift|"moot_community_review_session", arguments: ["kind": .string(kind.rawValue)]"#: 1,
        #"Integration/DaemonCommunityFeaturePorts.swift|"operationID": .string(operationID.uuidString),"#: 1,
        #"Integration/DaemonCommunityFeaturePorts.swift|"sessionID": .string(sessionID.uuidString),"#: 3,
        #"Integration/DaemonCommunityFeaturePorts.swift|await state("moot_community_estate_migrate", arguments: ["planID": .string(planID.uuidString)])"#: 1,
        #"Integration/DaemonCommunityFeaturePorts.swift|await state("moot_community_estate_open", arguments: ["estateID": .string(id.uuidString)])"#: 1,
        // Wire-response parsing — non-display.
        #"Integration/DaemonCommunityFeaturePorts.swift|let kind = ReviewSessionKind(rawValue: kindRaw),"#: 2,
        #"Integration/DaemonCommunityFeaturePorts.swift|value?.stringValue.flatMap(UUID.init(uuidString:))"#: 1,
        // Identifiable conformance — non-display.
        #"Review/ReviewCenterPort.swift|public var id: String { rawValue }"#: 1,
        // R-C16 closed (com.review.session.dup.records GREEN): the duplicate
        // group's FULL record identifiers on a labeled ("Record IDs:"),
        // selectable secondary line — sanctioned technical display under the
        // human-language law; the primary description is the human count.
        // CONTRACT-04 carries no record subjects (CD-3 remains open).
        #"Review/ReviewCenterView.swift|let list = ids.map { $0.uuidString }.joined(separator: ", ")"#: 1,
    ]

    // MARK: Guard tests

    @Test("the scan covers the real Community UI sources (non-vacuous)")
    func scanIsNotVacuous() throws {
        let result = try Self.scan(root: Self.sourcesRoot)
        // MootCommunityUI ships 21 sources today; a collapse below 10 means
        // the guard is scanning the wrong directory, not that UI shrank.
        #expect(result.fileCount >= 10, "scanned only \(result.fileCount) files under \(Self.sourcesRoot.path)")
        #expect(!result.hits.isEmpty, "zero token hits — the baseline says \(Self.baseline.count) exist; the scanner is broken or mis-rooted")
    }

    @Test("no source line leaks a raw internal value beyond the enumerated baseline")
    func noNewViolations() throws {
        let result = try Self.scan(root: Self.sourcesRoot)
        var newViolations: [String] = []
        for (key, count) in result.hits {
            let allowed = Self.baseline[key] ?? 0
            if count > allowed {
                newViolations.append("\(key) (found \(count), baseline \(allowed))")
            }
        }
        #expect(newViolations.isEmpty, """
            NEW raw-internal-value occurrences in MootCommunityUI. Default \
            visible UI must not show rawValue/uuidString/debugDescription/\
            error internals. Either present a human value instead, or — for \
            a genuinely non-display use — add the line to the baseline with \
            a census entry:
            \(newViolations.sorted().joined(separator: "\n"))
            """)
    }

    @Test("the baseline matches the sources exactly (no stale debt entries)")
    func baselineIsCurrent() throws {
        let result = try Self.scan(root: Self.sourcesRoot)
        var stale: [String] = []
        for (key, expected) in Self.baseline {
            let found = result.hits[key] ?? 0
            if found != expected {
                stale.append("\(key) (baseline \(expected), found \(found))")
            }
        }
        #expect(stale.isEmpty, """
            Baseline entries no longer match the sources — a violation was \
            fixed or moved. Update the baseline AND the census RED item \
            together:
            \(stale.sorted().joined(separator: "\n"))
            """)
    }

    // MARK: Scanner self-tests (fail-closed proof)

    @Test("the scanner detects a seeded display-layer violation")
    func scannerDetectsSeededViolation() {
        let seeded = """
        struct FixtureView {
            var body: some Text {
                Text(item.id.uuidString)
                Text(state.rawValue)
                Text(error.localizedDescription)
            }
        }
        """
        var result = CommunityHumanLanguageSourceGuard.ScanResult()
        Self.scanSource(seeded, relativePath: "Fixture.swift", into: &result)
        #expect(result.hits["Fixture.swift|Text(item.id.uuidString)"] == 1)
        #expect(result.hits["Fixture.swift|Text(state.rawValue)"] == 1)
        #expect(result.hits["Fixture.swift|Text(error.localizedDescription)"] == 1)
        #expect(result.hits.count == 3)
    }

    @Test("the scanner does not flag clean code or comments")
    func scannerIgnoresCommentsAndCleanCode() {
        let clean = """
        // rawValue in a comment is not a violation, nor is uuidString here.
        struct FixtureView {
            var body: some Text {
                Text(String(localized: "Perfectly human sentence."))
            }
        }
        """
        var result = CommunityHumanLanguageSourceGuard.ScanResult()
        Self.scanSource(clean, relativePath: "Clean.swift", into: &result)
        #expect(result.hits.isEmpty)
        #expect(result.fileCount == 1)
    }
}
