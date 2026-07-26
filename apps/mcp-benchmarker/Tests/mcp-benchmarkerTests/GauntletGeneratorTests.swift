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

    // MARK: - helpers

    private func tmpDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gauntlet-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
