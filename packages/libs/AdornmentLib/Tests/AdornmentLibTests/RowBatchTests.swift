#if MOOTX01_MINERS
import Foundation
import Testing

@testable import AdornmentLib

/// Golden pins for the row-batch transport primitives (Bob design
/// 2026-08-30): records travel as numbered row data, answers return as
/// "N| claim" rows, identity unchanged (transport, not recipe).
@Suite("Row-batch transport primitives")
struct RowBatchTests {

    @Test("row payload carries the date line only when a date exists")
    func rowPayloadShape() {
        #expect(
            buildAdornmentRow(drawerContent: "tomatoes planted", eventDate: "2023-05-14T00:00:00Z")
                == "Record date: 2023-05-14T00:00:00Z\ntomatoes planted")
        #expect(buildAdornmentRow(drawerContent: "tomatoes planted") == "tomatoes planted")
    }

    @Test("batch prompt numbers records with unambiguous markers")
    func batchPromptShape() {
        let prompt = formatAdornmentBatchPrompt(rows: ["alpha", "beta\nwith newline"])
        #expect(prompt == """
        Batch of 2 record(s):
        --- record 1 ---
        alpha
        --- record 2 ---
        beta
        with newline
        """)
    }

    @Test("reply parse maps N| lines to positions, nil for omissions, tolerates noise")
    func replyParse() {
        let reply = """
        Here are the adornments:
        1| tomato saplings planted; straw mulch; 12 count
        3| budget review; Alex; Priya

        2|
        """
        let out = parseAdornmentBatchReply(reply, expectedRows: 3)
        #expect(out[0] == "tomato saplings planted; straw mulch; 12 count")
        #expect(out[1] == nil, "an empty claim after the bar is an omission")
        #expect(out[2] == "budget review; Alex; Priya")
    }

    @Test("reply parse ignores out-of-range numbers and last occurrence wins")
    func replyParseBounds() {
        let reply = """
        0| out of range low
        1| first answer
        1| restated answer
        4| out of range high
        """
        let out = parseAdornmentBatchReply(reply, expectedRows: 2)
        #expect(out[0] == "restated answer")
        #expect(out[1] == nil)
    }
}
#endif // MOOTX01_MINERS: the library compiles to nothing with the switch off, so do its tests.
