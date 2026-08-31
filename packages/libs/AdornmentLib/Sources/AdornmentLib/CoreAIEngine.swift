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
    case plain
    case nuextract
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
    private let tokenizer: QwenTokenizer
    private let stopIDs: Set<Int32>
    /// Claim-length budget: adornments are one dense line; 96 tokens is
    /// ~3x the observed claim length, so the budget never truncates a
    /// well-formed claim and bounds a runaway generation.
    private let maxNewTokens = 96
    private let style: CoreAIPromptStyle
    private let outputKind: MintOutputKind

    public init(assetPath: String, tokenizerPath: String, identity: String,
                style: CoreAIPromptStyle = .chat) async throws {
        self.identity = identity
        self.style = style
        self.outputKind = style == .nuextract ? .json : .text
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
        self.prefillFunction = prefill
        self.decodeFunction = decode
    }

    public func mint(prompt: String) async -> String? {
        do {
            // Single mints ride the batch graph with dummy passenger
            // rows — the batch shape is static.
            let outs = try await generate([frameFor(prompt)])
            return finish(outs[0])
        } catch {
            // Per-prompt failure contract: nil, never throw.
            log.error("CoreAIEngine \(self.identity): mint failed — \(error)")
            return nil
        }
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
                claims.append(contentsOf: outs.map(finish))
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
        case .plain:
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
    /// token array per real prompt.
    private func generate(_ prompts: [String]) async throws -> [[Int32]] {
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

        // Batched prefill: one shared 128-token bucket (the mask makes
        // the tail pads inert), per-row read positions.
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
        var outputs = try await prefillFunction.run(inputs: [
            "input_ids": NDArray(scalars: ids, shape: [width, bucket]),
            "attention_mask": NDArray(scalars: pmask, shape: [width, bucket]),
            "position": NDArray(scalars: positions, shape: [width]),
        ])
        guard let logits = outputs.remove("logits")?.ndArray,
              let pk = outputs.remove("new_k")?.ndArray,
              let pv = outputs.remove("new_v")?.ndArray else {
            throw EngineError.badOutput("prefill outputs incomplete")
        }
        var next = try rowArgmax(logits, rows: width)
        // The cache rides as runtime STATE: allocated once per batch,
        // scatter-mutated in place by every decode step. Only the
        // logits cross the graph boundary per step — returning the
        // cache each step made step cost proportional to B x MAX.
        var keys = try assembleFullCache(pk, rows: width, bucket: bucket)
        var values = try assembleFullCache(pv, rows: width, bucket: bucket)

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
        var out: [[Int32]] = Array(repeating: [], count: width)
        for (r, row) in rowIDs.enumerated() {
            for i in 0..<row.count { dmask[r * maxCache + i] = 1 }
            cachePos[r] = Int32(row.count)
            done[r] = r >= prompts.count
        }
        for _ in 0..<maxNewTokens {
            for r in 0..<width where !done[r] {
                if stopIDs.contains(next[r]) || Int(cachePos[r]) >= maxCache {
                    done[r] = true
                } else {
                    out[r].append(next[r])
                }
            }
            if done.allSatisfy({ $0 }) { break }
            var states = InferenceFunction.MutableViews()
            states.insert(&keys, for: "cache_k")
            states.insert(&values, for: "cache_v")
            var stepOut = try await decodeFunction.run(
                inputs: [
                    "input_ids": NDArray(scalars: next, shape: [width, 1]),
                    "attention_mask": NDArray(scalars: dmask,
                                              shape: [width, maxCache]),
                    "cache_pos": NDArray(scalars: cachePos, shape: [width]),
                ],
                states: states)
            guard let stepLogits = stepOut.remove("logits")?.ndArray else {
                throw EngineError.badOutput("decode outputs incomplete")
            }
            let stepNext = try rowArgmax(stepLogits, rows: width)
            for r in 0..<width where !done[r] {
                dmask[r * maxCache + Int(cachePos[r])] = 1
                cachePos[r] += 1
                next[r] = stepNext[r]
            }
        }
        return Array(out.prefix(prompts.count))
    }

    private func finish(_ out: [Int32]) -> String? {
        let raw = tokenizer.decode(out)
        let text = normalizeMintOutput(raw, kind: outputKind)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
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
