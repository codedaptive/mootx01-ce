import Testing
import Foundation
@testable import mcp_benchmarker

// GauntletGeneratorTests — the corpus generator's determinism + tier structure +
// ground-truth consistency (Phase 2.1). These are pure unit tests: no live
// backend, no Date(), no filesystem (except the byte-identity test, which writes
// to a temp dir and compares bytes).

@Suite("Gauntlet RNG")
struct GauntletRNGTests {

    @Test("SplitMix64 is deterministic: same seed → same sequence")
    func deterministicSequence() {
        var a = SplitMix64(seed: 0xDEAD_BEEF)
        var b = SplitMix64(seed: 0xDEAD_BEEF)
        for _ in 0..<1000 {
            #expect(a.next() == b.next())
        }
    }

    @Test("SplitMix64 differs across seeds")
    func differsAcrossSeeds() {
        var a = SplitMix64(seed: 1)
        var b = SplitMix64(seed: 2)
        // Overwhelmingly likely to differ within the first few draws; assert at
        // least one of the first ten draws differs.
        var anyDiffer = false
        for _ in 0..<10 where a.next() != b.next() { anyDiffer = true }
        #expect(anyDiffer)
    }

    @Test("SplitMix64 matches the canonical reference vector for seed 0")
    func canonicalVector() {
        // The published SplitMix64 first outputs for state seeded at 0. These are
        // the reference values from the canonical algorithm; they pin the exact
        // constants so a future edit to the mixing function is caught.
        var rng = SplitMix64(seed: 0)
        let expected: [UInt64] = [
            0xE220A8397B1DCDAF,
            0x6E789E6AA1B965F4,
            0x06C45D188009454F,
            0xF88BB8A8724C81EC,
            0x1B39896A51A8749B,
        ]
        for e in expected {
            #expect(rng.next() == e)
        }
    }

    @Test("upTo stays in range")
    func upToInRange() {
        var rng = SplitMix64(seed: 42)
        for _ in 0..<10_000 {
            let v = rng.upTo(7)
            #expect(v >= 0 && v < 7)
        }
    }
}

@Suite("Gauntlet generator")
struct GauntletGeneratorTests {

    private func evenProfile(perTier: Int = 3, distractors: Int = 4) -> GauntletProfile {
        GauntletProfile.evenMix(perTier: perTier, distractorsPerNeedle: distractors)
    }

    @Test("same seed → byte-identical corpus.jsonl and needles.json")
    func byteIdenticalCorpus() throws {
        let gen = GauntletGenerator(profile: evenProfile())
        let a = gen.generate(seed: 12345)
        let b = gen.generate(seed: 12345)

        // In-memory: records and needles are equal.
        #expect(a.records == b.records)
        #expect(a.needles == b.needles)

        // On-disk: write both and compare the file bytes.
        let dirA = try tmpDir(); let dirB = try tmpDir()
        defer { try? FileManager.default.removeItem(at: dirA)
                try? FileManager.default.removeItem(at: dirB) }
        let (corpusA, needlesA) = try GauntletIO.writeCorpus(a, toDirectory: dirA.path)
        let (corpusB, needlesB) = try GauntletIO.writeCorpus(b, toDirectory: dirB.path)
        #expect(try Data(contentsOf: corpusA) == Data(contentsOf: corpusB))
        #expect(try Data(contentsOf: needlesA) == Data(contentsOf: needlesB))
    }

    @Test("different seeds → different corpus")
    func differentSeedsDiffer() {
        let gen = GauntletGenerator(profile: evenProfile())
        let a = gen.generate(seed: 1)
        let b = gen.generate(seed: 2)
        #expect(a.records != b.records)
    }

    @Test("needle count matches the tier profile")
    func needleCountMatchesProfile() {
        let profile = GauntletProfile(tierCounts: [.lexical: 2, .semantic: 3, .temporal: 1,
                                                   .split: 4, .scatter: 2],
                                      distractorsPerNeedle: 3)
        let corpus = GauntletGenerator(profile: profile).generate(seed: 7)
        #expect(corpus.needles.count == 2 + 3 + 1 + 4 + 2)
        for tier in NoiseTier.allCases {
            let want = profile.tierCounts[tier] ?? 0
            let got = corpus.needles.filter { $0.tier == tier }.count
            #expect(got == want, "tier \(tier.rawValue): want \(want) got \(got)")
        }
    }

    @Test("each needle's ground truth is internally consistent")
    func groundTruthConsistent() {
        let corpus = GauntletGenerator(profile: evenProfile()).generate(seed: 99)
        let recordByID = Dictionary(uniqueKeysWithValues: corpus.records.map { ($0.id, $0) })
        for needle in corpus.needles {
            // The needle id resolves to a needle record with matching content.
            let rec = recordByID[needle.id]
            #expect(rec != nil)
            #expect(rec?.role == .needle)
            #expect(rec?.content == needle.content, "needle \(needle.id) content mismatch")
            #expect(rec?.tier == needle.tier)
            #expect(needle.expectedRank == 1)
            // Every distractor id resolves to a distractor record of the same tier
            // and the same needle.
            for did in needle.distractorIDs {
                let d = recordByID[did]
                #expect(d != nil, "missing distractor \(did)")
                #expect(d?.role == .distractor)
                #expect(d?.needleID == needle.id)
                #expect(d?.tier == needle.tier)
            }
            // The needle's correct value must NOT appear in any of its distractors
            // (else a distractor would accidentally be a correct answer).
            for did in needle.distractorIDs {
                if let d = recordByID[did] {
                    #expect(d.content != needle.content,
                            "distractor \(did) duplicates the needle answer")
                }
            }
        }
    }

    @Test("T1 lexical distractors share the subject token but assert a different fact")
    func tier1Structure() {
        let profile = GauntletProfile(tierCounts: [.lexical: 5], distractorsPerNeedle: 3)
        let corpus = GauntletGenerator(profile: profile).generate(seed: 3)
        let recordByID = Dictionary(uniqueKeysWithValues: corpus.records.map { ($0.id, $0) })
        for needle in corpus.needles {
            // The subject is the leading phrase of the needle content up to the
            // first attribute verb; cheaper to assert the distractor shares a long
            // leading prefix (the subject) yet is a different string.
            let subjectPrefix = String(needle.content.prefix(8))
            for did in needle.distractorIDs {
                let d = recordByID[did]!
                #expect(d.content.hasPrefix(subjectPrefix),
                        "T1 distractor should share the subject token")
                #expect(d.content != needle.content)
            }
        }
    }

    @Test("T3 temporal distractors are marked superseded and the needle marked current")
    func tier3Structure() {
        let profile = GauntletProfile(tierCounts: [.temporal: 5], distractorsPerNeedle: 3)
        let corpus = GauntletGenerator(profile: profile).generate(seed: 4)
        let recordByID = Dictionary(uniqueKeysWithValues: corpus.records.map { ($0.id, $0) })
        for needle in corpus.needles {
            #expect(needle.content.contains("current as of"),
                    "T3 needle must be marked current")
            for did in needle.distractorIDs {
                let d = recordByID[did]!
                #expect(d.content.contains("superseded"),
                        "T3 distractor must be marked superseded")
            }
        }
    }

    @Test("T4 split needles have a partner holding the value, withheld from the needle")
    func tier4Structure() {
        let profile = GauntletProfile(tierCounts: [.split: 5], distractorsPerNeedle: 2)
        let corpus = GauntletGenerator(profile: profile).generate(seed: 5)
        let recordByID = Dictionary(uniqueKeysWithValues: corpus.records.map { ($0.id, $0) })
        for needle in corpus.needles {
            #expect(needle.splitPartnerID != nil, "T4 needle must have a split partner")
            let partner = recordByID[needle.splitPartnerID!]
            #expect(partner != nil)
            #expect(partner?.role == .splitPartner)
            // The needle points at a reference code; the partner resolves it.
            #expect(needle.content.contains("reference"))
            #expect(partner!.content.contains("Reference"))
        }
    }

    @Test("T5 scatter files the needle away from its distractors' home location")
    func tier5Structure() {
        let profile = GauntletProfile(tierCounts: [.scatter: 5], distractorsPerNeedle: 3)
        let corpus = GauntletGenerator(profile: profile).generate(seed: 6)
        let recordByID = Dictionary(uniqueKeysWithValues: corpus.records.map { ($0.id, $0) })
        for needle in corpus.needles {
            let needleWing = needle.location.split(separator: "/").first.map(String.init)
            for did in needle.distractorIDs {
                let d = recordByID[did]!
                let dWing = d.location.split(separator: "/").first.map(String.init)
                #expect(needleWing != dWing,
                        "T5 needle wing (\(needleWing ?? "?")) should differ from distractor wing (\(dWing ?? "?"))")
            }
        }
    }

    @Test("difficulty dial: distractor count drives record count")
    func difficultyDial() {
        let easy = GauntletGenerator(profile: GauntletProfile(tierCounts: [.lexical: 4],
                                                              distractorsPerNeedle: 1))
            .generate(seed: 8)
        let hard = GauntletGenerator(profile: GauntletProfile(tierCounts: [.lexical: 4],
                                                              distractorsPerNeedle: 8))
            .generate(seed: 8)
        #expect(hard.records.count > easy.records.count)
        // Each needle gains exactly the extra distractors.
        // easy: 4 needles × (1 needle + 1 distractor) = 8; hard: 4 × (1 + 8) = 36.
        #expect(easy.records.count == 4 * (1 + 1))
        #expect(hard.records.count == 4 * (1 + 8))
    }

    @Test("corpus round-trips through write/load unchanged")
    func ioRoundTrip() throws {
        let corpus = GauntletGenerator(profile: evenProfile()).generate(seed: 555)
        let dir = try tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try GauntletIO.writeCorpus(corpus, toDirectory: dir.path)
        let loaded = try GauntletIO.loadCorpus(fromDirectory: dir.path)
        #expect(loaded.seed == corpus.seed)
        #expect(loaded.records == corpus.records)
        #expect(loaded.needles == corpus.needles)
        #expect(loaded.distractorsPerNeedle == corpus.distractorsPerNeedle)
    }

    // ── Cross-port expectedRank round-trip ───────────────────────────────────
    //
    // Gate: `expectedRank` survives a full writeCorpus → loadCorpus round-trip
    // and the JSON on disk carries the camelCase key `"expectedRank"` (the name
    // Swift's Codable derives from the property). The corpus is generated from
    // the REAL Swift writer (GauntletGenerator.generate) and written by the REAL
    // I/O path (GauntletIO.writeCorpus), so neither the generator output nor the
    // JSON encoding is assumed — they are exercised. Asserting that decode merely
    // succeeded would not discriminate a wrong key; this test asserts the value.

    @Test("expectedRank is 1 and survives corpus IO round-trip")
    func expectedRankSurvivesIOAndEqualsOne() throws {
        // Generate from the real Swift writer (GauntletGenerator, GauntletCorpus.swift).
        // Even mix, 1 per tier, 1 distractor: minimal corpus that covers all tiers.
        let corpus = GauntletGenerator(
            profile: GauntletProfile(
                tierCounts: [.lexical: 1, .semantic: 1, .temporal: 1, .split: 1, .scatter: 1],
                distractorsPerNeedle: 1
            )
        ).generate(seed: 42)
        #expect(!corpus.needles.isEmpty, "corpus must have at least one needle")

        let dir = try tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Write using the real Swift I/O path (GauntletIO.writeCorpus).
        let (_, needlesURL) = try GauntletIO.writeCorpus(corpus, toDirectory: dir.path)

        // Verify the JSON on disk carries the camelCase key, not snake_case.
        let rawBytes = try Data(contentsOf: needlesURL)
        let rawString = String(bytes: rawBytes, encoding: .utf8) ?? ""
        #expect(rawString.contains("\"expectedRank\""),
                "needles.json must contain \"expectedRank\" (camelCase) — that is what Swift's Codable writes")
        #expect(!rawString.contains("\"expected_rank\""),
                "needles.json must NOT contain \"expected_rank\" — that would break the Rust decoder before the serde rename fix")

        // Load back with the real Swift reader and assert the VALUE is preserved.
        let loaded = try GauntletIO.loadCorpus(fromDirectory: dir.path)
        for needle in loaded.needles {
            #expect(needle.expectedRank == 1,
                    "needle \(needle.id): expectedRank must be 1 (the value GauntletGenerator writes)")
        }
    }

    // ── Cross-port corpus gate ────────────────────────────────────────────────
    //
    // CROSS-PORT GATE — Swift decodes a Rust-written gauntlet corpus.
    //
    // The fixture `corpus_rust_written/` (corpus-42.jsonl + needles-42.json)
    // was PRODUCED BY THE RUST PORT's `mcp-benchmarker-rs gauntlet-corpus`
    // (GauntletGenerator::generate + write_corpus, serde_json) from seed 42,
    // even mix (1 per tier, 1 distractor per needle). This test proves the
    // Swift production loader reads the Rust writer's bytes field-for-field —
    // every field of the first needle is asserted individually so a key-name
    // divergence or value mismatch in any field is immediately visible. The
    // Rust twin (tests/cross_port_gauntlet_corpus.rs `decodes_swift_written_corpus`)
    // decodes the Swift-written fixture.

    @Test("cross-port corpus gate: Swift decodes Rust-written corpus field-for-field")
    func decodesRustWrittenCorpus() throws {
        // Load the Rust-written fixture through the PRODUCTION Swift loader
        // (GauntletIO.loadCorpus), not a bare JSONDecoder call. The production
        // loader exercises the full decode path including corpus.jsonl record
        // parsing and NeedlesFile deserialization.
        let fixtureDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("corpus_rust_written")
            .path
        let corpus = try GauntletIO.loadCorpus(fromDirectory: fixtureDir)

        // Top-level corpus fields.
        #expect(corpus.seed == 42)
        #expect(corpus.distractorsPerNeedle == 1)
        #expect(corpus.needles.count == 5)
        #expect(corpus.records.count == 11)

        // First needle — T1 lexical, no split partner.
        // All eight Needle fields are asserted individually so any key-name
        // divergence or value drift in either port is immediately visible.
        let n0 = try #require(corpus.needles.first)
        #expect(n0.id       == "n0000",
            "needle id mismatch — Swift loader did not read Rust-written id")
        #expect(n0.query    == "What is the charter year of the Quillon Charter?",
            "needle query mismatch")
        #expect(n0.content  == "the Quillon Charter was chartered in the year 1926.",
            "needle content mismatch — GOLDEN PIN; matches crossPortGoldenPin")
        #expect(n0.tier     == .lexical,
            "needle tier mismatch — Rust writes T1; Codable must decode NoiseTier.lexical")
        #expect(n0.location == "Ledger/quillon-charter",
            "needle location mismatch")
        #expect(n0.distractorIDs == ["n0000-t1-0"],
            "distractor ids mismatch — Rust writes camelCase key distractorIDs")
        #expect(n0.splitPartnerID == nil,
            "T1 needle must have no split partner; Rust writes splitPartnerID: null")
        #expect(n0.expectedRank  == 1,
            "expectedRank mismatch — Rust writes camelCase expectedRank")

        // Spot-check the T4 needle (split): splitPartnerID must decode from
        // Rust's explicit null on non-split needles and string on split needles.
        let n3 = corpus.needles[3]
        #expect(n3.tier == .split,
            "fourth needle must be T4 split")
        #expect(n3.splitPartnerID == "n0003-partner",
            "T4 split partner id must decode from Rust-written splitPartnerID")
        #expect(n3.expectedRank == 1,
            "T4 needle expectedRank must be 1")
    }

    // ── Cross-port golden pin ─────────────────────────────────────────────────

    @Test("cross-port golden pin: seed 42 even mix corpus[0] content is stable")
    func crossPortGoldenPin() {
        // GOLDEN PIN: seed=42, even mix (1 per tier, 1 distractor per needle).
        // corpus[0].content must match the Rust port exactly so drift in either
        // generator is caught before a run contaminates published results.
        // DO NOT change this expected string without also updating the Rust twin
        // in gauntlet_corpus.rs (GOLDEN_PIN_SEED = 42, same profile).
        let corpus = GauntletGenerator(
            profile: GauntletProfile(
                tierCounts: [.lexical: 1, .semantic: 1, .temporal: 1, .split: 1, .scatter: 1],
                distractorsPerNeedle: 1
            )
        ).generate(seed: 42)
        #expect(!corpus.records.isEmpty, "golden-pin corpus must not be empty")
        let first = corpus.records[0].content
        let expected = "the Quillon Charter was chartered in the year 1926."
        #expect(first == expected,
                "corpus[0].content mismatch — GOLDEN PIN broken. Update Rust twin in gauntlet_corpus.rs when changing.")
    }

    // MARK: - helpers

    private func tmpDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gauntlet-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
