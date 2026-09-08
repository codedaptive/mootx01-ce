import Testing
@testable import ContextDistillLib

@Test func completeJSONPreservesEveryLineSeparator() {
    let endings = ["\r\n", "\n", "\r", "\u{b}", "\u{c}", "\u{1c}", "\u{1d}", "\u{1e}", "\u{85}", "\u{2028}", "\u{2029}"]
    let count: (String) -> Int = { $0.utf8.count }
    let rows = (0..<60).map { "{\"kind\":\"func\",\"name\":\"function\($0)\",\"signature\":\"public func function\($0)()\"}" }
    let array = "[" + rows.joined(separator: ",") + "]"
    for separator in endings {
        let after = separator + "Following prose stays separate."
        let tables = CompleteJSON.tables(array + after, count: count)
        #expect(tables.hasPrefix(CompleteJSON.legend))
        #expect(tables.utf8.suffix(after.utf8.count).elementsEqual(after.utf8))

        let blocks = CompleteJSON.blocks("{  \"a\" : 1  }" + after, count: count)
        #expect(blocks.utf8.elementsEqual(("{\"a\":1}" + after).utf8))

        let declarations = CompleteJSON.declarations(tables, count: count)
        #expect(declarations.contains(CompleteJSON.declarationLegend))
        #expect(declarations.utf8.suffix(after.utf8.count).elementsEqual(after.utf8))
    }
}

@Test func completeJSONNativeDepthLimitPreservesUnsupportedInput() {
    let count: (String) -> Int = { $0.utf8.count }
    let accepted = String(repeating: "[ ", count: 127) + "0" + String(repeating: " ]", count: 127)
    #expect(CompleteJSON.blocks(accepted, count: count) != accepted)
    let rejected = String(repeating: "[ ", count: 128) + "0" + String(repeating: " ]", count: 128)
    #expect(CompleteJSON.blocks(rejected, count: count) == rejected)
}
