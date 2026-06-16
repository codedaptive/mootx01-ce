// CookbookAudit — subsystem 5 of the SubstrateValidator Swift app.
//
// STRUCTURAL / HEURISTIC SOURCE↔COOKBOOK AUDIT — NOT A SEMANTIC-EQUIVALENCE
// PROOF. This auditor reads the approved engineering cookbook's per-primitive
// pseudocode and checks that the SHIPPING Swift lib source (packages/libs)
// references the same algorithm signatures — the same magic hex constants and
// the same operation vocabulary (popcount, XOR/AND/OR, shifts, sqrt/exp/log,
// etc.). It reports MATCH or DRIFT per primitive.
//
// What MATCH means here: every magic hex constant the cookbook block names is
// textually present in the shipping source, AND every cookbook operation
// keyword the block uses is textually present (under its Swift spelling). That
// is a *token/constant coverage* check. It says "the source mentions the same
// constants and operations the cookbook prescribes." It does NOT say "the
// source computes the same function" — token coverage is necessary but not
// sufficient for semantic equivalence. Bit-exact equivalence is proven
// elsewhere: the conformance CRC gate (main.swift, subsystem B+2) and the
// cross-language comparator (subsystem 3). This auditor is the cheap structural
// tripwire that flags when shipping source has visibly drifted from the
// cookbook's named constants/operations — a fast first signal, read alongside
// the CRC gate, never in place of it.
//
// Map source: the primitive→cookbook-§→shipping-Swift-source mapping is read
// live from docs/engineering/HARNESS_REFERENCE.md:
//   - the §2.0 four-package table gives "| primitive | package | Swift file | Rust module |"
//   - the per-primitive "#### `name` — §X.Y — CRC ..." headings give the cookbook §.
// The algorithm pseudocode is read from
// docs/engineering/GENIUSLOCUS_ENGINEERING_COOKBOOK.md.

import Foundation

enum CookbookAudit {

    // MARK: - Path resolution

    // The app package root is validation-app/swift-app. This file sits at
    // <pkgRoot>/Sources/SubstrateValidator/CookbookAudit.swift, so the package
    // root is three parents up. The repo root is five parents up from there
    // (validation-app/swift-app -> validation-app -> substrate_math_performance
    // -> validation -> docs -> repo root). docs/engineering/ holds the cookbook
    // and the harness reference. We resolve relative to #filePath so the audit
    // runs from any working directory.
    private static func docsEngineeringDir() -> URL {
        let pkgRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // SubstrateValidator
            .deletingLastPathComponent()   // Sources
            .deletingLastPathComponent()   // swift-app (package root)
        let repoRoot = pkgRoot
            .deletingLastPathComponent()   // validation-app
            .deletingLastPathComponent()   // substrate_math_performance
            .deletingLastPathComponent()   // validation
            .deletingLastPathComponent()   // docs
            .deletingLastPathComponent()   // repo root
        return repoRoot
            .appendingPathComponent("docs")
            .appendingPathComponent("engineering")
            .standardizedFileURL
    }

    private static func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // SubstrateValidator
            .deletingLastPathComponent()   // Sources
            .deletingLastPathComponent()   // swift-app
            .deletingLastPathComponent()   // validation-app
            .deletingLastPathComponent()   // substrate_math_performance
            .deletingLastPathComponent()   // validation
            .deletingLastPathComponent()   // docs
            .deletingLastPathComponent()   // repo root
            .standardizedFileURL
    }

    private static let cookbookName = "GENIUSLOCUS_ENGINEERING_COOKBOOK.md"
    private static let harnessName = "HARNESS_REFERENCE.md"

    // MARK: - Map model

    // One row of the primitive→source map, assembled from the harness reference.
    private struct MapEntry {
        let primitive: String
        let cookbookSections: [String]   // e.g. ["3.6"] or ["5.3", "8.15"]
        let package: String              // e.g. "SubstrateTypes"
        let swiftFile: String            // e.g. "SimHash.swift"
    }

    // MARK: - Op vocabulary

    // The cookbook writes operations in a small, stable vocabulary. For each we
    // record (a) the cookbook spelling we look for in the pseudocode body, and
    // (b) the set of acceptable Swift spellings in shipping source. A cookbook
    // op counts as "expected" only when its cookbook spelling appears in the
    // section's fenced pseudocode; it then counts as "present" when ANY of its
    // Swift spellings appears in the source. Spellings differ on purpose:
    // the cookbook says "popcount", Swift says "nonzeroBitCount"; the cookbook
    // says "XOR", Swift uses the "^" operator. Token coverage, not semantics.
    private struct OpToken {
        let label: String                 // shown in the missing-token report
        let cookbookNeedles: [String]     // any match in the cookbook block => expected
        let cookbookCaseSensitive: Bool   // AND/OR/XOR are uppercase words in the cookbook
        let swiftNeedles: [String]        // any match in the source => present
    }

    private static let opVocabulary: [OpToken] = [
        // Bit-population count: cookbook "popcount" -> Swift "nonzeroBitCount"
        // (also accept a literal "popcount" helper name if a lib defines one).
        OpToken(label: "popcount",
                cookbookNeedles: ["popcount"], cookbookCaseSensitive: false,
                swiftNeedles: ["nonzeroBitCount", "popcount", "popCount"]),
        // Boolean bit ops. The cookbook spells these as uppercase words; in
        // Swift they are the bitwise operators. Match the cookbook words
        // case-sensitively so we do not fire on substrings like "or" inside
        // "for" or "and" inside "candidate".
        OpToken(label: "XOR",
                cookbookNeedles: [" XOR ", " XOR\n"], cookbookCaseSensitive: true,
                swiftNeedles: ["^"]),
        OpToken(label: "AND",
                cookbookNeedles: [" AND ", " AND\n"], cookbookCaseSensitive: true,
                swiftNeedles: ["&"]),
        OpToken(label: "OR",
                cookbookNeedles: [" OR ", " OR\n"], cookbookCaseSensitive: true,
                swiftNeedles: ["|"]),
        // Transcendental / float ops. Cookbook lowercase; Swift Foundation/std
        // names. exp matched as a word-ish needle to avoid "expired"/"export".
        OpToken(label: "sqrt",
                cookbookNeedles: ["sqrt"], cookbookCaseSensitive: false,
                swiftNeedles: ["sqrt", ".squareRoot("]),
        OpToken(label: "exp",
                cookbookNeedles: ["exp("], cookbookCaseSensitive: false,
                swiftNeedles: ["exp(", "expf("]),
        OpToken(label: "log",
                cookbookNeedles: ["log("], cookbookCaseSensitive: false,
                swiftNeedles: ["log(", "logf(", "log2(", "log10("]),
        // max() appears in HLC advance and several reductions.
        OpToken(label: "max",
                cookbookNeedles: ["max("], cookbookCaseSensitive: false,
                swiftNeedles: ["max(", ".max("]),
        // Right-shift amounts. The exact shift distance is load-bearing in
        // bit-packing/hash mixing (e.g. HLC packing ">> 40"/">> 56", hash
        // finalizers ">> 30"/">> 27"/">> 31"). A shift distance present in the
        // cookbook block is expected verbatim in the source.
        OpToken(label: ">> 30", cookbookNeedles: [">> 30", ">>30"], cookbookCaseSensitive: true, swiftNeedles: [">> 30", ">>30"]),
        OpToken(label: ">> 31", cookbookNeedles: [">> 31", ">>31"], cookbookCaseSensitive: true, swiftNeedles: [">> 31", ">>31"]),
        OpToken(label: ">> 27", cookbookNeedles: [">> 27", ">>27"], cookbookCaseSensitive: true, swiftNeedles: [">> 27", ">>27"]),
        OpToken(label: ">> 40", cookbookNeedles: [">> 40", ">>40"], cookbookCaseSensitive: true, swiftNeedles: [">> 40", ">>40"]),
        OpToken(label: ">> 56", cookbookNeedles: [">> 56", ">>56"], cookbookCaseSensitive: true, swiftNeedles: [">> 56", ">>56"]),
        OpToken(label: ">> 33", cookbookNeedles: [">> 33", ">>33"], cookbookCaseSensitive: true, swiftNeedles: [">> 33", ">>33"]),
    ]

    // MARK: - Status

    private enum Status: String {
        case match = "MATCH"
        case drift = "DRIFT"
        case skip = "SKIP"
    }

    private struct Result {
        let primitive: String
        let sectionLabel: String     // e.g. "§3.6" or "§5.3+§8.15" or "?"
        let status: Status
        let missing: [String]        // missing tokens (DRIFT) or skip reason (SKIP)
    }

    // MARK: - Entry point

    /// Run the structural source↔cookbook audit. Prints a per-primitive table
    /// and returns the number of primitives that DRIFTED (0 = all matched).
    /// SKIPped primitives (unmappable or missing source) do not count as drift.
    static func run() -> Int {
        let eng = docsEngineeringDir()
        let harnessURL = eng.appendingPathComponent(harnessName)
        let cookbookURL = eng.appendingPathComponent(cookbookName)

        printHeader()

        guard let harnessText = try? String(contentsOf: harnessURL, encoding: .utf8) else {
            print("  (could not read harness reference at \(harnessURL.path))")
            print("  0 matched, 0 drift, 0 skipped")
            return 0
        }
        guard let cookbookText = try? String(contentsOf: cookbookURL, encoding: .utf8) else {
            print("  (could not read cookbook at \(cookbookURL.path))")
            print("  0 matched, 0 drift, 0 skipped")
            return 0
        }

        let entries = parseMap(harnessText: harnessText)
        var results: [Result] = []

        for entry in entries {
            results.append(audit(entry: entry, cookbookText: cookbookText))
        }

        // Emit table.
        let nameW = max(22, (results.map { $0.primitive.count }.max() ?? 0) + 1)
        print(padR("primitive", nameW) + padR("§", 12) + padR("status", 8) + "missing-tokens")
        print(String(repeating: "-", count: nameW + 12 + 8 + 14))
        for r in results {
            let missingCol: String
            switch r.status {
            case .match: missingCol = "—"
            case .drift: missingCol = r.missing.isEmpty ? "(unspecified)" : r.missing.joined(separator: ", ")
            case .skip:  missingCol = r.missing.first ?? "(skipped)"
            }
            print(padR(r.primitive, nameW) + padR(r.sectionLabel, 12) + padR(r.status.rawValue, 8) + missingCol)
        }

        let matched = results.filter { $0.status == .match }.count
        let drifted = results.filter { $0.status == .drift }.count
        let skipped = results.filter { $0.status == .skip }.count
        print(String(repeating: "-", count: nameW + 12 + 8 + 14))
        print("  \(matched) matched, \(drifted) drift, \(skipped) skipped  (of \(results.count) mapped primitives)")
        print("  Reminder: structural/heuristic coverage only — not a semantic-equivalence proof.")
        return drifted
    }

    private static func printHeader() {
        print("== Subsystem 5: source↔cookbook structural audit ==")
        print("  HEURISTIC structural correspondence (magic-constant + operation token coverage).")
        print("  NOT a proof of semantic equivalence. Bit-exact equivalence is proven by the")
        print("  conformance CRC gate (subsystem B+2) and the cross-language comparator (subsystem 3).")
        print("  Cookbook: \(cookbookName)")
        print("  Map:      \(harnessName)  (§2.0 package table + per-primitive § headings)")
        print("")
    }

    // MARK: - Map parsing

    // Build the primitive→(sections, package, swiftFile) map by combining two
    // structures in the harness reference:
    //   1. The §2.0 markdown table rows "| `prim` | Package | `File.swift` | `mod.rs` |"
    //      give package + Swift file.
    //   2. The per-primitive headings "#### `prim` — §X.Y — CRC `0x...`" give the
    //      cookbook section(s). A heading may name two sections, e.g.
    //      "audit_log_fold — §5.3 + §8.15".
    // We key on the primitive name and join. A primitive present in only one of
    // the two structures still appears (with the missing field blank), so the
    // auditor can mark it SKIP rather than silently dropping it.
    private static func parseMap(harnessText: String) -> [MapEntry] {
        var packageOf: [String: String] = [:]
        var fileOf: [String: String] = [:]
        var sectionsOf: [String: [String]] = [:]
        var order: [String] = []   // preserve first-seen order for stable output

        let lines = harnessText.components(separatedBy: "\n")

        // 1) §2.0 table rows. Shape: | `prim` | Package | `File.swift` | `mod.rs` |
        //    We accept any 4+-column row whose first cell is a backticked
        //    snake_case token and whose third cell ends in ".swift".
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("|") else { continue }
            let cells = line
                .split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard cells.count >= 3 else { continue }
            let prim = stripBackticks(cells[0])
            let pkg = stripBackticks(cells[1])
            let file = stripBackticks(cells[2])
            guard isPrimitiveName(prim), file.hasSuffix(".swift") else { continue }
            if packageOf[prim] == nil {
                packageOf[prim] = pkg
                fileOf[prim] = file
                if !order.contains(prim) { order.append(prim) }
            }
        }

        // 2) Per-primitive headings: "#### `prim` — §X.Y — CRC `0x...`"
        //    The section list is every "§N.N" token before "CRC".
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("#### ") else { continue }
            guard let prim = firstBacktickedToken(line), isPrimitiveName(prim) else { continue }
            // Restrict the §-scan to the part before "CRC" so the CRC's own
            // hex (not a section) is never mistaken for a section token.
            let headPart: String
            if let crcRange = line.range(of: "CRC") {
                headPart = String(line[line.startIndex..<crcRange.lowerBound])
            } else {
                headPart = line
            }
            let secs = extractSectionNumbers(headPart)
            if !secs.isEmpty {
                sectionsOf[prim] = secs
                if !order.contains(prim) { order.append(prim) }
            }
        }

        return order.map { prim in
            MapEntry(primitive: prim,
                     cookbookSections: sectionsOf[prim] ?? [],
                     package: packageOf[prim] ?? "",
                     swiftFile: fileOf[prim] ?? "")
        }
    }

    // MARK: - Per-primitive audit

    private static func audit(entry: MapEntry, cookbookText: String) -> Result {
        let label = entry.cookbookSections.isEmpty
            ? "?"
            : "§" + entry.cookbookSections.joined(separator: "+§")

        // SKIP: no package/file mapping resolved.
        guard !entry.package.isEmpty, !entry.swiftFile.isEmpty else {
            return Result(primitive: entry.primitive, sectionLabel: label,
                          status: .skip, missing: ["no source mapping in §2.0 table"])
        }
        // SKIP: no cookbook section resolved.
        guard !entry.cookbookSections.isEmpty else {
            return Result(primitive: entry.primitive, sectionLabel: label,
                          status: .skip, missing: ["no cookbook § in harness heading"])
        }

        // Locate the shipping source file:
        // packages/libs/<Package>/Sources/<Package>/<File>.swift
        let sourceURL = repoRoot()
            .appendingPathComponent("packages/libs")
            .appendingPathComponent(entry.package)
            .appendingPathComponent("Sources")
            .appendingPathComponent(entry.package)
            .appendingPathComponent(entry.swiftFile)
            .standardizedFileURL
        guard let sourceText = try? String(contentsOf: sourceURL, encoding: .utf8) else {
            return Result(primitive: entry.primitive, sectionLabel: label,
                          status: .skip, missing: ["source not found: \(entry.package)/\(entry.swiftFile)"])
        }

        // Gather the cookbook section body and its fenced pseudocode for each
        // mapped section, then concatenate.
        var bodies: [String] = []
        var fenced: [String] = []
        for sec in entry.cookbookSections {
            if let body = sectionBody(cookbookText: cookbookText, section: sec) {
                bodies.append(body)
                fenced.append(fencedBlocks(in: body))
            }
        }
        guard !bodies.isEmpty else {
            return Result(primitive: entry.primitive, sectionLabel: label,
                          status: .skip, missing: ["cookbook section(s) \(label) not found"])
        }
        let sectionBodyText = bodies.joined(separator: "\n")
        let fencedText = fenced.joined(separator: "\n")

        // Derive expected SIGNATURE TOKENS:
        //  (a) magic hex constants — read ONLY from the fenced pseudocode, so
        //      stray CRC hexes in prose/headings never count as algorithm
        //      magic numbers. (Cookbook fenced blocks are pseudocode; CRCs
        //      live in headings and the §18 summary, outside fences.)
        let expectedHex = magicHexConstants(in: fencedText)
        //  (b) operation keywords — read from the fenced pseudocode (the
        //      operation vocabulary lives in the algorithm, not the prose).
        let expectedOps = opVocabulary.filter { op in
            op.cookbookNeedles.contains { needle in
                contains(fencedText, needle, caseSensitive: op.cookbookCaseSensitive)
            }
        }

        // If the section had no fenced pseudocode (e.g. a struct-free prose
        // section, or a pure cross-reference like §8.15 "Specified in §5.3"),
        // expectedHex and expectedOps may both be empty. In that case there is
        // nothing structural to check against — SKIP rather than vacuously
        // declare MATCH (a vacuous MATCH would hide real drift).
        guard !(expectedHex.isEmpty && expectedOps.isEmpty) else {
            return Result(primitive: entry.primitive, sectionLabel: label,
                          status: .skip, missing: ["no hex constants or ops in cookbook pseudocode"])
        }

        // Check presence in the shipping source.
        var missing: [String] = []

        // Hex: case-insensitive compare on the numeric body (strip "0x",
        // drop leading zeros) so 0x01000193 in source matches 0x1000193 etc.
        let sourceHexCanon = Set(allHexLiterals(in: sourceText).map { canonHex($0) })
        for hex in expectedHex {
            if !sourceHexCanon.contains(canonHex(hex)) {
                missing.append(hex)
            }
        }

        // Ops: present if any acceptable Swift spelling appears.
        for op in expectedOps {
            let present = op.swiftNeedles.contains { sourceText.contains($0) }
            if !present {
                missing.append(op.label)
            }
        }

        // MATCH iff nothing expected is missing (all hex present and all the
        // ops the cookbook block uses are present). Otherwise DRIFT.
        if missing.isEmpty {
            return Result(primitive: entry.primitive, sectionLabel: label,
                          status: .match, missing: [])
        } else {
            return Result(primitive: entry.primitive, sectionLabel: label,
                          status: .drift, missing: missing)
        }
    }

    // MARK: - Cookbook section extraction

    // Return the body text of cookbook section "X.Y": every line after the
    // heading "### §X.Y." up to (but excluding) the next "### " or "## "
    // heading. Returns nil if the heading is not found.
    private static func sectionBody(cookbookText: String, section: String) -> String? {
        let lines = cookbookText.components(separatedBy: "\n")
        // Heading forms tolerated: "### §3.6." and "### §3.6 " — match the
        // section number followed by a non-digit boundary so "§3.6" does not
        // also match "§3.60".
        var startIdx: Int? = nil
        for (i, line) in lines.enumerated() {
            guard line.hasPrefix("### ") else { continue }
            if headingMatchesSection(line, section: section) {
                startIdx = i + 1
                break
            }
        }
        guard let s = startIdx else { return nil }
        var collected: [String] = []
        var i = s
        while i < lines.count {
            let line = lines[i]
            if line.hasPrefix("### ") || line.hasPrefix("## ") { break }
            collected.append(line)
            i += 1
        }
        return collected.joined(separator: "\n")
    }

    // Does an "### " heading line correspond to section X.Y? We look for the
    // literal "§<section>" and require a clean right boundary so "§3.6" matches
    // "§3.6." and "§3.6 " (the cookbook writes "### §3.6. Title") but never
    // "§3.60". The boundary is clean when the next char is end-of-line, or a
    // non-digit that is not the start of a deeper number. A trailing "." is the
    // common heading form ("§3.6.") and is always a clean boundary because the
    // dot is immediately followed by a space in every heading.
    private static func headingMatchesSection(_ line: String, section: String) -> Bool {
        let needle = "§" + section
        guard let r = line.range(of: needle) else { return false }
        let after = r.upperBound
        if after == line.endIndex { return true }
        let nextChar = line[after]
        // A digit directly after means we matched a prefix of a longer section
        // number (e.g. needle "§3.6" inside "§3.60") — reject.
        return !nextChar.isNumber
    }

    // Concatenate the contents of every ``` ... ``` fenced block in a body.
    // Fence detection: a line whose trimmed content starts with three
    // backticks toggles fenced state. Lines inside fences are collected.
    private static func fencedBlocks(in body: String) -> String {
        var inside = false
        var out: [String] = []
        for raw in body.components(separatedBy: "\n") {
            let t = raw.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("```") {
                inside.toggle()
                continue
            }
            if inside { out.append(raw) }
        }
        return out.joined(separator: "\n")
    }

    // MARK: - Token helpers

    // All hex literals 0x followed by >=3 hex digits.
    private static func allHexLiterals(in text: String) -> [String] {
        regexMatches(pattern: "0[xX][0-9A-Fa-f]{3,}", in: text)
    }

    // Magic hex constants from cookbook pseudocode: de-duplicated, original
    // spelling preserved for the report.
    private static func magicHexConstants(in fencedText: String) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for h in allHexLiterals(in: fencedText) {
            let key = canonHex(h)
            if !seen.contains(key) {
                seen.insert(key)
                out.append(h)
            }
        }
        return out
    }

    // Canonical hex key: lowercase, "0x" stripped, leading zeros dropped.
    private static func canonHex(_ s: String) -> String {
        var body = s.lowercased()
        if body.hasPrefix("0x") { body.removeFirst(2) }
        while body.count > 1 && body.hasPrefix("0") { body.removeFirst() }
        return body
    }

    private static func contains(_ haystack: String, _ needle: String, caseSensitive: Bool) -> Bool {
        if caseSensitive { return haystack.contains(needle) }
        return haystack.range(of: needle, options: .caseInsensitive) != nil
    }

    // MARK: - Small parse utilities

    private static func stripBackticks(_ s: String) -> String {
        s.trimmingCharacters(in: CharacterSet(charactersIn: "`")).trimmingCharacters(in: .whitespaces)
    }

    // The first `backticked` token on a line, with backticks removed.
    private static func firstBacktickedToken(_ line: String) -> String? {
        guard let open = line.firstIndex(of: "`") else { return nil }
        let afterOpen = line.index(after: open)
        guard afterOpen < line.endIndex,
              let close = line[afterOpen...].firstIndex(of: "`") else { return nil }
        return String(line[afterOpen..<close])
    }

    // A primitive name is lowercase letters, digits, and underscores.
    private static func isPrimitiveName(_ s: String) -> Bool {
        guard !s.isEmpty else { return false }
        return s.allSatisfy { $0.isLowercase || $0.isNumber || $0 == "_" }
    }

    // Extract section numbers "N.N" that follow a "§" in the given text.
    private static func extractSectionNumbers(_ text: String) -> [String] {
        // Match "§" then digits.dot.digits. e.g. "§5.3", "§12.3".
        let raw = regexMatches(pattern: "§[0-9]+\\.[0-9]+", in: text)
        var seen = Set<String>()
        var out: [String] = []
        for m in raw {
            let num = String(m.dropFirst())   // drop the §
            if !seen.contains(num) { seen.insert(num); out.append(num) }
        }
        return out
    }

    // MARK: - Regex helper (Foundation NSRegularExpression)

    private static func regexMatches(pattern: String, in text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        return re.matches(in: text, range: range).map { ns.substring(with: $0.range) }
    }

    // MARK: - Output formatting

    private static func padR(_ s: String, _ n: Int) -> String {
        s.count >= n ? s : s + String(repeating: " ", count: n - s.count)
    }
}
