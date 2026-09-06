// EncoderActivation.swift
//
// The `"encoder"` value of the `embedding_provider` manifest key: how the
// estate lifecycle turns the active `encoder_models` row into a
// `SpanEncoder`, where the recall rerank stage and the `spanEncode` duty
// fetch it, and the two companion manifest keys (`encoder_head`,
// `encoder_batch`).
//
// The encoder is a rerank stage over the lexical head, not an ensemble
// member: provisioning `"encoder"` leaves the Corpus ensemble exactly as
// configured and registers the encoder beside the VectorStore instead.
//
// Failure contract: a missing model directory, a vocabulary hash mismatch
// or a load failure leaves the estate with NO encoder for the session,
// writes ONE OSLog line on the `GeniusLocusKit` category, and raises
// nothing to the caller. Recall then runs lexical-only.
//
// Mirror: rust/src/coordinator.rs `activate_span_encoder` and
// rust/src/encoder_activation.rs.

import Foundation
import OSLog
import CorpusKit
import LocusKit
import CorpusKitProviders

/// Resolves the on-disk directory holding a model's assets (`vocab.txt`
/// plus the compiled model). The bundling unit supplies the production
/// conformer; the default resolver returns `nil` for every id, which the
/// lifecycle treats as "model unavailable".
public protocol ModelDirectoryResolving: Sendable {
    /// Directory for `modelID`, or `nil` when this device has no copy.
    func encoderModelDirectory(for modelID: String) -> URL?
}

/// The default resolver: no model directories on this device.
public struct NilModelDirectoryResolver: ModelDirectoryResolving {
    /// Create the resolver.
    public init() {}
    public func encoderModelDirectory(for modelID: String) -> URL? { nil }
}

/// The production resolver: `CorpusKitProviders.ModelDirectoryResolver`
/// searched from the mootx01 data directory (the 1.2 download slot) and the
/// process bundle (the bundled model). Serve entry points install it with
/// `setModelDirectoryResolver(_:)` BEFORE the estate is opened and wired, so
/// `applyProvisionedEmbeddingProvider` can activate the encoder; without it
/// the kit keeps `NilModelDirectoryResolver` and every estate runs
/// lexical-only. Twin of Rust `BundledModelDirectoryResolver`.
public struct BundledModelDirectoryResolver: ModelDirectoryResolving {
    /// The mootx01 data directory root (search slot 1, the 1.2 download
    /// location; empty in 1.1).
    public let dataDirectory: URL

    /// Create the resolver over `dataDirectory`.
    public init(dataDirectory: URL) {
        self.dataDirectory = dataDirectory
    }

    public func encoderModelDirectory(for modelID: String) -> URL? {
        ModelDirectoryResolver.encoderModelDirectory(for: modelID, dataDirectory: dataDirectory)
    }
}

public extension GeniusLocusKit {

    /// `embedding_provider` value that activates the span encoder.
    static var encoderProviderID: String { "encoder" }

    /// Manifest key: BM25 head size the rerank stage encodes (Int).
    static var encoderHeadMetaKey: String { "encoder_head" }

    /// Manifest key: spans per inference batch in the duty (Int).
    static var encoderBatchMetaKey: String { "encoder_batch" }

    /// Default `encoder_head` when the manifest carries none.
    static var defaultEncoderHead: Int { 30 }

    /// Default `encoder_batch` when the manifest carries none: 16 on iOS
    /// (memory-constrained), 64 elsewhere.
    static var defaultEncoderBatch: Int {
#if os(iOS)
        16
#else
        64
#endif
    }

    private static var encoderLog: Logger {
        Logger(subsystem: "com.mootx01.kit", category: "GeniusLocusKit")
    }

    // MARK: - Registry

    /// Register a `SpanEncoder` for `handle` so the recall rerank stage and
    /// the `spanEncode` duty read the same instance. Re-registering replaces
    /// the entry; `close(_:)` drops it.
    func registerSpanEncoder(_ encoder: any SpanEncoder, for handle: EstateHandle) {
        spanEncoders[handle] = encoder
    }

    /// The `SpanEncoder` registered for `handle`, or `nil` when the estate
    /// was not provisioned with `"encoder"` or activation failed (see the
    /// failure contract in this file's header).
    func registeredSpanEncoder(for handle: EstateHandle) -> (any SpanEncoder)? {
        spanEncoders[handle]
    }

    /// Install the model-directory resolver used by every later activation.
    /// The bundling unit calls this once at daemon start; tests inject a
    /// scratch-directory resolver.
    func setModelDirectoryResolver(_ resolver: any ModelDirectoryResolving) {
        modelDirectoryResolver = resolver
    }

    // MARK: - Manifest keys

    /// Store `encoder_head` on the estate manifest.
    func provisionEncoderHead(_ head: Int, for handle: EstateHandle) async throws {
        let estate = try estate(for: handle)
        do {
            try await estate.setMeta(key: Self.encoderHeadMetaKey, value: String(head))
        } catch {
            throw remap(verb: "provisionEncoderHead", estateID: handle.estateUUID.uuidString, error: error)
        }
    }

    /// `encoder_head` from the manifest, or `defaultEncoderHead` when the
    /// key is absent or does not parse as a positive integer.
    func provisionedEncoderHead(for handle: EstateHandle) async -> Int {
        await positiveIntMeta(key: Self.encoderHeadMetaKey, for: handle) ?? Self.defaultEncoderHead
    }

    /// Store `encoder_batch` on the estate manifest.
    func provisionEncoderBatch(_ batch: Int, for handle: EstateHandle) async throws {
        let estate = try estate(for: handle)
        do {
            try await estate.setMeta(key: Self.encoderBatchMetaKey, value: String(batch))
        } catch {
            throw remap(verb: "provisionEncoderBatch", estateID: handle.estateUUID.uuidString, error: error)
        }
    }

    /// `encoder_batch` from the manifest, or `defaultEncoderBatch` when the
    /// key is absent or does not parse as a positive integer.
    func provisionedEncoderBatch(for handle: EstateHandle) async -> Int {
        await positiveIntMeta(key: Self.encoderBatchMetaKey, for: handle) ?? Self.defaultEncoderBatch
    }

    /// Fail-quiet positive-Int manifest read: a stale handle, an absent key
    /// or a malformed value all yield `nil` so a bad provision never breaks
    /// an open.
    private func positiveIntMeta(key: String, for handle: EstateHandle) async -> Int? {
        guard let estate = try? estate(for: handle),
              let raw = try? await estate.meta(key: key),
              let value = Int(raw.trimmingCharacters(in: .whitespaces)),
              value > 0 else {
            return nil
        }
        return value
    }

    // MARK: - Activation

    /// The active `encoder_models` row for `handle` as a CorpusKit spec; the
    /// floor model when the registry holds no active row or the estate's
    /// storage is not open (a stale handle never breaks an open).
    func activeEncoderModelSpec(for handle: EstateHandle) async -> EncoderModelSpec {
        guard let storage = storages[handle],
              let row = try? await EncoderModelStore(storage: storage).active() else {
            return EncoderModelSpec.floor
        }
        return EncoderModelSpec(row: row)
    }

    /// Build and register the span encoder for `handle` from the active
    /// registry row, applying the failure contract: nil encoder + one log
    /// line on any failure, no throw.
    func activateSpanEncoder(for handle: EstateHandle) async {
        let spec = await activeEncoderModelSpec(for: handle)
        guard let directory = modelDirectoryResolver.encoderModelDirectory(for: spec.modelID) else {
            Self.encoderLog.warning(
                "encoder: no model directory for \(spec.modelID, privacy: .public); recall runs lexical-only (estate: \(handle.estateUUID, privacy: .public))"
            )
            return
        }
        let batch = await provisionedEncoderBatch(for: handle)
        do {
            let encoder = try SpanEncoderFactory.make(spec: spec, modelDirectory: directory, batchSize: batch)
            registerSpanEncoder(encoder, for: handle)
            // The recall stage reads spans from the estate's VectorStore under
            // the encoder's model id; without a registered store there is
            // nothing to rerank against, so only the duty-side encoder stays.
            if let store = vectorStores[handle] {
                let head = await provisionedEncoderHead(for: handle)
                registerSpanRerank(SpanEncoderQuerySeam(encoder: encoder),
                                   spanVectors: SynapseSpanVectorReader(store: store),
                                   head: head, for: handle)
            } else {
                Self.encoderLog.warning(
                    "encoder: no vector store registered; span rerank stage not registered (estate: \(handle.estateUUID, privacy: .public))"
                )
            }
            Self.encoderLog.info(
                "encoder: activated \(spec.modelID, privacy: .public) from \(directory.path, privacy: .public) (estate: \(handle.estateUUID, privacy: .public))"
            )
        } catch {
            Self.encoderLog.warning(
                "encoder: \(spec.modelID, privacy: .public) unavailable (\(String(describing: error), privacy: .public)); recall runs lexical-only (estate: \(handle.estateUUID, privacy: .public))"
            )
        }
    }
}
