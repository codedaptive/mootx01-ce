import Testing
import AriaLexiconLib
@testable import AriaMCP

/// Coverage that the lexicon-to-MCP projection holds the contract
/// described in ARIA_MCP_SPEC_v0.2 § 2 and § 4.
///
/// `cross_estate_recall` is the one tool that sits ABOVE the lexicon
/// projection (provenance `.federation`, no `(verb, noun)` pair). The
/// lexicon-conformance tests below iterate only the `.lexicon` tools —
/// the federation tool is the single deliberate exception and has its
/// own dedicated test (MCP-MULTI-01, Kong review).
@Suite("Tool projection")
struct ToolProjectionTests {

    /// Every lexicon-projected tool must correspond to a (verb, noun)
    /// pair the lexicon's acceptance matrix accepts. A drift here is a
    /// wire surface that promises something the substrate refuses.
    @Test func testEveryProjectedToolIsAcceptedByLexicon() {
        for tool in ToolProjection.tools() {
            guard case .lexicon(let verb, let noun) = tool.provenance else { continue }
            #expect(
                Acceptance.accepts(noun, verb),
                "tool \(tool.name) projects (verb: \(verb), noun: \(noun)) but the matrix rejects that pair"
            )
        }
    }

    /// propose and associate are substrate-driven; they must never
    /// appear on the tool surface.
    @Test func testSubstrateDrivenVerbsAreNotTools() {
        for tool in ToolProjection.tools() {
            guard case .lexicon(let verb, _) = tool.provenance else { continue }
            #expect(verb != .propose, "propose surfaced as tool \(tool.name)")
            #expect(verb != .associate, "associate surfaced as tool \(tool.name)")
        }
    }

    /// Action tools take the verb_noun form; the one query verb takes
    /// noun_verb. Spec § 2 fixes this naming discipline.
    @Test func testNamingDiscipline() {
        for tool in ToolProjection.tools() {
            guard case .lexicon(let verb, let noun) = tool.provenance else { continue }
            // Shipped names carry the product namespace prefix (moot_)
            // ahead of the ARIA grammar body (commit e6dd7ba).
            let prefix = ToolProjection.toolNamePrefix
            if verb == .recall {
                #expect(tool.name == "\(prefix)\(noun.rawValue)_recall")
            } else {
                #expect(tool.name == "\(prefix)\(verb.rawValue)_\(noun.rawValue)")
            }
        }
    }

    /// Round-trip: each lexicon tool name parses back to its verb / noun
    /// pair. Confirms `ToolDispatcher.parseToolName` is the strict
    /// inverse of `ToolProjection.toolName`.
    @Test func testParseRoundTrip() {
        for tool in ToolProjection.tools() {
            guard case .lexicon(let verb, let noun) = tool.provenance else { continue }
            guard let parsed = ToolDispatcher.parseToolName(tool.name) else {
                Issue.record("parse failed for tool \(tool.name)")
                continue
            }
            #expect(parsed.0 == verb)
            #expect(parsed.1 == noun)
        }
    }

    /// The capture_drawer and drawer_recall tools must be present —
    /// they are the live verbs in the GLK substrate today and the
    /// smoke test for the wire works through them.
    @Test func testCoreToolsArePresent() {
        let names = Set(ToolProjection.tools().map(\.name))
        #expect(names.contains("moot_capture_drawer"))
        #expect(names.contains("moot_drawer_recall"))
        #expect(names.contains("moot_withdraw_drawer"))
    }

    /// `cross_estate_recall` is the one federation tool above the lexicon
    /// projection: present in `tools()`, provenance `.federation`, no
    /// `(verb, noun)` pair, and NOT parseable as a lexicon tool name.
    @Test func testFederationToolIsPresentAboveTheProjection() throws {
        let federation = ToolProjection.tools().filter { $0.provenance == .federation }
        #expect(federation.count == 1, "exactly one federation tool is expected")
        let tool = try #require(federation.first)
        #expect(tool.name == ToolDispatcher.crossEstateRecallToolName)
        #expect(tool.verb == nil)
        #expect(tool.noun == nil)
        #expect(
            ToolDispatcher.parseToolName(tool.name) == nil,
            "the federation tool name must not parse as a lexicon (verb, noun) pair"
        )
        // Its schema requires the caller identity and carries no estateID
        // (it fans across estates rather than targeting one).
        let schema = tool.inputSchema.objectValue
        let required = schema?["required"]?.arrayValue?.compactMap { $0.stringValue } ?? []
        #expect(required.contains("requesterEstateID"))
        #expect(schema?["properties"]?.objectValue?["estateID"] == nil)
    }

    /// `estateID` is an optional addressing field on every per-estate
    /// (lexicon) tool: present in `properties`, never in `required`.
    @Test func testEstateIDIsOptionalOnPerEstateTools() {
        for tool in ToolProjection.tools() {
            guard case .lexicon = tool.provenance else { continue }
            let schema = tool.inputSchema.objectValue
            #expect(
                schema?["properties"]?.objectValue?["estateID"] != nil,
                "\(tool.name) must expose an optional estateID property"
            )
            let required = schema?["required"]?.arrayValue?.compactMap { $0.stringValue } ?? []
            #expect(
                !required.contains("estateID"),
                "\(tool.name) must never require estateID"
            )
        }
    }
}
