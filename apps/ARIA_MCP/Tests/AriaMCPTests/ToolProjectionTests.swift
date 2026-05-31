import XCTest
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
final class ToolProjectionTests: XCTestCase {

    /// Every lexicon-projected tool must correspond to a (verb, noun)
    /// pair the lexicon's acceptance matrix accepts. A drift here is a
    /// wire surface that promises something the substrate refuses.
    func testEveryProjectedToolIsAcceptedByLexicon() {
        for tool in ToolProjection.tools() {
            guard case .lexicon(let verb, let noun) = tool.provenance else { continue }
            XCTAssertTrue(
                Acceptance.accepts(noun, verb),
                "tool \(tool.name) projects (verb: \(verb), noun: \(noun)) but the matrix rejects that pair"
            )
        }
    }

    /// propose and associate are substrate-driven; they must never
    /// appear on the tool surface.
    func testSubstrateDrivenVerbsAreNotTools() {
        for tool in ToolProjection.tools() {
            guard case .lexicon(let verb, _) = tool.provenance else { continue }
            XCTAssertNotEqual(verb, .propose, "propose surfaced as tool \(tool.name)")
            XCTAssertNotEqual(verb, .associate, "associate surfaced as tool \(tool.name)")
        }
    }

    /// Action tools take the verb_noun form; the one query verb takes
    /// noun_verb. Spec § 2 fixes this naming discipline.
    func testNamingDiscipline() {
        for tool in ToolProjection.tools() {
            guard case .lexicon(let verb, let noun) = tool.provenance else { continue }
            // Shipped names carry the product namespace prefix (moot_)
            // ahead of the ARIA grammar body (commit e6dd7ba).
            let prefix = ToolProjection.toolNamePrefix
            if verb == .recall {
                XCTAssertEqual(tool.name, "\(prefix)\(noun.rawValue)_recall")
            } else {
                XCTAssertEqual(tool.name, "\(prefix)\(verb.rawValue)_\(noun.rawValue)")
            }
        }
    }

    /// Round-trip: each lexicon tool name parses back to its verb / noun
    /// pair. Confirms `ToolDispatcher.parseToolName` is the strict
    /// inverse of `ToolProjection.toolName`.
    func testParseRoundTrip() {
        for tool in ToolProjection.tools() {
            guard case .lexicon(let verb, let noun) = tool.provenance else { continue }
            guard let parsed = ToolDispatcher.parseToolName(tool.name) else {
                XCTFail("parse failed for tool \(tool.name)")
                continue
            }
            XCTAssertEqual(parsed.0, verb)
            XCTAssertEqual(parsed.1, noun)
        }
    }

    /// The capture_drawer and drawer_recall tools must be present —
    /// they are the live verbs in the GLK substrate today and the
    /// smoke test for the wire works through them.
    func testCoreToolsArePresent() {
        let names = Set(ToolProjection.tools().map(\.name))
        XCTAssertTrue(names.contains("moot_capture_drawer"))
        XCTAssertTrue(names.contains("moot_drawer_recall"))
        XCTAssertTrue(names.contains("moot_withdraw_drawer"))
    }

    /// `cross_estate_recall` is the one federation tool above the lexicon
    /// projection: present in `tools()`, provenance `.federation`, no
    /// `(verb, noun)` pair, and NOT parseable as a lexicon tool name.
    func testFederationToolIsPresentAboveTheProjection() throws {
        let federation = ToolProjection.tools().filter { $0.provenance == .federation }
        XCTAssertEqual(federation.count, 1, "exactly one federation tool is expected")
        let tool = try XCTUnwrap(federation.first)
        XCTAssertEqual(tool.name, ToolDispatcher.crossEstateRecallToolName)
        XCTAssertNil(tool.verb)
        XCTAssertNil(tool.noun)
        XCTAssertNil(
            ToolDispatcher.parseToolName(tool.name),
            "the federation tool name must not parse as a lexicon (verb, noun) pair"
        )
        // Its schema requires the caller identity and carries no estateID
        // (it fans across estates rather than targeting one).
        let schema = tool.inputSchema.objectValue
        let required = schema?["required"]?.arrayValue?.compactMap { $0.stringValue } ?? []
        XCTAssertTrue(required.contains("requesterEstateID"))
        XCTAssertNil(schema?["properties"]?.objectValue?["estateID"])
    }

    /// `estateID` is an optional addressing field on every per-estate
    /// (lexicon) tool: present in `properties`, never in `required`.
    func testEstateIDIsOptionalOnPerEstateTools() {
        for tool in ToolProjection.tools() {
            guard case .lexicon = tool.provenance else { continue }
            let schema = tool.inputSchema.objectValue
            XCTAssertNotNil(
                schema?["properties"]?.objectValue?["estateID"],
                "\(tool.name) must expose an optional estateID property"
            )
            let required = schema?["required"]?.arrayValue?.compactMap { $0.stringValue } ?? []
            XCTAssertFalse(
                required.contains("estateID"),
                "\(tool.name) must never require estateID"
            )
        }
    }
}
