import FactExtractionKit
import Foundation
import Testing
@testable import FactExtractionKitProviders

@Test("NuExtract codec preserves source input and fails closed on partial facts")
func nuExtractCodecContract() throws {
    let source = "Jack's birthday is June 20th."
    let spec = FactExtractorModelSpec(
        providerID: "apple-coreai-nuextract",
        modelID: "numind/NuExtract-1.5-tiny",
        modelVersion: "q8", schemaVersion: "kgfact-extraction-v1",
        extractorKind: .specializedModel,
        maximumInputCharacters: 12_000, maximumFactsPerSource: 16)
    let request = FactExtractionRequest(
        sourceID: "drawer-1", sourceDigest: "digest", sourceText: source,
        eligibleSourceSpans: [FactSourceSpan(
            start: 0, end: source.unicodeScalars.count,
            startUTF8Byte: 0, endUTF8Byte: source.utf8.count)],
        maximumFacts: 4)

    #expect(NuExtractFactCodec.prompt(for: request).contains(source))
    let response = try NuExtractFactCodec.response(
        from: "prefix {\"facts\":[{\"subject\":\"Jack\",\"predicate\":\"birthday\",\"object\":\"June 20th\",\"evidenceQuote\":\"Jack's birthday is June 20th.\",\"confidence\":0.98,\"assertionKind\":\"asserted\",\"searchAliases\":[\"Jack birthday\"]}]} trailing",
        request: request, spec: spec)
    #expect(response.providerID == spec.providerID)
    #expect(response.candidates.count == 1)
    #expect(response.candidates[0].object == "June 20th")

    #expect(throws: FactExtractionError.self) {
        _ = try NuExtractFactCodec.response(
            from: "{\"facts\":[{\"subject\":\"Jack\"}]}",
            request: request, spec: spec)
    }
}

@Test("NuExtract worker uses Rust-compatible frames and exits on EOF")
func nuExtractWorkerProtocolContract() async throws {
    let source = "Jack's birthday is June 20th."
    let request = FactExtractionRequest(
        sourceID: "drawer-1", sourceDigest: "digest", sourceText: source,
        eligibleSourceSpans: [FactSourceSpan(
            start: 0, end: source.unicodeScalars.count,
            startUTF8Byte: 0, endUTF8Byte: source.utf8.count)],
        maximumFacts: 4)
    let envelope = CoreAINuExtractWorkerProtocol.Request(
        protocolVersion: CoreAINuExtractWorkerProtocol.version,
        requestID: 17,
        extraction: request)

    let encoded = try JSONEncoder().encode(envelope)
    let object = try #require(
        JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    let extraction = try #require(object["extraction"] as? [String: Any])
    let spans = try #require(extraction["eligibleSourceSpans"] as? [[String: Any]])
    #expect(object["requestId"] as? Int == 17)
    #expect(extraction["sourceId"] as? String == "drawer-1")
    #expect(spans.first?["startUtf8Byte"] as? Int == 0)

    let input = Pipe()
    let output = Pipe()
    let server = Task {
        try await CoreAINuExtractWorkerLoop.serve(
            input: input.fileHandleForReading,
            output: output.fileHandleForWriting,
            extract: { extraction in
                FactExtractionResponse(
                    sourceDigest: extraction.sourceDigest,
                    providerID: "test-worker", modelID: "nuextract",
                    modelVersion: "q8", schemaVersion: "kgfact-extraction-v1",
                    candidates: [])
            })
    }
    try CoreAINuExtractWorkerProtocol.write(
        envelope, to: input.fileHandleForWriting)
    try input.fileHandleForWriting.close()
    let response = try #require(try CoreAINuExtractWorkerProtocol.read(
        CoreAINuExtractWorkerProtocol.Response.self,
        from: output.fileHandleForReading))
    try await server.value
    try output.fileHandleForWriting.close()

    #expect(response.protocolVersion == CoreAINuExtractWorkerProtocol.version)
    #expect(response.requestID == 17)
    #expect(response.result?.providerID == "test-worker")
    #expect(response.error == nil)
}
