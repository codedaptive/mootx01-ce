@preconcurrency import Dispatch
import FactExtractionKit
import Foundation

enum NuExtractFactCodec {
    private static let template = """
    {
      "facts": [{
        "subject": "",
        "predicate": "",
        "object": "",
        "evidence": ""
      }]
    }
    """

    static func prompt(for request: FactExtractionRequest) -> String {
        """
        <|input|>
        ### Template:
        \(template)
        ### Text:
        \(request.sourceText)

        <|output|>
        """
    }

    /// A valid explicit empty batch is different from unusable model output.
    static func response(
        from rawOutput: String,
        request: FactExtractionRequest,
        spec: FactExtractorModelSpec
    ) throws -> FactExtractionResponse {
        let rawFacts: [RawFact]
        if let object = firstJSONObject(in: rawOutput),
           let data = object.data(using: .utf8),
           let batch = try? JSONDecoder().decode(RawBatch.self, from: data) {
            guard batch.facts != nil || batch.fact != nil else {
                throw FactExtractionError.malformedResponse("missing fact collection")
            }
            rawFacts = batch.facts ?? batch.fact.map { [$0] } ?? []
        } else {
            throw FactExtractionError.malformedResponse("invalid or incomplete extraction JSON")
        }
        // NuExtract represents absence with an empty template as well as [].
        let candidates = rawFacts.filter { !$0.isExplicitEmpty }.map {
            $0.candidate(sourceText: request.sourceText)
        }
        return FactExtractionResponse(
            sourceDigest: request.sourceDigest,
            providerID: spec.providerID,
            modelID: spec.modelID,
            modelVersion: spec.modelVersion,
            schemaVersion: spec.schemaVersion,
            candidates: candidates)
    }

    static func firstJSONObject(in text: String) -> String? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var cursor = start
        while cursor < text.endIndex {
            let character = text[cursor]
            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
            } else {
                switch character {
                case "\"": inString = true
                case "{": depth += 1
                case "}":
                    depth -= 1
                    if depth == 0 {
                        return String(text[start...cursor])
                    }
                default: break
                }
            }
            cursor = text.index(after: cursor)
        }
        return nil
    }

    private struct RawBatch: Decodable {
        let facts: [RawFact]?
        let fact: RawFact?
    }

    private struct RawFact: Decodable {
        let subject: String?
        let predicate: String?
        let object: String?
        let evidenceQuote: String?

        var isExplicitEmpty: Bool {
            subject == "" && predicate == "" && object == "" && evidenceQuote == ""
        }

        private enum CodingKeys: String, CodingKey {
            case subject, predicate, object
            case evidenceQuote = "evidence"
        }
        /// A missing field is passed through empty; the grounding validator
        /// rejects the candidate as `emptyField` and the other candidates in
        /// the same response survive.
        func candidate(sourceText: String) -> FactCandidate {
            let subject = self.subject ?? ""
            let object = self.object ?? ""
            let evidence = evidenceQuote.flatMap {
                !$0.isEmpty && sourceText.contains($0) ? $0 : nil
            }
                ?? sourceText.split(separator: "\n", omittingEmptySubsequences: true)
                    .map(String.init)
                    .first { line in
                        line.localizedCaseInsensitiveContains(subject)
                            && line.localizedCaseInsensitiveContains(object)
                    }
            return FactCandidate(
                subject: subject,
                predicate: predicate ?? "",
                object: object,
                evidenceQuote: evidence ?? "",
                // Quote grounding is not a calibrated certainty estimate.
                confidence: 0.8,
                assertionKind: .asserted,
                searchAliases: [])
        }
    }
}

enum CoreAINuExtractWorkerProtocol {
    static let version: UInt32 = 3
    static let maximumFrameBytes = 16 * 1_024 * 1_024

    struct Request: Codable, Equatable, Sendable {
        let protocolVersion: UInt32
        let requestID: UInt64
        let extraction: FactExtractionRequest

        private enum CodingKeys: String, CodingKey {
            case protocolVersion
            case requestID = "requestId"
            case extraction
        }
    }

    struct Response: Codable, Equatable, Sendable {
        let protocolVersion: UInt32
        let requestID: UInt64
        let result: FactExtractionResponse?
        let error: String?
        var errorCode: String? = nil

        private enum CodingKeys: String, CodingKey {
            case protocolVersion
            case requestID = "requestId"
            case result
            case error
            case errorCode
        }

        static func success(
            requestID: UInt64,
            result: FactExtractionResponse
        ) -> Response {
            Response(
                protocolVersion: CoreAINuExtractWorkerProtocol.version,
                requestID: requestID,
                result: result, error: nil)
        }

        static func failure(requestID: UInt64, error: String, errorCode: String? = nil) -> Response {
            Response(
                protocolVersion: CoreAINuExtractWorkerProtocol.version,
                requestID: requestID,
                result: nil, error: error, errorCode: errorCode)
        }
    }

    enum ProtocolError: Error, CustomStringConvertible {
        case invalidFrameLength(Int)
        case unexpectedEOF
        case decode(String)

        var description: String {
            switch self {
            case .invalidFrameLength(let length):
                "invalid frame length \(length)"
            case .unexpectedEOF:
                "unexpected EOF inside worker frame"
            case .decode(let reason):
                "decode worker frame: \(reason)"
            }
        }
    }

    static func write<T: Encodable>(_ value: T, to handle: FileHandle) throws {
        let payload = try JSONEncoder().encode(value)
        guard !payload.isEmpty, payload.count <= maximumFrameBytes else {
            throw ProtocolError.invalidFrameLength(payload.count)
        }
        let length = UInt32(payload.count)
        let header = Data([
            UInt8((length >> 24) & 0xff), UInt8((length >> 16) & 0xff),
            UInt8((length >> 8) & 0xff), UInt8(length & 0xff),
        ])
        try handle.write(contentsOf: header)
        try handle.write(contentsOf: payload)
    }

    static func read<T: Decodable>(
        _ type: T.Type,
        from handle: FileHandle,
        allowCleanEOF: Bool = false
    ) throws -> T? {
        guard let header = try readExactly(
            4, from: handle, allowCleanEOF: allowCleanEOF) else { return nil }
        let bytes = [UInt8](header)
        let length = Int(
            (UInt32(bytes[0]) << 24) | (UInt32(bytes[1]) << 16)
                | (UInt32(bytes[2]) << 8) | UInt32(bytes[3]))
        guard length > 0, length <= maximumFrameBytes else {
            throw ProtocolError.invalidFrameLength(length)
        }
        guard let payload = try readExactly(
            length, from: handle, allowCleanEOF: false) else {
            throw ProtocolError.unexpectedEOF
        }
        do {
            return try JSONDecoder().decode(type, from: payload)
        } catch {
            throw ProtocolError.decode(String(describing: error))
        }
    }

    private static func readExactly(
        _ count: Int,
        from handle: FileHandle,
        allowCleanEOF: Bool
    ) throws -> Data? {
        var data = Data()
        while data.count < count {
            let chunk = try handle.read(upToCount: count - data.count) ?? Data()
            if chunk.isEmpty {
                if allowCleanEOF, data.isEmpty { return nil }
                throw ProtocolError.unexpectedEOF
            }
            data.append(chunk)
        }
        return data
    }
}

enum CoreAINuExtractWorkerLoop {
    typealias Extract = @Sendable (
        FactExtractionRequest
    ) async throws -> FactExtractionResponse

    static func serve(
        input: FileHandle,
        output: FileHandle,
        extract: @escaping Extract
    ) async throws {
        while let request = try CoreAINuExtractWorkerProtocol.read(
            CoreAINuExtractWorkerProtocol.Request.self,
            from: input,
            allowCleanEOF: true)
        {
            let response: CoreAINuExtractWorkerProtocol.Response
            if request.protocolVersion != CoreAINuExtractWorkerProtocol.version {
                response = .failure(
                    requestID: request.requestID,
                    error: "unsupported NuExtract worker protocol \(request.protocolVersion)")
            } else {
                do {
                    response = .success(
                        requestID: request.requestID,
                        result: try await extract(request.extraction))
                } catch {
                    response = .failure(
                        requestID: request.requestID,
                        error: String(describing: error),
                        errorCode: (error as? FactExtractionError)?.code)
                }
            }
            try CoreAINuExtractWorkerProtocol.write(response, to: output)
        }
    }
}

public struct CoreAINuExtractWorkerConfiguration: Sendable, Equatable {
    public let assetURL: URL
    public let tokenizerURL: URL
    public let modelVersion: String
    public let maximumInputCharacters: Int
    public let maximumFactsPerSource: Int
    public let maximumNewTokens: Int

    public init(
        assetURL: URL,
        tokenizerURL: URL,
        modelVersion: String,
        maximumInputCharacters: Int = 12_000,
        maximumFactsPerSource: Int = 16,
        maximumNewTokens: Int = 1_024
    ) throws {
        guard assetURL.isFileURL, tokenizerURL.isFileURL,
              !modelVersion.isEmpty,
              maximumInputCharacters > 0,
              maximumFactsPerSource > 0,
              maximumNewTokens > 0 else {
            throw FactExtractionError.invalidRequest(
                "NuExtract worker configuration contains an invalid path, empty identity, or zero bound")
        }
        self.assetURL = assetURL
        self.tokenizerURL = tokenizerURL
        self.modelVersion = modelVersion
        self.maximumInputCharacters = maximumInputCharacters
        self.maximumFactsPerSource = maximumFactsPerSource
        self.maximumNewTokens = maximumNewTokens
    }

    var spec: FactExtractorModelSpec {
        FactExtractorModelSpec(
            providerID: "apple-coreai-nuextract-worker",
            modelID: "numind/NuExtract-1.5-tiny",
            modelVersion: modelVersion,
            schemaVersion: "kgfact-extraction-v1",
            extractorKind: .specializedModel,
            maximumInputCharacters: maximumInputCharacters,
            maximumFactsPerSource: maximumFactsPerSource)
    }
}

#if os(macOS)
import Darwin

private final class CoreAIExchangeCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    private let continuation: CheckedContinuation<CoreAINuExtractWorkerProtocol.Response, any Error>
    init(_ continuation: CheckedContinuation<CoreAINuExtractWorkerProtocol.Response, any Error>) {
        self.continuation = continuation
    }
    func finish(_ result: Result<CoreAINuExtractWorkerProtocol.Response, any Error>) -> Bool {
        lock.lock()
        guard !completed else { lock.unlock(); return false }
        completed = true
        lock.unlock()
        continuation.resume(with: result)
        return true
    }
}
/// Native Swift client for the isolated CoreAI NuExtract worker. The parent
/// owns only pipes and lifecycle state; the child exclusively owns model and
/// KV-cache memory.
public actor CoreAINuExtractFactExtractor: FactExtractor {
    public nonisolated let spec: FactExtractorModelSpec

    private let workerExecutableURL: URL
    private let workerArgumentsPrefix: [String]
    private let configuration: CoreAINuExtractWorkerConfiguration
    private let idleSeconds: UInt64
    private let maximumRequestsPerProcess: Int
    private let requestTimeoutSeconds: UInt64
    private var worker: CoreAINuExtractWorkerProcess?
    private var nextRequestID: UInt64 = 1
    private var useGeneration: UInt64 = 0
    private var transactionActive = false
    private var transactionWaiters: [CheckedContinuation<Void, Never>] = []

    public init(
        workerExecutableURL: URL,
        workerArgumentsPrefix: [String] = ["coreai-nuextract-worker"],
        assetURL: URL,
        tokenizerURL: URL,
        modelVersion: String,
        maximumInputCharacters: Int = 12_000,
        maximumFactsPerSource: Int = 16,
        maximumNewTokens: Int = 1_024,
        idleSeconds: UInt64 = 120,
        maximumRequestsPerProcess: Int = 256,
        requestTimeoutSeconds: UInt64 = 60
    ) throws {
        let fileManager = FileManager.default
        guard workerExecutableURL.isFileURL,
              fileManager.isExecutableFile(atPath: workerExecutableURL.path),
              !workerArgumentsPrefix.isEmpty else {
            throw FactExtractionError.unavailable(
                "NuExtract worker executable is unavailable")
        }
        var assetIsDirectory: ObjCBool = false
        guard fileManager.fileExists(
                atPath: assetURL.path, isDirectory: &assetIsDirectory),
              assetIsDirectory.boolValue,
              assetURL.pathExtension == "aimodel" else {
            throw FactExtractionError.unavailable(
                "NuExtract CoreAI asset is unavailable")
        }
        var tokenizerIsDirectory: ObjCBool = false
        guard fileManager.fileExists(
                atPath: tokenizerURL.path, isDirectory: &tokenizerIsDirectory),
              !tokenizerIsDirectory.boolValue,
              fileManager.isReadableFile(atPath: tokenizerURL.path),
              idleSeconds > 0,
              maximumRequestsPerProcess > 0, requestTimeoutSeconds > 0 else {
            throw FactExtractionError.unavailable(
                "NuExtract tokenizer or worker lifecycle configuration is unavailable")
        }
        let configuration = try CoreAINuExtractWorkerConfiguration(
            assetURL: assetURL,
            tokenizerURL: tokenizerURL,
            modelVersion: modelVersion,
            maximumInputCharacters: maximumInputCharacters,
            maximumFactsPerSource: maximumFactsPerSource,
            maximumNewTokens: maximumNewTokens)
        self.workerExecutableURL = workerExecutableURL
        self.workerArgumentsPrefix = workerArgumentsPrefix
        self.configuration = configuration
        self.idleSeconds = idleSeconds
        self.maximumRequestsPerProcess = maximumRequestsPerProcess
        self.requestTimeoutSeconds = requestTimeoutSeconds
        spec = configuration.spec
    }

    public func extract(
        _ request: FactExtractionRequest
    ) async throws -> FactExtractionResponse {
        guard request.maximumFacts > 0,
              request.maximumFacts <= spec.maximumFactsPerSource,
              request.sourceText.unicodeScalars.count <= spec.maximumInputCharacters else {
            throw FactExtractionError.invalidRequest(
                "request exceeds the configured NuExtract recipe")
        }

        await acquireTransaction()
        defer { releaseTransaction() }
        useGeneration &+= 1
        let generation = useGeneration

        if let worker, !worker.process.isRunning {
            self.worker = nil
        }
        if let worker,
           worker.requests >= maximumRequestsPerProcess {
            worker.stop(graceful: true)
            self.worker = nil
        }
        if worker == nil {
            worker = try spawnWorker()
        }
        guard let worker else {
            throw FactExtractionError.unavailable(
                "NuExtract worker could not be started")
        }

        let requestID = nextRequestID
        nextRequestID &+= 1
        let envelope = CoreAINuExtractWorkerProtocol.Request(
            protocolVersion: CoreAINuExtractWorkerProtocol.version,
            requestID: requestID,
            extraction: request)
        let response: CoreAINuExtractWorkerProtocol.Response
        do {
            response = try await Self.exchange(envelope, with: worker, timeoutSeconds: requestTimeoutSeconds)
            worker.requests += 1
        } catch {
            worker.stop(graceful: false)
            self.worker = nil
            if let typed = error as? FactExtractionError { throw typed }
            if error is CancellationError { throw error }
            throw FactExtractionError.inferenceFailed(
                "NuExtract worker exchange failed: \(error)")
        }

        scheduleIdleReap(after: generation)
        guard response.protocolVersion == CoreAINuExtractWorkerProtocol.version,
              response.requestID == requestID else {
            worker.stop(graceful: false)
            self.worker = nil
            throw FactExtractionError.malformedResponse(
                "NuExtract worker response protocol or request identity mismatch")
        }
        switch (response.result, response.error) {
        case (.some(let result), .none):
            return result
        case (.none, .some(let error)):
            throw FactExtractionError.fromWire(code: response.errorCode, message: error)
        default:
            worker.stop(graceful: false)
            self.worker = nil
            throw FactExtractionError.malformedResponse(
                "NuExtract worker returned an invalid result/error envelope")
        }
    }

    public func shutdown() async {
        await acquireTransaction()
        defer { releaseTransaction() }
        useGeneration &+= 1
        worker?.stop(graceful: true)
        worker = nil
    }

    private func spawnWorker() throws -> CoreAINuExtractWorkerProcess {
        let process = Process()
        process.executableURL = workerExecutableURL
        process.arguments = workerArgumentsPrefix + [
            "--asset", configuration.assetURL.path,
            "--tokenizer", configuration.tokenizerURL.path,
            "--model-version", configuration.modelVersion,
            "--maximum-input-characters", String(configuration.maximumInputCharacters),
            "--maximum-facts", String(configuration.maximumFactsPerSource),
            "--maximum-new-tokens", String(configuration.maximumNewTokens),
        ]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.standardError
        do {
            try process.run()
        } catch {
            throw FactExtractionError.unavailable(
                "start NuExtract worker: \(error)")
        }
        return CoreAINuExtractWorkerProcess(
            process: process,
            stdin: input.fileHandleForWriting,
            stdout: output.fileHandleForReading)
    }

    private static func exchange(
        _ request: CoreAINuExtractWorkerProtocol.Request,
        with worker: CoreAINuExtractWorkerProcess,
        timeoutSeconds: UInt64
    ) async throws -> CoreAINuExtractWorkerProtocol.Response {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler(operation: {
          try await withCheckedThrowingContinuation { continuation in
            let completion = CoreAIExchangeCompletion(continuation)
            let watchdog = DispatchWorkItem {
                if completion.finish(.failure(FactExtractionError.timedOut("worker request deadline exceeded"))) {
                    worker.stop(graceful: false)
                }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Double(timeoutSeconds), execute: watchdog)
            DispatchQueue.global(qos: .userInitiated).async {
                defer { watchdog.cancel() }
                do {
                    try CoreAINuExtractWorkerProtocol.write(
                        request, to: worker.stdin)
                    guard let response = try CoreAINuExtractWorkerProtocol.read(
                        CoreAINuExtractWorkerProtocol.Response.self,
                        from: worker.stdout) else {
                        throw CoreAINuExtractWorkerProtocol.ProtocolError.unexpectedEOF
                    }
                    _ = completion.finish(.success(response))
                } catch {
                    _ = completion.finish(.failure(error))
                }
            }
          }
        }, onCancel: { worker.stop(graceful: false) })
    }

    private func acquireTransaction() async {
        guard transactionActive else {
            transactionActive = true
            return
        }
        await withCheckedContinuation { continuation in
            transactionWaiters.append(continuation)
        }
    }

    private func releaseTransaction() {
        guard !transactionWaiters.isEmpty else {
            transactionActive = false
            return
        }
        transactionWaiters.removeFirst().resume()
    }

    private func scheduleIdleReap(after generation: UInt64) {
        Task { [idleSeconds] in
            try? await Task.sleep(nanoseconds: idleSeconds * 1_000_000_000)
            self.reapIfIdle(since: generation)
        }
    }

    private func reapIfIdle(since generation: UInt64) {
        guard useGeneration == generation,
              !transactionActive,
              let worker else { return }
        worker.stop(graceful: true)
        self.worker = nil
    }
}

private final class CoreAINuExtractWorkerProcess: @unchecked Sendable {
    let process: Process
    let stdin: FileHandle
    let stdout: FileHandle
    var requests = 0
    private let lock = NSLock()
    private var stopped = false

    init(process: Process, stdin: FileHandle, stdout: FileHandle) {
        self.process = process
        self.stdin = stdin
        self.stdout = stdout
    }

    func stop(graceful: Bool) {
        lock.lock()
        guard !stopped else {
            lock.unlock()
            return
        }
        stopped = true
        lock.unlock()

        if process.isRunning {
            if graceful {
                try? stdin.close()
                process.waitUntilExit()
            } else {
                // SIGTERM can be ignored while the model is wedged. This is
                // our own isolated worker; force-reap to unblock framed I/O.
                Darwin.kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
        }
        try? stdin.close()
        try? stdout.close()
    }

    deinit {
        stop(graceful: false)
    }
}
#endif

#if os(macOS) && canImport(CoreAI)
import CoreAI
public enum CoreAINuExtractWorkerServer {
    public static func serve(
        configuration: CoreAINuExtractWorkerConfiguration,
        input: FileHandle = .standardInput,
        output: FileHandle = .standardOutput
    ) async throws {
        let runtime = try await CoreAINuExtractRuntime(configuration: configuration)
        try await CoreAINuExtractWorkerLoop.serve(
            input: input,
            output: output,
            extract: { request in try await runtime.extract(request) })
    }
}
private actor CoreAINuExtractRuntime {
    let spec: FactExtractorModelSpec
    private let engine: CoreAINuExtractEngine

    init(configuration: CoreAINuExtractWorkerConfiguration) async throws {
        spec = configuration.spec
        engine = try await CoreAINuExtractEngine(
            assetURL: configuration.assetURL,
            tokenizerURL: configuration.tokenizerURL,
            maximumNewTokens: configuration.maximumNewTokens)
    }

    func extract(
        _ request: FactExtractionRequest
    ) async throws -> FactExtractionResponse {
        guard request.maximumFacts > 0,
              request.maximumFacts <= spec.maximumFactsPerSource,
              request.sourceText.unicodeScalars.count <= spec.maximumInputCharacters else {
            throw FactExtractionError.invalidRequest(
                "request exceeds the configured NuExtract recipe")
        }
        do {
            let raw = try await engine.generate(
                NuExtractFactCodec.prompt(for: request))
            return try NuExtractFactCodec.response(
                from: raw, request: request, spec: spec)
        } catch let error as FactExtractionError {
            throw error
        } catch {
            throw FactExtractionError.inferenceFailed(String(describing: error))
        }
    }
}
private final class CoreAINuExtractEngine: @unchecked Sendable {
    private let prefill: InferenceFunction
    private let decode: InferenceFunction
    private let tokenizer: NuExtractQwenTokenizer
    private let stopIDs: Set<Int32>
    private let layers: Int
    private let heads: Int
    private let cacheLength: Int
    private let headDimension: Int
    private let cacheScalarType: NDArray.ScalarType
    private let maximumNewTokens: Int

    init(
        assetURL: URL,
        tokenizerURL: URL,
        maximumNewTokens: Int
    ) async throws {
        let loadedTokenizer = try NuExtractQwenTokenizer(tokenizerJSON: tokenizerURL)
        tokenizer = loadedTokenizer
        stopIDs = Set(["<|endoftext|>", "<|end|>", "<|im_end|>"].compactMap {
            loadedTokenizer.specialID($0)
        })
        self.maximumNewTokens = maximumNewTokens

        var options = SpecializationOptions(preferredComputeUnitKind: .gpu)
        options.expectFrequentReshapes = true
        let model = try await AIModel(contentsOf: assetURL, options: options)
        guard let prefill = try model.loadFunction(named: "prefill_b"),
              let decode = try model.loadFunction(named: "decode_b") else {
            throw FactExtractionError.unavailable(
                "NuExtract CoreAI asset lacks prefill_b/decode_b")
        }
        guard case .ndArray(let decodeCache)? = decode.descriptor.stateDescriptor(of: "cache_k"),
              decodeCache.shape.count == 5,
              decodeCache.shape[1] == 1,
              case .ndArray(let prefillKey)? = prefill.descriptor.stateDescriptor(of: "cache_k"),
              case .ndArray(let prefillValue)? = prefill.descriptor.stateDescriptor(of: "cache_v"),
              prefillKey.shape == decodeCache.shape,
              prefillValue.shape == decodeCache.shape else {
            throw FactExtractionError.unavailable(
                "NuExtract CoreAI asset is not the stateful batch-one geometry")
        }
        guard maximumNewTokens < decodeCache.shape[3] - 1 else {
            throw FactExtractionError.invalidRequest(
                "NuExtract generation budget does not fit the model cache")
        }
        self.prefill = prefill
        self.decode = decode
        layers = decodeCache.shape[0]
        heads = decodeCache.shape[2]
        cacheLength = decodeCache.shape[3]
        headDimension = decodeCache.shape[4]
        cacheScalarType = decodeCache.scalarType
    }

    func generate(_ prompt: String) async throws -> String {
        let promptCapacity = cacheLength - maximumNewTokens - 1
        let encoded = tokenizer.encode(prompt)
        guard !encoded.isEmpty, encoded.count <= promptCapacity else {
            throw FactExtractionError.needsSubdivision("prompt exceeds token context including output reserve")
        }
        let bucket = min(((encoded.count + 127) / 128) * 128, cacheLength)
        var inputIDs = [Int32](repeating: 0, count: bucket)
        var prefillMask = [Int32](repeating: 0, count: bucket)
        for index in encoded.indices {
            inputIDs[index] = encoded[index]
            prefillMask[index] = 1
        }

        await CoreAIExecutionGate.shared.acquire()
        defer { CoreAIExecutionGate.shared.release() }

        var keyCache = NDArray(
            shape: [layers, 1, heads, cacheLength, headDimension],
            scalarType: cacheScalarType)
        var valueCache = NDArray(
            shape: [layers, 1, heads, cacheLength, headDimension],
            scalarType: cacheScalarType)
        var prefillStates = InferenceFunction.MutableViews()
        prefillStates.insert(&keyCache, for: "cache_k")
        prefillStates.insert(&valueCache, for: "cache_v")
        var prefillOutput = try await prefill.run(inputs: [
            "input_ids": NDArray(scalars: inputIDs, shape: [1, bucket]),
            "attention_mask": NDArray(scalars: prefillMask, shape: [1, bucket]),
            "position": NDArray(scalars: [Int32(encoded.count - 1)], shape: [1]),
        ], states: prefillStates)
        guard let logits = prefillOutput.remove("logits")?.ndArray else {
            throw FactExtractionError.inferenceFailed(
                "NuExtract prefill returned no logits")
        }

        var next = try argmax(logits)
        var generated: [Int32] = []
        var decodeMask = [Int32](repeating: 0, count: cacheLength)
        for index in 0..<encoded.count { decodeMask[index] = 1 }
        var decodeMaskArray = NDArray(scalars: decodeMask, shape: [1, cacheLength])
        var cachePosition = Int32(encoded.count)

        for _ in 0..<maximumNewTokens {
            if stopIDs.contains(next) { break }
            guard Int(cachePosition) < cacheLength else { break }
            generated.append(next)
            let raw = tokenizer.decode(generated)
            if let object = NuExtractFactCodec.firstJSONObject(in: raw) {
                return object
            }

            var decodeStates = InferenceFunction.MutableViews()
            decodeStates.insert(&keyCache, for: "cache_k")
            decodeStates.insert(&valueCache, for: "cache_v")
            var output = try await decode.run(inputs: [
                "input_ids": NDArray(scalars: [next], shape: [1, 1]),
                "attention_mask": decodeMaskArray,
                "cache_pos": NDArray(scalars: [cachePosition], shape: [1]),
            ], states: decodeStates)
            guard let stepLogits = output.remove("logits")?.ndArray else {
                throw FactExtractionError.inferenceFailed(
                    "NuExtract decode returned no logits")
            }
            var maskView = decodeMaskArray.mutableView(as: Int32.self)
            maskView.withUnsafeMutablePointer { pointer, _, _ in
                pointer[Int(cachePosition)] = 1
            }
            cachePosition += 1
            next = try argmax(stepLogits)
        }
        throw FactExtractionError.needsSubdivision("output ended without a complete JSON object")
    }

    private func argmax(_ logits: NDArray) throws -> Int32 {
        switch logits.scalarType {
        case .float16:
            guard let values = logits.view(as: Float16.self).contiguousElements,
                  !values.isEmpty else {
                throw FactExtractionError.inferenceFailed("NuExtract logits are not contiguous")
            }
            var best = 0
            for index in 1..<values.count where values[index] > values[best] { best = index }
            return Int32(best)
        case .float32:
            guard let values = logits.view(as: Float.self).contiguousElements,
                  !values.isEmpty else {
                throw FactExtractionError.inferenceFailed("NuExtract logits are not contiguous")
            }
            var best = 0
            for index in 1..<values.count where values[index] > values[best] { best = index }
            return Int32(best)
        default:
            throw FactExtractionError.inferenceFailed(
                "NuExtract logits use an unsupported scalar type")
        }
    }
}

private final class CoreAIExecutionGate: @unchecked Sendable {
    static let shared = CoreAIExecutionGate()
    private let lock = NSLock()
    private var occupied = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if occupied {
                waiters.append(continuation)
                lock.unlock()
            } else {
                occupied = true
                lock.unlock()
                continuation.resume()
            }
        }
    }

    func release() {
        lock.lock()
        guard !waiters.isEmpty else {
            occupied = false
            lock.unlock()
            return
        }
        let next = waiters.removeFirst()
        lock.unlock()
        next.resume()
    }
}
#endif
