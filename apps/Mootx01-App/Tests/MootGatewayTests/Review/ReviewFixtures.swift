import Foundation
import AriaMCP
@testable import MootGateway

// MARK: - Review fixtures  (FAB5-G1 Part 3)
//
// PROVENANCE OF THESE STRINGS. Every response in `populated` below was captured
// VERBATIM from a live local MOOTx01 estate on 2026-07-24 through the resident
// daemon's ARIA surface, then truncated in row count only — no line was reworded,
// reordered, or invented. Truncation points are marked. The one exception is
// `moot_fact_search`, noted at its own definition: no live capture was taken, so
// its rows are transcribed from the code that formats them
// (ToolDispatch.runFactSearch). Both provenance classes are labelled so a future
// reader never has to guess which is which.
//
// Fixtures exist so builder behaviour is deterministic and testable without a
// live estate. They are not a substitute for the live smoke run — that is
// recorded separately in the completion report.

enum ReviewFixtures {

    // MARK: Populated responses (live capture, 2026-07-24)

    /// `moot_lens_theme_weather` — 20 rooms live; first five rising/fading rows
    /// kept plus the trailing `hint:` line the lens appends on thin estates
    /// (the parser must skip it).
    static let themeWeather = """
        theme_weather: 20 result(s)
          - 820E4924-F81A-4EB3-9F74-F2ADCCF73483 momentum=0.017680074613053376
          - 569EE15B-8950-4539-879D-0262DAA5DC3A momentum=0.013475476812148085
          - 3F00B735-2D8B-4C10-B908-3DC51FDA9283 momentum=0.005434496707719977
          - 2D23EDF6-1DCD-4916-9983-F5C8A1BDF65A momentum=-0.0003194910701785972
          - F46592A7-FD76-4FB4-A90E-170871D089FF momentum=-0.007558014664944129
        hint: lens results are thin — try scope: active for a broader search
        """

    /// `moot_lens_keystones` (wing "Agentic Memory", topK 5) — complete live response.
    static let keystones = """
        keystones: 5 result(s)
          - 3D2EE55F-CAE5-4A8A-846E-0BFD9AC413E7 centrality=0.7071064739073133
          - 057E744D-CEA8-4B40-A2E1-62118D79870D centrality=0.0653720734540243
          - 058DAAE5-1275-4E4B-9B48-65B6DAD56886 centrality=0.0653720734540243
          - 07A0084E-EC53-4F61-AB65-D497A8529B09 centrality=0.0653720734540243
          - 081AB739-249B-4A38-8D5B-AD94C985F10D centrality=0.0653720734540243
        """

    /// `moot_lens_cohesion` (threshold 1.5, estate mode) — complete live response.
    static let cohesion = """
        cohesion_outliers (considered 50): 6 result(s)
          - D99B504F-C344-4A24-900E-227826AE4D0F
          - 102E33DF-2D7D-4349-A507-19DB8D435DE3
          - 8048B4B8-9C2E-4676-817D-B5A56ED21AAA
          - 2E5137AB-E05A-4985-97AC-D076F36164C6
          - 151B0D83-B72E-405C-B778-2503653C7CBF
          - DA7CFD5E-51A0-460C-B70F-974EE3270462
        """

    /// `moot_lens_drift` — live response for splitAt 2026-07-17T00:00:00Z. The
    /// zeros are the estate's real reading (nothing filed before the split within
    /// the recalled frame), so this doubles as the "measurable but zero" case.
    static let drift = """
        drift: before=0 after=50
        jensenShannon: 0.0
        klDivergence: 0.0
        """

    /// `moot_lens_contradiction` — live: 13 tunnels, 81 conflicting pairs. Kept:
    /// two visible tunnel rows, one `<hidden>`-endpoint row (the MCP disclosure
    /// ceiling redacting a Restricted/Secret drawer), the real
    /// `conflicting_facts` header count, and two complete fact groups.
    static let contradiction = """
        contradicts_tunnels: 13
          0816C3B2-651D-43F5-82B1-88900DEEC8A0 contradicts 4F0C3009-CB52-47F9-9E96-4EE8DBB87AC4 (tunnel DAAAE428-B717-4053-93F7-77AD5E561438) [proposed (agent-derived, unreviewed) — accept/reject via moot_review_tunnel]
          EB25F987-540B-4DEF-9D8A-6AA60D3F94E5 contradicts FF938066-669D-4DDB-B11E-97CCD93146EE (tunnel B1D33E21-4E2A-47DA-B836-B548145EEC19) [proposed (agent-derived, unreviewed) — accept/reject via moot_review_tunnel]
          <hidden> contradicts 4299DF43-9387-4BC1-A413-0885307BA383 (tunnel B42BE134-E317-44D1-9AB2-D6BFD8BDCB4D) [proposed (agent-derived, unreviewed) — accept/reject via moot_review_tunnel]
        conflicting_facts: 81 subject+predicate pair(s)
          [agent-sdk-gap-analysis-2026-05-02] track1_p1
            A3896BD2-5880-4E32-91BF-A7CE3CB63AA5  object=[f1-claude-md-compaction-survival]  source=  filed=2026-07-04T05:46:42Z
            EF9DEA15-A3C9-45CC-A78F-28ACA6E59CE7  object=[f9-brief-slash-command-ships-as-claude-commands-brief-md-not-skill]  source=  filed=2026-07-04T05:46:42Z
          [forge_v10] phase1_state
            8F3EB809-10CD-40C0-9989-49EE6FA85A8D  object=[ACCEPTED live by Bob 2026-07-05; merged to forge develop at 1df6a36]  source=mootx01  filed=2026-07-05T09:28:59Z
            843C301F-23A0-4F23-BC1D-A5090842CBD3  object=[ACCEPTED 2026-07-05 single tree develop]  source=599ED465-7C48-4567-8382-0D8E2396081D  filed=2026-07-09T20:53:30Z
        """

    /// `moot_memory_search` — NOT live-captured: transcribed from the code that
    /// formats it (DenseRow.render: `uuid · subject · fdc:<code> · qid:<QID> ·
    /// <iso>`) plus the two footer lines, after the PR-03 dense-row migration
    /// replaced the earlier `<uuid>  [<room>]  <content>` listing. The text
    /// feeds only section notices — review items derive from
    /// `memorySearchStructured` below.
    static let memorySearch = """
        found 7 memory(s)
        DFA470F5-4D6C-48E6-AF8C-56E535F1DD43 · W2-INTERFACE FAB5-I1: WorkPacketKit Schema + Persistence — Interface Summary · fdc:D2 · qid:Q00 · 2026-07-23T18:04:11Z
        591F3E67-878E-4373-A6FC-3406B26E38D8 · W2-INTERFACE FAB5-L1: iPadOS Enablement — defect list and second-pass note. · fdc:D2 · qid:Q00 · 2026-07-23T18:05:02Z
        A743A822-2FAD-4958-97A9-81CB1EB2201F · W2-INTERFACE FAB5-H1: MootWorker protocol, three worker APIs, fallback semantics. · fdc:D2 · qid:Q00 · 2026-07-23T18:06:40Z
        discrimination: medium — partial separation.
        recall_provenance: dense_lane:active degraded_stages:none
        """

    /// The structured twin of `memorySearch` — the `structuredContent` block
    /// the recall family carries beside the text (shape from
    /// ToolDispatch.structuredTextResult / structuredRecallRow).
    /// `ReviewLineParsing.drawers` decodes items from THESE rows.
    static let memorySearchStructured: JSONValue = .object([
        "results": .array([
            .object([
                "id": .string("DFA470F5-4D6C-48E6-AF8C-56E535F1DD43"),
                "room": .string("fab5-w2"),
                "content": .string("W2-INTERFACE FAB5-I1: WorkPacketKit Schema + Persistence — Interface Summary"),
                "subject": .string("W2-INTERFACE FAB5-I1: WorkPacketKit Schema + Persistence — Interface Summary"),
            ]),
            .object([
                "id": .string("591F3E67-878E-4373-A6FC-3406B26E38D8"),
                "room": .string("fab5-w2"),
                "content": .string("W2-INTERFACE FAB5-L1: iPadOS Enablement — defect list and second-pass note."),
                "subject": .string("W2-INTERFACE FAB5-L1: iPadOS Enablement — defect list and second-pass note."),
            ]),
            .object([
                "id": .string("A743A822-2FAD-4958-97A9-81CB1EB2201F"),
                "room": .string("fab5-w2"),
                "content": .string("W2-INTERFACE FAB5-H1: MootWorker protocol, three worker APIs, fallback semantics."),
                "subject": .string("W2-INTERFACE FAB5-H1: MootWorker protocol, three worker APIs, fallback semantics."),
            ]),
        ])
    ])

    /// `moot_read_journal` (last_n 3) — live capture; entry text shortened, the
    /// `[<iso>]  ` stamp prefix is exactly as emitted.
    static let journal = """
        journal for mcp-agent: 3 entry(s)
        [2026-07-23T23:50:25Z]  FAB5-FR stream complete 2026-07-23. First-run consumer surface delivered.
        [2026-07-23T21:31:43Z]  SESSION:2026-07-23|inbox.batch:MXC-2026-0052..0056|VERDICT:ACCEPT.all5
        [2026-07-23T00:14:16Z]  2026-07-22: Released the approved Prototype pair to mootx01-ce develop/1.0.x.
        """

    /// `moot_fact_search` — NOT live-captured. Rows are transcribed from the
    /// formatter in ToolDispatch.runFactSearch:
    ///   "\\(id)  [\\(subject)] \\(predicate) [\\(object)]  filed=\\(iso)  source=\\(s)"
    /// The two instants straddle the end-of-day window used in the tests, which is
    /// what exercises window clipping.
    static let facts = """
        facts: 2
        11111111-1111-4111-8111-111111111111  [ce-release] version_is [1.1.0-beta-04]  filed=2026-07-13T09:00:00Z  source=DFA470F5-4D6C-48E6-AF8C-56E535F1DD43
        22222222-2222-4222-8222-222222222222  [ce-release] cut_by [Bob]  filed=2026-07-01T09:00:00Z  source=<hidden>
        """

    // MARK: Empty-estate responses
    //
    // What each surface really says with nothing to report. Transcribed from the
    // producing code paths: LensTools.list's "N result(s)" header, the
    // contradiction lens's literal "none" branches, ToolDispatch's search and
    // journal headers.

    static let emptyThemeWeather = "theme_weather: 0 result(s)"
    static let emptyKeystones = "keystones: 0 result(s)"
    static let emptyCohesion = "cohesion_outliers (considered 0): 0 result(s)"
    static let emptyDrift = """
        drift: before=0 after=0
        jensenShannon: 0.0
        klDivergence: 0.0
        """
    static let emptyContradiction = """
        contradicts_tunnels: none
        conflicting_facts: none
        """
    static let emptyMemorySearch = "found 0 memory(s)"
    static let emptyFacts = "facts: 0"
    static let emptyJournal = "journal for mcp-agent: 0 entry(s)"

    // MARK: Response tables

    /// Structured blocks per surface, for the populated maps. Only the recall
    /// family carries one; every other surface answers in text alone.
    static let populatedStructured: [ReviewSurface: JSONValue] = [
        .memorySearch: memorySearchStructured
    ]

    /// Every surface answering with live-captured content.
    static let populated: [ReviewSurface: String] = [
        .themeWeather: themeWeather,
        .keystones: keystones,
        .cohesion: cohesion,
        .drift: drift,
        .contradiction: contradiction,
        .memorySearch: memorySearch,
        .factSearch: facts,
        .journal: journal,
    ]

    /// Every surface answering, with nothing to report.
    static let empty: [ReviewSurface: String] = [
        .themeWeather: emptyThemeWeather,
        .keystones: emptyKeystones,
        .cohesion: emptyCohesion,
        .drift: emptyDrift,
        .contradiction: emptyContradiction,
        .memorySearch: emptyMemorySearch,
        .factSearch: emptyFacts,
        .journal: emptyJournal,
    ]
}

// MARK: - StubReviewReader

/// Replays recorded responses and records every call. An actor because it
/// mutates its call log; `ReviewSurfaceReading` is Sendable and the builders
/// await each call.
actor StubReviewReader: ReviewSurfaceReading {
    /// Tool names, in call order — the read-only and determinism assertions read this.
    private(set) var calls: [String] = []
    /// Arguments per call, in call order.
    private(set) var callArguments: [[String: JSONValue]] = []

    private let responses: [ReviewSurface: String]
    private let structured: [ReviewSurface: JSONValue]
    private let failing: Set<ReviewSurface>
    private let refusalText: String

    /// - Parameters:
    ///   - responses: text to return per surface. A surface with no entry returns
    ///     the empty string, which builders must treat as "nothing parsed".
    ///   - structured: structuredContent blocks per surface (recall family
    ///     only). A surface with no entry answers with structured == nil, the
    ///     shape every text-only tool produces.
    ///   - failing: surfaces that answer with `isError: true`.
    ///   - refusalText: the message failing surfaces return.
    init(
        responses: [ReviewSurface: String],
        structured: [ReviewSurface: JSONValue] = [:],
        failing: Set<ReviewSurface> = [],
        refusalText: String = "estate is not open"
    ) {
        self.responses = responses
        self.structured = structured
        self.failing = failing
        self.refusalText = refusalText
    }

    func call(_ surface: ReviewSurface, arguments: [String: JSONValue]) async -> ReviewToolResponse {
        calls.append(surface.rawValue)
        callArguments.append(arguments)
        if failing.contains(surface) {
            return ReviewToolResponse(text: refusalText, isError: true)
        }
        return ReviewToolResponse(
            text: responses[surface] ?? "",
            structured: structured[surface],
            isError: false)
    }
}
