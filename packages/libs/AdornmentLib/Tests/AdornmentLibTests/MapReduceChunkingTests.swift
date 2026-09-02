// MapReduceChunkingTests.swift — piece-bound pins for mintAdornmentMapReduce.
//
// A record line longer than the chunk threshold is hard-split at
// Character boundaries so no piece the mint seam sees ever exceeds the
// threshold. The 40_000 x "a" / 16_000 literal is the cross-port pin:
// the Rust twin asserts the same 16_000, 16_000, 8_000 sequence.

import Testing
@testable import AdornmentLib

@Suite("mintAdornmentMapReduce chunking")
struct MapReduceChunkingTests {

    /// The record body the prompt template wraps, or nil for a prompt
    /// that is not shaped by `buildAdornmentPrompt`.
    private func recordBody(of prompt: String) -> String? {
        guard let head = prompt.range(of: "Memory record:\n"),
              let tail = prompt.range(of: "\n\nAdornment:", options: .backwards),
              head.upperBound <= tail.lowerBound else { return nil }
        return String(prompt[head.upperBound..<tail.lowerBound])
    }

    @Test("one 40_000-character line is minted as 16_000, 16_000, 8_000 then reduced")
    func overLongLineIsHardSplit() async throws {
        let content = String(repeating: "a", count: 40_000)
        var prompts: [String] = []
        var pieceIndex = 0
        let out = await mintAdornmentMapReduce(
            drawerContent: content, eventDate: nil, chunkThreshold: 16_000
        ) { prompt in
            prompts.append(prompt)
            pieceIndex += 1
            return pieceIndex <= 3 ? "summary \(pieceIndex)" : "final"
        }
        #expect(out == "final")
        #expect(prompts.count == 4, "three pieces then one reduce prompt")
        let bodies = try prompts.map { try #require(recordBody(of: $0)) }
        #expect(bodies.prefix(3).map(\.count) == [16_000, 16_000, 8_000])
        #expect(bodies.prefix(3).allSatisfy { $0.allSatisfy { $0 == "a" } })
        #expect(bodies[3] == "summary 1\nsummary 2\nsummary 3")
    }

    @Test("no piece exceeds the threshold when an over-long line follows a short one")
    func mixedLinesStayUnderThreshold() async throws {
        let content = "short\n" + String(repeating: "b", count: 40)
        var bodies: [String] = []
        _ = await mintAdornmentMapReduce(
            drawerContent: content, eventDate: nil, chunkThreshold: 16
        ) { prompt in
            if let body = recordBody(of: prompt) { bodies.append(body) }
            return "x"
        }
        // Pieces first, then the reduce prompt over the piece summaries.
        #expect(bodies.dropLast().map(\.count) == [5, 16, 16, 8])
        #expect(bodies.dropLast().allSatisfy { $0.count <= 16 })
        #expect(bodies.first == "short")
    }

    @Test("cross-port pin: a hard-split trailing fragment packs with the next short line")
    func trailingFragmentPacksWithNextLine() async throws {
        let content = String(repeating: "b", count: 7) + "\nzz"
        var bodies: [String] = []
        _ = await mintAdornmentMapReduce(
            drawerContent: content, eventDate: nil, chunkThreshold: 6
        ) { prompt in
            if let body = recordBody(of: prompt) { bodies.append(body) }
            return "x"
        }
        // The Rust twin asserts the identical ["bbbbbb", "b\nzz"] literal.
        #expect(Array(bodies.prefix(2)) == ["bbbbbb", "b\nzz"])
    }
}
