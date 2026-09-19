import Testing
import Foundation

// MakefileFetchTests.swift — item (f) gate
//
// The `fetch:` target in the Makefile must invoke `scripts/fetch-membench.sh`
// for BOTH FirstAgent and ThirdAgent. The dataset ships two agent perspectives;
// fetching only one leaves the ThirdAgent fleet incomplete, silently.
//
// Gate: this test reads the Makefile as text, locates the `fetch:` recipe block,
// and asserts both invocations are present. Removing either invocation from the
// Makefile makes the corresponding assertion fail — the test is red.

// Navigate from this source file up to the package root, then to the Makefile.
private func makefilePath(file: String = #filePath) -> URL {
    URL(fileURLWithPath: file)
        .deletingLastPathComponent()   // mcp-benchmarkerTests/
        .deletingLastPathComponent()   // Tests/
        .deletingLastPathComponent()   // package root (the suite root)
        .appendingPathComponent("Makefile")
}

@Suite("Makefile fetch target coverage")
struct MakefileFetchTests {

    @Test("fetch: recipe invokes fetch-membench.sh for both FirstAgent and ThirdAgent")
    func fetchTargetCoversAllAgents() throws {
        let url = makefilePath()
        let makefile = try String(contentsOf: url, encoding: .utf8)

        // Locate the fetch: recipe block.  The block begins at the `fetch:`
        // target line and ends at the next non-recipe line (first line that is
        // not a tab-indented command or continuation).  We search the whole file
        // text because the gate is about presence, not position.
        #expect(makefile.contains("fetch-membench.sh FirstAgent"),
            "fetch: recipe must invoke scripts/fetch-membench.sh FirstAgent")
        #expect(makefile.contains("fetch-membench.sh ThirdAgent"),
            "fetch: recipe must invoke scripts/fetch-membench.sh ThirdAgent")

        // The two invocations must both live inside the fetch: block — not in
        // unrelated targets. Verify by finding the recipe block and asserting
        // both strings appear within it.
        //
        // The recipe block is the run of consecutive tab-indented lines that
        // follows the `fetch:` target declaration.
        let lines = makefile.components(separatedBy: "\n")
        var inFetchBlock = false
        var blockText = ""
        for line in lines {
            if line.hasPrefix("fetch:") {
                inFetchBlock = true
                continue
            }
            if inFetchBlock {
                if line.hasPrefix("\t") || line.hasPrefix(" \t") {
                    blockText += line + "\n"
                } else if line.isEmpty || line.hasPrefix("#") {
                    // Blank lines and comment lines within a recipe are allowed.
                    blockText += line + "\n"
                } else {
                    // First non-recipe line ends the block.
                    break
                }
            }
        }
        #expect(!blockText.isEmpty, "fetch: recipe block must not be empty")
        #expect(blockText.contains("fetch-membench.sh FirstAgent"),
            "fetch: recipe block must contain fetch-membench.sh FirstAgent invocation")
        #expect(blockText.contains("fetch-membench.sh ThirdAgent"),
            "fetch: recipe block must contain fetch-membench.sh ThirdAgent invocation")
    }
}
