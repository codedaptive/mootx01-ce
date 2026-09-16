import FactExtractionKit
import Foundation
import Testing
@testable import FactExtractionKitProviders

@Test("NuExtract codec preserves source input and passes partial facts through empty for the validator")
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
    let response = NuExtractFactCodec.response(
        from: "prefix {\"facts\":[{\"subject\":\"Jack\",\"predicate\":\"birthday\",\"object\":\"June 20th\",\"evidence\":\"jack's birthday is june 20th.\"}]} trailing",
        request: request, spec: spec)
    #expect(response.providerID == spec.providerID)
    #expect(response.candidates.count == 1)
    #expect(response.candidates[0].object == "June 20th")
    #expect(response.candidates[0].evidenceQuote == source)
    #expect(response.candidates[0].confidence == 1.0)
    #expect(response.candidates[0].assertionKind == .asserted)

    // A partial fact is not an error: it passes through with empty fields so
    // the grounding validator rejects it (emptyField) and counts it, and the
    // other candidates in the same response survive.
    let partial = NuExtractFactCodec.response(
        from: "{\"facts\":[{\"subject\":\"Jack\"}]}",
        request: request, spec: spec)
    #expect(partial.candidates.count == 1)
    #expect(partial.candidates[0].predicate.isEmpty)
    #expect(FactGroundingValidator.validate(
        response: partial, request: request, originalSource: source,
        expectedSpec: spec).accepted.isEmpty)

    // Output with no complete JSON object is the chunk's answer: zero
    // candidates, never an error to retry.
    #expect(NuExtractFactCodec.response(
        from: "{\"facts\":[{\"subject\":\"Ja", request: request, spec: spec)
        .candidates.isEmpty)
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
