import Testing
@testable import mcp_benchmarker

// CaptureSpreadCorpusTests.swift — golden pins for the capture-spread corpus
// projection (spread, burst, splitcap).
//
// These tests pin three contracts:
//
//   1. Byte-identity of spread and burst projections across runs (v1 contract:
//      same seed → same corpus → same records in both variants).
//   2. splitcap projection (v2): captureDate carries the designed per-record
//      dates (O-side alive); eventTime is held constant at T0 for all records
//      (T-side signal killed). Comparing splitcap decayed-vs-balanced isolates
//      the O projection alone; comparing against v1 burst decayed-vs-balanced
//      (T-side alone) completes the two-dimensional decomposition.
//   3. Cross-port golden pin: both Swift and Rust ports must produce the same
//      SeedFileRecord for the same corpus record under the splitcap projection.
//
// The small corpus (seed=42, probes=2, distractors=5) keeps every test fast
// while exercising the full RNG call sequence for two topics and five
// distractors. The seed and counts must not be changed without updating the
// corresponding Rust tests in capturespread_corpus.rs.

@Suite("CaptureSpreadCorpus") struct CaptureSpreadCorpusTests {

    // MARK: - Spread golden pins (v1 behaviour must remain byte-identical)

    /// Spread variant: every seed record has captureDate populated and
    /// eventTime == captureDate (v1 no-confound rule: no event-vs-capture split).
    @Test func spreadProjectionCaptureEqualsEventTime() {
        let corpus = generateCaptureSpreadCorpus(seed: 42, probeTopicCount: 2, distractorCount: 5)
        let records = captureSpreadSeedRecords(from: corpus, variant: .spread)
        // O-side: captureDate is set for every record.
        #expect(records.allSatisfy { $0.captureDate != nil },
                "spread: every record must have captureDate set")
        // T-side == O-side (v1 no-confound): eventTime equals captureDate.
        for r in records {
            #expect(r.eventTime == r.captureDate,
                    "spread: record \(r.id) eventTime \(r.eventTime) != captureDate \(r.captureDate ?? "nil")")
        }
    }

    // MARK: - Burst golden pins (v1 behaviour must remain byte-identical)

    /// Burst variant: captureDate is omitted for every record so the importer
    /// stamps all records with the batch wall-clock (the null-control cell).
    /// eventTime still carries the corpus captureDate (T-side spread preserved).
    @Test func burstProjectionNoCaptureDate() {
        let corpus = generateCaptureSpreadCorpus(seed: 42, probeTopicCount: 2, distractorCount: 5)
        let records = captureSpreadSeedRecords(from: corpus, variant: .burst)
        // O-side: captureDate is absent for every record (batch wall-clock).
        #expect(records.allSatisfy { $0.captureDate == nil },
                "burst: captureDate must be nil for every record")
        // T-side: eventTime is still the corpus captureDate (T-side spread alive).
        let spreadRecords = captureSpreadSeedRecords(from: corpus, variant: .spread)
        for (b, s) in zip(records, spreadRecords) {
            #expect(b.eventTime == s.eventTime,
                    "burst eventTime \(b.eventTime) must equal spread eventTime \(s.eventTime)")
        }
    }

    // MARK: - Splitcap golden pins (v2 — new in this build)

    /// splitcap variant: captureDate carries the designed per-record date (O-side
    /// alive); eventTime is held constant at T0 for every record (T-side killed).
    /// The scientific contract: splitcap decayed-vs-balanced difference measures
    /// the O projection alone; comparing against the v1 burst difference (T-side
    /// alone) completes the decomposition.
    @Test func splitcapProjectionKillsEventTimeSpread() {
        let corpus = generateCaptureSpreadCorpus(seed: 42, probeTopicCount: 2, distractorCount: 5)
        let records = captureSpreadSeedRecords(from: corpus, variant: .splitcap)
        // T-side killed: all eventTime values are the same constant (T0).
        let t0 = "2026-01-01T00:00:00Z"
        #expect(records.allSatisfy { $0.eventTime == t0 },
                "splitcap: every record must have eventTime == T0 (\(t0)) to kill the T-side signal")
        // O-side alive: captureDate is set for every record.
        #expect(records.allSatisfy { $0.captureDate != nil },
                "splitcap: every record must have captureDate set (O-side alive)")
    }

    /// splitcap variant: captureDate values match the spread variant exactly
    /// (same designed O-side clock). The only difference from spread is eventTime.
    @Test func splitcapProjectionCaptureDatesMatchSpread() {
        let corpus = generateCaptureSpreadCorpus(seed: 42, probeTopicCount: 2, distractorCount: 5)
        let spreadRecords = captureSpreadSeedRecords(from: corpus, variant: .spread)
        let splitcapRecords = captureSpreadSeedRecords(from: corpus, variant: .splitcap)
        #expect(spreadRecords.count == splitcapRecords.count,
                "spread and splitcap must have the same record count")
        for (sp, sc) in zip(spreadRecords, splitcapRecords) {
            #expect(sp.captureDate == sc.captureDate,
                    "splitcap captureDate for \(sc.id) must equal spread captureDate (O-side identical)")
        }
    }

    /// Cross-port golden pin: record "cs-s-0-0" (first stale item, topic 0,
    /// seed=42) in the splitcap projection must have eventTime == T0 and a
    /// non-empty captureDate that matches the spread variant. Both Swift and
    /// Rust ports must satisfy this assertion.
    @Test func splitcapGoldenPinFirstStaleRecord() {
        let corpus = generateCaptureSpreadCorpus(seed: 42, probeTopicCount: 2, distractorCount: 5)
        let spreadRecords = captureSpreadSeedRecords(from: corpus, variant: .spread)
        let splitcapRecords = captureSpreadSeedRecords(from: corpus, variant: .splitcap)

        // "cs-s-0-0" must exist in the corpus.
        guard let spreadRecord = spreadRecords.first(where: { $0.id == "cs-s-0-0" }),
              let splitcapRecord = splitcapRecords.first(where: { $0.id == "cs-s-0-0" }) else {
            Issue.record("golden-pin: record 'cs-s-0-0' not found in corpus (seed=42)")
            return
        }

        // T-side killed: eventTime is T0, not the corpus captureDate.
        #expect(splitcapRecord.eventTime == "2026-01-01T00:00:00Z",
                "splitcap cs-s-0-0 eventTime must be T0")
        // O-side alive: captureDate matches spread.
        #expect(splitcapRecord.captureDate == spreadRecord.captureDate,
                "splitcap cs-s-0-0 captureDate must equal spread captureDate")
        // captureDate is not T0 (otherwise the O-side would also be collapsed).
        #expect(splitcapRecord.captureDate != "2026-01-01T00:00:00Z",
                "splitcap cs-s-0-0 captureDate must differ from T0 (O-side is spread, not burst)")
    }

    // MARK: - Record count invariant (all three variants)

    /// All three variants must produce the same number of records. The variant
    /// only changes timestamp fields, never record identity or count.
    @Test func allVariantsSameRecordCount() {
        let corpus = generateCaptureSpreadCorpus(seed: 42, probeTopicCount: 2, distractorCount: 5)
        let spread   = captureSpreadSeedRecords(from: corpus, variant: .spread)
        let burst    = captureSpreadSeedRecords(from: corpus, variant: .burst)
        let splitcap = captureSpreadSeedRecords(from: corpus, variant: .splitcap)
        #expect(spread.count == burst.count && burst.count == splitcap.count,
                "all variants must produce the same record count")
    }

    /// All three variants must produce records in the same order (captureDate
    /// sort from the corpus record, which is the ingestion order invariant).
    @Test func allVariantsSameRecordOrder() {
        let corpus = generateCaptureSpreadCorpus(seed: 42, probeTopicCount: 2, distractorCount: 5)
        let spread   = captureSpreadSeedRecords(from: corpus, variant: .spread)
        let burst    = captureSpreadSeedRecords(from: corpus, variant: .burst)
        let splitcap = captureSpreadSeedRecords(from: corpus, variant: .splitcap)
        let spreadIDs   = spread.map(\.id)
        let burstIDs    = burst.map(\.id)
        let splitcapIDs = splitcap.map(\.id)
        #expect(spreadIDs == burstIDs,   "spread and burst must have the same record order")
        #expect(spreadIDs == splitcapIDs, "spread and splitcap must have the same record order")
    }
}
