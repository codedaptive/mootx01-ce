// EstateConfiguration.swift
//
// Estate configuration per DECISION_STORAGEKIT_DESIGN §8 (Q6).
// One configuration value per estate; opens one Storage instance.

import Foundation

public struct EstateConfiguration: Sendable {
    public let estateID: UUID
    public let backend: BackendConfiguration
    /// At-rest encryption mode for this estate (Mission ENC-01). Defaults
    /// to `.plaintext` so existing call sites are unchanged: a plaintext
    /// estate behaves exactly as before, with no crypto on any path.
    public let encryptionConfig: EstateEncryptionConfig
    /// Cache configuration for this estate (Mission PK-CACHE-A). Defaults
    /// to `.disabled` so existing call sites are unchanged: a disabled-cache
    /// estate behaves exactly as before, with no cache on any path.
    public let cacheConfig: EstateCacheConfig
    /// Novel-token tagger choice for this estate (Layer-2a, v1.0). Defaults
    /// to `.hmm` — the deterministic, cross-platform baseline. Existing call
    /// sites that do not specify this parameter receive `.hmm`, which is the
    /// intended behavior: this field flips the estate-creation default from
    /// NLTagger (the old implicit Apple-only default) to HMM (the new explicit
    /// cross-platform default). Advanced Apple-only deployments may opt in to
    /// `.nlTagger` at creation time.
    ///
    /// This choice is fixed at creation. Change-after-creation and re-tagging
    /// migration are v1.1 features. See `NovelTokenTaggerChoice` for the full
    /// constraints, especially the federation-incompatibility note.
    public let novelTokenTagger: NovelTokenTaggerChoice

    public init(
        estateID: UUID,
        backend: BackendConfiguration,
        encryptionConfig: EstateEncryptionConfig = .plaintext,
        cacheConfig: EstateCacheConfig = .disabled,
        novelTokenTagger: NovelTokenTaggerChoice = .hmm
    ) {
        self.estateID = estateID
        self.backend = backend
        self.encryptionConfig = encryptionConfig
        self.cacheConfig = cacheConfig
        self.novelTokenTagger = novelTokenTagger
    }
}

public enum BackendConfiguration: Sendable {
    case sqlite(url: URL, busyTimeout: TimeInterval = 5.0)
    case postgresql(
        connectionString: String,
        poolSize: Int = 10,
        connectionTimeout: TimeInterval = 5.0,
        idleTimeout: TimeInterval = 300.0
    )
    case inMemory
}
