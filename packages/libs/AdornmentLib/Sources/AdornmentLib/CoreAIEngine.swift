// CoreAIEngine.swift — in-process Swift minter arm over the Core AI
// runtime (operator mandate 2026-08-31: the Swift binary mints every
// model under test; Rust binaries never run under the Swift product).
//
// Loads a converted `.aimodel` (see benchmark-ee/minters/coreai-convert)
// plus its HF tokenizer.json, and greedy-decodes claims in-process.
// The asset carries TWO entrypoints (convert-qwen-v4.py): `prefill`
// runs the bucket-padded, attention-masked prompt once and returns the
// KV cache as tensors; `decode` runs ONE token against a fixed
// MAX-length cache, scatter-writing the new slot in-graph. Each
// generated token costs one single-token execution (a stateless export
// re-ran the whole prefix: 3.5s/claim on 1.2k-token records), and
// because the decode shape never varies and prefill shapes come from a
// small bucket set, the runtime's compiled-shape cache stays flat — an
// exact-length dynamic-shape cache leaked per-shape state at
// ~1.5GB/min under a three-engine serve and OOM-died in minutes.
//
// Compute unit: GPU-pinned. The ANE compiler rejects this graph
// (measured 2026-08-31: 24 failed per-shape ANECCompile attempts cost
// ~8.5s/token before fallback); pinning the GPU skips the attempts.
//
// macOS 27+ only (`canImport(CoreAI)` + availability): older systems
// never construct this engine and arms fall back per GoldMiner rules.

#if canImport(CoreAI)
import CoreAI
import Foundation
import OSLog

private let log = Logger(subsystem: "com.mootx01.kit", category: "AdornmentLib")

/// How a Core AI arm's mint prompt is framed — chat-tuned models take
/// the qwen chat frame; NuExtract takes its own extraction template
/// (byte-identical to the candle recipe's chat_template so the prompt
/// digest stays comparable) and emits JSON the normalizer flattens;
/// plain feeds the prompt verbatim. File-scope: the style is parseable
/// on every OS even though the engine itself needs macOS 27.
public enum CoreAIPromptStyle: String, Sendable {
    case chat
    /// Qwen3-family frame: the chat frame plus the empty think-block
    /// prefix after the assistant sentinel. Qwen3 models THINK by
    /// default — without the prefix, generation opens a <think> block
    /// instead of the claim (observed at rust bring-up, QWEN3-ENGINE).
    /// Byte-twin of the rust QWEN3_06B_RECIPE chat_template.
    case chat3
    case plain
    /// Caller supplies the complete model-native prompt, while generated
    /// output retains the JSON contract (normalization and structural stop).
    /// This is the chained NuExtract path: `.plain` alone would incorrectly
    /// downgrade the same emission to a text contract.
    case plainJSON = "plain-json"
    case nuextract
}

/// Per-row result of a batched `mintPrompts` call: the normalized claim
/// (nil = per-row failure), the number of tokens generated, and whether
/// the generation budget or cache limit cut it off before a stop token.
/// `hitCap` is the spec-v2 finish-or-retry trigger — the harness retries
/// capped rows at a doubled budget rather than accepting a truncated
/// claim silently.
public struct MintOutcome: Sendable {
    public let text: String?
    public let generatedTokens: Int
    public let hitCap: Bool
    /// Raw decoded generation BEFORE normalization (Wave-1 protocol-lab
    /// evidence — the normalizer's first-line extraction hides what a
    /// runaway actually produced). nil only on a failed batch.
    public let rawText: String?
    /// Per-graph-call stage timing. Every real row in the same graph batch
    /// carries the same values; these fields are evidence for Core AI geometry
    /// and cache-path changes, not per-row billing measurements.
    public let prefillSeconds: Double?
    public let cacheAssemblySeconds: Double?
    public let decodeSeconds: Double?

    public init(text: String?, generatedTokens: Int, hitCap: Bool,
                rawText: String? = nil, prefillSeconds: Double? = nil,
                cacheAssemblySeconds: Double? = nil,
                decodeSeconds: Double? = nil) {
        self.text = text
        self.generatedTokens = generatedTokens
        self.hitCap = hitCap
        self.rawText = rawText
        self.prefillSeconds = prefillSeconds
        self.cacheAssemblySeconds = cacheAssemblySeconds
        self.decodeSeconds = decodeSeconds
    }
}

/// Process-wide serial gate over Core AI graph executions. Three
/// engines submitting concurrently wedged the shared runtime after
/// ~60 claims each (all lanes suspended on awaits that never resumed;
/// a single engine ran 100/100 clean), and the GPU serializes the
/// executions anyway — concurrent submission bought no throughput,
/// only the wedge. FIFO continuation queue; actor reentrancy cannot
/// hold across the inner await, hence the explicit token dance.
private final class SerialGPUGate: @unchecked Sendable {
    static let shared = SerialGPUGate()
    private let lock = NSLock()
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            lock.lock()
            if busy {
                waiters.append(cont)
                lock.unlock()
            } else {
                busy = true
                lock.unlock()
                cont.resume()
            }
        }
    }

    func release() {
        lock.lock()
        if waiters.isEmpty {
            busy = false
            lock.unlock()
        } else {
            let next = waiters.removeFirst()
            lock.unlock()
            next.resume()
        }
    }
}

@available(macOS 27.0, *)
public final class CoreAIEngine: GoldMinerEngine, @unchecked Sendable {
    public let identity: String
    /// Serial: one graph execution at a time per engine; concurrency
    /// across arms comes from the pass's per-minter lanes.
    public let maxConcurrentMints: Int = 1
    public var supportsRowBatching: Bool { true }

    private let prefillFunction: InferenceFunction
    private let decodeFunction: InferenceFunction
    /// Preferred v11 contract: prefill writes directly into the same runtime
    /// cache state that decode mutates. This avoids both the legacy host copy
    /// and the numerically unsafe full-cache output/hand-off experiment.
    private let prefillWritesCacheState: Bool
    /// New assets return a fixed MAX-length cache from prefill, allowing the
    /// runtime value to become decode state without host assembly.
    private let prefillReturnsFullCache: Bool
    /// Rows per batched graph call, read from the decode state shape
    /// (static; the export bakes it in). Single mints ride the same
    /// batch with dummy rows.
    private let batchWidth: Int
    /// Static cache geometry read from the decode entrypoint's cache_k
    /// STATE descriptor: [layers, B, kv_heads, MAX, head_dim]. The
    /// cache is runtime state (mutated in place by the graph), never a
    /// per-step output — returning it each step made the step cost
    /// proportional to B x MAX (measured v5) instead of to the compute.
    private let cacheLayers: Int
    private let cacheHeads: Int
    private let maxCache: Int
    private let headDim: Int
    private let cacheScalarType: NDArray.ScalarType
    private let tokenizer: QwenTokenizer
    private let stopIDs: Set<Int32>
    /// Per-mint generation budget in tokens. Adornments are one dense
    /// line; the 96-token default is ~3x the observed claim length, so
    /// it never truncates a well-formed claim and bounds a runaway
    /// generation. Callers running the spec-v2 finish-or-retry regime
    /// (the harness probe's --max-new-tokens flag) pass a per-process
    /// override; per-row cap-hits surface via `MintOutcome.hitCap`.
    private let maxNewTokens: Int
    private let style: CoreAIPromptStyle
    private let outputKind: MintOutputKind
    private let stopAtCompleteJSON: Bool

    public init(assetPath: String, tokenizerPath: String, identity: String,
                style: CoreAIPromptStyle = .chat,
                maxNewTokens: Int = 96,
                stopAtCompleteJSON: Bool? = nil) async throws {
        self.identity = identity
        self.style = style
        self.maxNewTokens = maxNewTokens
        self.outputKind = (style == .nuextract || style == .plainJSON)
            ? .json : .text
        // Product-native NuExtract defaults to the safe structural boundary.
        // Preassembled/historical harness paths must opt in explicitly so old
        // protocol versions remain replayable.
        self.stopAtCompleteJSON = stopAtCompleteJSON ?? (style == .nuextract)
        self.tokenizer = try QwenTokenizer(
            tokenizerJSON: URL(fileURLWithPath: tokenizerPath))
        var stops: Set<Int32> = []
        for name in ["<|im_end|>", "<|endoftext|>"] {
            if let id = tokenizer.specialID(name) { stops.insert(id) }
        }
        self.stopIDs = stops
        // expectFrequentReshapes: every decode step presents a new
        // sequence length; without this the graph re-specializes per
        // shape (~10s/token measured). GPU-pinned: the ANE compiler
        // rejects this graph outright.
        var options = SpecializationOptions(preferredComputeUnitKind: .gpu)
        options.expectFrequentReshapes = true
        let model = try await AIModel(
            contentsOf: URL(fileURLWithPath: assetPath),
            options: options)
        guard let prefill = try model.loadFunction(named: "prefill_b"),
              let decode = try model.loadFunction(named: "decode_b") else {
            throw QwenTokenizer.TokenizerError.malformed(
                "asset \(assetPath) lacks prefill_b/decode_b entrypoints — "
                + "reconvert with convert-qwen-v6.py")
        }
        // The static cache geometry is baked into the asset; read it
        // from the decode entrypoint's cache STATE rather than
        // duplicating it here.
        guard case .ndArray(let cacheDesc)? = decode.descriptor.stateDescriptor(of: "cache_k"),
              cacheDesc.shape.count == 5 else {
            throw QwenTokenizer.TokenizerError.malformed(
                "asset \(assetPath): decode_b lacks a rank-5 cache_k state — "
                + "reconvert with convert-qwen-v6.py")
        }
        self.cacheLayers = cacheDesc.shape[0]
        self.batchWidth = cacheDesc.shape[1]
        self.cacheHeads = cacheDesc.shape[2]
        self.maxCache = cacheDesc.shape[3]
        self.headDim = cacheDesc.shape[4]
        self.cacheScalarType = cacheDesc.scalarType
        if case .ndArray(let prefillKeyState)? = prefill.descriptor.stateDescriptor(
                of: "cache_k"),
           case .ndArray(let prefillValueState)? = prefill.descriptor.stateDescriptor(
                of: "cache_v"),
           prefillKeyState.shape == cacheDesc.shape,
           prefillValueState.shape == cacheDesc.shape,
           prefillKeyState.scalarType == cacheDesc.scalarType,
           prefillValueState.scalarType == cacheDesc.scalarType {
            self.prefillWritesCacheState = true
        } else {
            self.prefillWritesCacheState = false
        }
        if case .ndArray(let keyOutput)? = prefill.descriptor.outputDescriptor(
                of: "new_k"),
           case .ndArray(let valueOutput)? = prefill.descriptor.outputDescriptor(
                of: "new_v"),
           keyOutput.shape == cacheDesc.shape,
           valueOutput.shape == cacheDesc.shape {
            self.prefillReturnsFullCache = true
        } else {
            self.prefillReturnsFullCache = false
        }
        self.prefillFunction = prefill
        self.decodeFunction = decode
    }

    public func mint(prompt: String) async -> String? {
        do {
            // Single mints ride the batch graph with dummy passenger
            // rows — the batch shape is static.
            let outs = try await generate([frameFor(prompt)])
            return finish(outs[0].tokens)
        } catch {
            // Per-prompt failure contract: nil, never throw.
            log.error("CoreAIEngine \(self.identity): mint failed — \(error)")
            return nil
        }
    }

    /// Batched mint over caller-built INNER prompts (the engine applies
    /// only the style frame). This is the harness seam for the spec-v2
    /// regime, where flavor/loop/retry/shorten wording is composed
    /// outside the engine: prompts chunk into consecutive `batchWidth`
    /// graph batches, and every row reports its generated-token count
    /// and whether the budget capped it before a stop token (the
    /// finish-or-retry trigger). Product mint paths keep using
    /// `mint`/`mintRows`; behavior there is unchanged.
    public func mintPrompts(_ prompts: [String]) async -> [MintOutcome] {
        let frames = prompts.map(frameFor)
        var results: [MintOutcome] = []
        var start = 0
        while start < frames.count {
            let group = Array(frames[start..<min(start + batchWidth, frames.count)])
            do {
                let outs = try await generate(group)
                results.append(contentsOf: outs.map {
                    MintOutcome(text: finish($0.tokens),
                                generatedTokens: $0.tokens.count,
                                hitCap: $0.hitCap,
                                rawText: decodedOutput($0.tokens),
                                prefillSeconds: $0.prefillSeconds,
                                cacheAssemblySeconds: $0.cacheAssemblySeconds,
                                decodeSeconds: $0.decodeSeconds)
                })
            } catch {
                log.error("CoreAIEngine \(self.identity): batch failed — \(error)")
                results.append(contentsOf: group.map { _ in
                    MintOutcome(text: nil, generatedTokens: 0, hitCap: false)
                })
            }
            start += group.count
        }
        return results
    }

    /// Row batching: each row payload mints as its OWN independent
    /// claim (transport, never identity — the batch dimension exists to
    /// amortize graph-launch overhead, which dominates single-token
    /// decode on models this small). Rows over the width chunk into
    /// consecutive graph batches; a failed batch fails its rows to the
    /// single-record fallback path per the mintRows contract.
    public func mintRows(_ rows: [String], maxLength: Int) async -> [String?] {
        let frames = rows.map { row in
            frameFor(buildAdornmentPrompt(drawerContent: row, maxLength: maxLength))
        }
        var claims: [String?] = []
        var start = 0
        while start < frames.count {
            let group = Array(frames[start..<min(start + batchWidth, frames.count)])
            do {
                let outs = try await generate(group)
                claims.append(contentsOf: outs.map { finish($0.tokens) })
            } catch {
                log.error("CoreAIEngine \(self.identity): batch failed — \(error)")
                claims.append(contentsOf: Array(repeating: nil, count: group.count))
            }
            start += group.count
        }
        return claims
    }

    private func frameFor(_ prompt: String) -> String {
        switch style {
        case .chat:
            return "<|im_start|>user\n\(prompt)<|im_end|>\n<|im_start|>assistant\n"
        case .chat3:
            // Qwen3 non-thinking form (see CoreAIPromptStyle.chat3).
            return "<|im_start|>user\n\(prompt)<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n"
        case .plain, .plainJSON:
            return prompt
        case .nuextract:
            // The candle recipe's chat_template verbatim (nuextract-tiny
            // p1): extraction template + the record text, JSON out.
            return "<|input|>\n### Template:\n{\"claim\": \"\", \"entities\": [], "
                + "\"dates\": [], \"quantities\": []}\n### Text:\n\(prompt)\n<|output|>\n"
        }
    }

    /// Greedy-decode up to `batchWidth` framed prompts through the
    /// batched entrypoints. Rows beyond `prompts.count` are dummy slots
    /// (single pad token) whose outputs are discarded. Returns one
    /// token array per real prompt, plus whether that row's generation
    /// was cut off by the budget or the cache limit rather than a stop
    /// token (spec-v2 cap-hit telemetry).
    private func generate(_ prompts: [String]) async throws
        -> [(tokens: [Int32], hitCap: Bool, prefillSeconds: Double,
             cacheAssemblySeconds: Double, decodeSeconds: Double)] {
        let width = batchWidth
        // Tokenize with the hard cap: prompt + generation budget must
        // fit the static cache. Over-long records truncate here as a
        // last resort — upstream chunking bounds normal records first.
        let promptCap = maxCache - maxNewTokens - 1
        var rowIDs: [[Int32]] = prompts.map { p in
            let ids = tokenizer.encode(p)
            return ids.count > promptCap ? Array(ids.prefix(promptCap)) : ids
        }
        while rowIDs.count < width { rowIDs.append([stopIDs.first ?? 0]) }

        // Batched prefill: one shared 128-token bucket (the mask makes the
        // tail pads inert), per-row read positions. Forcing MAX-length input
        // is not equivalent on the macOS 27 beta runtime, so bounded process
        // recycling handles its long-lived specialization pressure instead.
        let longest = rowIDs.map(\.count).max() ?? 1
        let bucket = min(((longest + 127) / 128) * 128, maxCache)
        var ids = [Int32](repeating: 0, count: width * bucket)
        var pmask = [Int32](repeating: 0, count: width * bucket)
        var positions = [Int32](repeating: 0, count: width)
        for (r, row) in rowIDs.enumerated() {
            for (i, t) in row.enumerated() {
                ids[r * bucket + i] = t
                pmask[r * bucket + i] = 1
            }
            positions[r] = Int32(row.count - 1)
        }
        await SerialGPUGate.shared.acquire()
        defer { SerialGPUGate.shared.release() }
        let inputs = [
            "input_ids": NDArray(scalars: ids, shape: [width, bucket]),
            "attention_mask": NDArray(scalars: pmask, shape: [width, bucket]),
            "position": NDArray(scalars: positions, shape: [width]),
        ]
        let prefillStarted = ProcessInfo.processInfo.systemUptime
        let prefillResult: (
            logits: NDArray,
            keys: NDArray,
            values: NDArray,
            prefillSeconds: Double,
            cacheAssemblySeconds: Double
        )
        if prefillWritesCacheState {
            // Core AI owns these full-cache NDArrays. The prefill graph writes
            // the live prefix and decode continues mutating the same storage;
            // masked suffix bytes are never attended.
            var stateKeys = NDArray(
                shape: [cacheLayers, width, cacheHeads, maxCache, headDim],
                scalarType: cacheScalarType)
            var stateValues = NDArray(
                shape: [cacheLayers, width, cacheHeads, maxCache, headDim],
                scalarType: cacheScalarType)
            var states = InferenceFunction.MutableViews()
            states.insert(&stateKeys, for: "cache_k")
            states.insert(&stateValues, for: "cache_v")
            var outputs = try await prefillFunction.run(
                inputs: inputs, states: states)
            let elapsed = ProcessInfo.processInfo.systemUptime - prefillStarted
            guard let logits = outputs.remove("logits")?.ndArray else {
                throw EngineError.badOutput("stateful prefill logits missing")
            }
            prefillResult = (logits, stateKeys, stateValues, elapsed, 0.0)
        } else {
            var prefillOutputs = try await prefillFunction.run(inputs: inputs)
            let prefillRunSeconds = (
                ProcessInfo.processInfo.systemUptime - prefillStarted)
            guard let prefillLogits = prefillOutputs.remove("logits")?.ndArray,
                  let pk = prefillOutputs.remove("new_k")?.ndArray,
                  let pv = prefillOutputs.remove("new_v")?.ndArray else {
                throw EngineError.badOutput("prefill outputs incomplete")
            }
            if prefillReturnsFullCache {
                // Kept only for diagnosing already-exported v10f assets. New
                // assets use stateful prefill because this output contract has
                // produced incorrect logits after Core AI specialization.
                prefillResult = (
                    prefillLogits, pk, pv, prefillRunSeconds, 0.0)
            } else {
            let assemblyStarted = ProcessInfo.processInfo.systemUptime
            let legacyKeys = try assembleFullCache(
                pk, rows: width, bucket: bucket)
            let legacyValues = try assembleFullCache(
                pv, rows: width, bucket: bucket)
            prefillResult = (
                prefillLogits, legacyKeys, legacyValues, prefillRunSeconds,
                ProcessInfo.processInfo.systemUptime - assemblyStarted)
            }
        }
        let prefillSeconds = prefillResult.prefillSeconds
        let cacheAssemblySeconds = prefillResult.cacheAssemblySeconds
        var keys = prefillResult.keys
        var values = prefillResult.values
        var next = try rowArgmax(prefillResult.logits, rows: width)

        // Decode loop: [width, MAX] mask over the cache slots, per-row
        // cache position. A row's new slot gets its mask bit only
        // AFTER the step that writes it (the incoming token attends
        // via the appended position; a valid bit on the still-zero
        // slot corrupts attention). Rows that hit a stop ride along as
        // inert passengers until every row is done or the budget runs
        // out.
        var dmask = [Int32](repeating: 0, count: width * maxCache)
        var cachePos = [Int32](repeating: 0, count: width)
        var done = [Bool](repeating: false, count: width)
        // Cap-hit ledger: a row is capped when generation ends without a
        // stop token — either the budget loop exhausts while the row is
        // still live, or the static cache fills. Stop-token completions
        // clear the flag.
        var capped = [Bool](repeating: true, count: width)
        var out: [[Int32]] = Array(repeating: [], count: width)
        for (r, row) in rowIDs.enumerated() {
            for i in 0..<row.count { dmask[r * maxCache + i] = 1 }
            cachePos[r] = Int32(row.count)
            done[r] = r >= prompts.count
        }
        // The mask is the only large decode input (B x MAX). Keep one NDArray
        // for the whole generation and flip newly-valid slots in place rather
        // than allocating and copying it for every token.
        var dmaskArray = NDArray(
            scalars: dmask, shape: [width, maxCache])
        let decodeStarted = ProcessInfo.processInfo.systemUptime
        for _ in 0..<maxNewTokens {
            for r in 0..<width where !done[r] {
                if stopIDs.contains(next[r]) {
                    done[r] = true
                    capped[r] = false
                } else if Int(cachePos[r]) >= maxCache {
                    done[r] = true
                } else {
                    out[r].append(next[r])
                    if stopAtCompleteJSON, outputKind == .json,
                       topLevelJSONObjectPrefix(tokenizer.decode(out[r])) != nil {
                        // A complete extraction object is a real structural
                        // termination boundary, not post-hoc capped-output
                        // salvage.  Stop this row before it can continue the
                        // source's timeline/list shape.
                        done[r] = true
                        capped[r] = false
                    }
                }
            }
            if done.allSatisfy({ $0 }) { break }
            var states = InferenceFunction.MutableViews()
            states.insert(&keys, for: "cache_k")
            states.insert(&values, for: "cache_v")
            var stepOut = try await decodeFunction.run(
                inputs: [
                    "input_ids": NDArray(scalars: next, shape: [width, 1]),
                    "attention_mask": dmaskArray,
                    "cache_pos": NDArray(scalars: cachePos, shape: [width]),
                ],
                states: states)
            guard let stepLogits = stepOut.remove("logits")?.ndArray else {
                throw EngineError.badOutput("decode outputs incomplete")
            }
            let stepNext = try rowArgmax(stepLogits, rows: width)
            var maskView = dmaskArray.mutableView(as: Int32.self)
            maskView.withUnsafeMutablePointer { pointer, _, _ in
                for r in 0..<width where !done[r] {
                    pointer[r * maxCache + Int(cachePos[r])] = 1
                    cachePos[r] += 1
                    next[r] = stepNext[r]
                }
            }
        }
        let decodeSeconds = ProcessInfo.processInfo.systemUptime - decodeStarted
        return (0..<prompts.count).map {
            (tokens: out[$0], hitCap: capped[$0],
             prefillSeconds: prefillSeconds,
             cacheAssemblySeconds: cacheAssemblySeconds,
             decodeSeconds: decodeSeconds)
        }
    }

    private func finish(_ out: [Int32]) -> String? {
        let raw = decodedOutput(out)
        let text = normalizeMintOutput(raw, kind: outputKind)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// Decode one generated row under the same structural contract used by
    /// the stop check. Tokenizers may bundle the closing brace and trailing
    /// punctuation into one token, so token-level retention cannot represent
    /// the JSON boundary exactly; trim the decoded output to that boundary.
    private func decodedOutput(_ out: [Int32]) -> String {
        let raw = tokenizer.decode(out)
        guard stopAtCompleteJSON, outputKind == .json else { return raw }
        return topLevelJSONObjectPrefix(raw) ?? raw
    }

    private enum EngineError: Error {
        case badOutput(String)
    }

    /// Copies a bucket-length prefill cache [layers, rows, kv, bucket,
    /// hd] into a fresh MAX-length cache [layers, rows, kv, MAX, hd]
    /// (zeros past the bucket — masked, never attended). Host-side
    /// block copy once per batch (~25MB per row).
    private func assembleFullCache(_ partial: NDArray, rows: Int,
                                   bucket: Int) throws -> NDArray {
        let view = partial.view(as: Float16.self)
        guard let src = view.contiguousElements else {
            throw EngineError.badOutput("prefill cache not contiguous")
        }
        var full = [Float16](
            repeating: 0,
            count: cacheLayers * rows * cacheHeads * maxCache * headDim)
        for block in 0..<(cacheLayers * rows * cacheHeads) {
            let srcBase = block * bucket * headDim
            let dstBase = block * maxCache * headDim
            for i in 0..<(bucket * headDim) {
                full[dstBase + i] = src[srcBase + i]
            }
        }
        return NDArray(
            scalars: full,
            shape: [cacheLayers, rows, cacheHeads, maxCache, headDim])
    }

    /// Per-row argmax over [rows, vocab] logits, fp16 or fp32.
    private func rowArgmax(_ arr: NDArray, rows: Int) throws -> [Int32] {
        switch arr.scalarType {
        case .float16:
            guard let span = arr.view(as: Float16.self).contiguousElements else {
                throw EngineError.badOutput("logits not contiguous")
            }
            let vocab = span.count / rows
            var out = [Int32](repeating: 0, count: rows)
            for r in 0..<rows {
                let base = r * vocab
                var bestIndex = 0
                for i in 1..<vocab where span[base + i] > span[base + bestIndex] {
                    bestIndex = i
                }
                out[r] = Int32(bestIndex)
            }
            return out
        case .float32:
            guard let span = arr.view(as: Float.self).contiguousElements else {
                throw EngineError.badOutput("logits not contiguous")
            }
            let vocab = span.count / rows
            var out = [Int32](repeating: 0, count: rows)
            for r in 0..<rows {
                let base = r * vocab
                var bestIndex = 0
                for i in 1..<vocab where span[base + i] > span[base + bestIndex] {
                    bestIndex = i
                }
                out[r] = Int32(bestIndex)
            }
            return out
        default:
            throw EngineError.badOutput("unexpected logits scalar type")
        }
    }
}
#endif
