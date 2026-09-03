// IndexCompositionSetting.swift
//
// The index composition policy as a stored estate setting.
//
// Which text each search index lane is built from (CorpusKit
// `IndexCompositionPolicy`: lexical and dense sources, id
// `lex=<source>;dense=<source>`) is a fact about the rows an estate holds,
// so it lives in the estate: LocusKit manifest key `index_composition_policy`
// (`ManifestKey.indexCompositionPolicy`). The setting is written once, when
// the estate is created (`provision`, the migration catalog's fresh-estate
// branch) or when the estate-format 1.3 to 1.4 capsule seeds a populated
// estate; it is read at every open (`wireSubstores`) and shown by
// `moot_estate_status`; it changes only through
// `setIndexCompositionPolicy(_:for:)`, whose caller (`mootx01 db composition
// --set`) rebuilds every index lane in the same command so the stored id and
// the `corpus_index_state.composition_policy` rows never disagree.
//
// The MOOT_INDEX_COMPOSITION environment variable is read in exactly one
// place, `indexCompositionPolicyCreationSeed(environment:)`, and only when
// the setting is being seeded, so a gauntlet clone can still be created
// under a chosen policy while two processes opening one estate can never
// index it differently.
//
// Rust twin: `coordinator.rs` (`stored_index_composition_policy`,
// `set_index_composition_policy`, `seed_index_composition_policy_if_absent`,
// `index_composition_policy_creation_seed`, `active_index_composition_policy`,
// `index_composition_policy_row_counts`).
//
// Logging: Apple OSLog, subsystem "com.mootx01.kit", category "GeniusLocusKit".

import CorpusKit
import Foundation
import LocusKit
import os.log

private let settingLog = Logger(subsystem: "com.mootx01.kit", category: "GeniusLocusKit")

public extension GeniusLocusKit {

    /// The manifest key the stored setting lives under: `index_composition_policy`.
    static var indexCompositionPolicyMetaKey: String {
        ManifestKey.indexCompositionPolicy.rawValue
    }

    /// The environment variable consulted when the setting is seeded.
    static let indexCompositionPolicyEnvironmentKey = "MOOT_INDEX_COMPOSITION"

    /// The policy a seed writes: `MOOT_INDEX_COMPOSITION` when it is set to a
    /// valid policy id, else `.current`. Pure; the only reader of the variable.
    static func indexCompositionPolicyCreationSeed(
        environment: [String: String]
    ) -> IndexCompositionPolicy {
        guard let raw = environment[indexCompositionPolicyEnvironmentKey], !raw.isEmpty else {
            return .current
        }
        guard let policy = IndexCompositionPolicy.fromEnvironmentValue(raw) else {
            settingLog.warning(
                "index composition seed: \(indexCompositionPolicyEnvironmentKey, privacy: .public)='\(raw, privacy: .public)' is not a policy id; seeding \(IndexCompositionPolicy.current.id, privacy: .public)")
            return .current
        }
        return policy
    }

    /// The stored setting, or nil when the estate carries none.
    ///
    /// - Throws: `GeniusLocusKitError.estateNotOpen` for a stale handle;
    ///   `GeniusLocusKitError.invalidManifest` when the stored value is not a
    ///   policy id (the estate is refused rather than indexed under a guess).
    func storedIndexCompositionPolicy(for handle: EstateHandle) async throws -> IndexCompositionPolicy? {
        let estate = try estate(for: handle)
        let raw: String?
        do {
            raw = try await estate.meta(key: Self.indexCompositionPolicyMetaKey)
        } catch {
            throw remap(verb: "storedIndexCompositionPolicy", estateID: handle.estateUUID.uuidString, error: error)
        }
        guard let raw, !raw.isEmpty else { return nil }
        guard let policy = IndexCompositionPolicy.fromEnvironmentValue(raw) else {
            throw GeniusLocusKitError.invalidManifest(
                key: Self.indexCompositionPolicyMetaKey,
                detail: "'\(raw)' is not an index composition policy id (expected lex=<source>;dense=<source>)")
        }
        return policy
    }

    /// Write the setting. Touches no index row: the caller rebuilds every
    /// lane under the new policy (`reindexCorpus(handle:now:)` on a Corpus
    /// wired with `reindexPending: true`) before the estate serves a query.
    ///
    /// - Throws: `GeniusLocusKitError.estateNotOpen` for a stale handle.
    func setIndexCompositionPolicy(_ policy: IndexCompositionPolicy, for handle: EstateHandle) async throws {
        let estate = try estate(for: handle)
        do {
            try await estate.setMeta(key: Self.indexCompositionPolicyMetaKey, value: policy.id)
        } catch {
            throw remap(verb: "setIndexCompositionPolicy", estateID: handle.estateUUID.uuidString, error: error)
        }
        settingLog.info(
            "index composition policy stored: \(policy.id, privacy: .public) (estate: \(handle.estateUUID, privacy: .public))")
    }

    /// `id` as a normalized policy id when it parses, else nil. Pure; lets a
    /// host refuse a malformed `--set` argument before it opens anything.
    static func indexCompositionPolicyID(parsing id: String) -> String? {
        IndexCompositionPolicy.fromEnvironmentValue(id)?.id
    }

    /// The stored setting as its id string, for hosts that hold no CorpusKit
    /// import (the `mootx01` CLI). nil when the estate carries none.
    func storedIndexCompositionPolicyID(for handle: EstateHandle) async throws -> String? {
        try await storedIndexCompositionPolicy(for: handle)?.id
    }

    /// Validate `id` and write it as the setting; returns the id as stored.
    /// Refuses before any write when `id` is not a policy id.
    ///
    /// - Throws: `GeniusLocusKitError.invalidManifest` for a malformed id;
    ///   `GeniusLocusKitError.estateNotOpen` for a stale handle.
    @discardableResult
    func setIndexCompositionPolicy(id: String, for handle: EstateHandle) async throws -> String {
        guard let policy = IndexCompositionPolicy.fromEnvironmentValue(id) else {
            throw GeniusLocusKitError.invalidManifest(
                key: Self.indexCompositionPolicyMetaKey,
                detail: "'\(id)' is not an index composition policy id (expected lex=<source>;dense=<source>)")
        }
        try await setIndexCompositionPolicy(policy, for: handle)
        return policy.id
    }

    /// Seed the setting when the estate carries none and return the policy
    /// the estate now runs under. Idempotent: a stored setting is returned
    /// untouched. Called at estate creation and by the 1.3 to 1.4 capsule.
    ///
    /// - Parameter environment: where the creation-time seed is read from;
    ///   the process environment unless a test supplies its own.
    @discardableResult
    func seedIndexCompositionPolicyIfAbsent(
        for handle: EstateHandle,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async throws -> IndexCompositionPolicy {
        if let stored = try await storedIndexCompositionPolicy(for: handle) {
            return stored
        }
        let policy = Self.indexCompositionPolicyCreationSeed(environment: environment)
        try await setIndexCompositionPolicy(policy, for: handle)
        return policy
    }

    /// The policy every open runs under: the stored setting. An estate that
    /// carries none (its format stamp predates 1.4 and the catalog has not
    /// run, or the row was deleted by hand) runs `.current` and says so in
    /// the log, because the Corpus must still open; `mootx01 db composition
    /// --set` or `mootx01 upgrade` seeds it.
    func activeIndexCompositionPolicy(for handle: EstateHandle) async throws -> IndexCompositionPolicy {
        if let stored = try await storedIndexCompositionPolicy(for: handle) {
            settingLog.info(
                "index composition policy: \(stored.id, privacy: .public) (stored; estate: \(handle.estateUUID, privacy: .public))")
            return stored
        }
        settingLog.warning(
            "index composition policy: no stored setting; running \(IndexCompositionPolicy.current.id, privacy: .public) (estate: \(handle.estateUUID, privacy: .public)); seed it with `mootx01 upgrade` or `mootx01 db composition --set`")
        return .current
    }

    /// Active index rows grouped by the policy id each row was built under.
    /// Empty for an estate with no Corpus (locusOnly) or no indexed rows. A
    /// row written before the column existed counts under `.current`, the
    /// policy it was built under. After `reindexCorpus(handle:now:)` every
    /// row carries the wired Corpus's policy id.
    ///
    /// - Throws: `GeniusLocusKitError.estateNotOpen` for a stale handle.
    func indexCompositionPolicyRowCounts(for handle: EstateHandle) async throws -> [String: Int] {
        guard registry[handle] != nil else {
            throw GeniusLocusKitError.estateNotOpen(estateUUID: handle.estateUUID)
        }
        guard let corpus = corpusKits[handle] else { return [:] }
        var counts: [String: Int] = [:]
        for state in try await corpus.allIndexStates()
        where state.isLexicallyIndexed && !state.isRemoved {
            let id = state.compositionPolicyID.isEmpty
                ? IndexCompositionPolicy.current.id
                : state.compositionPolicyID
            counts[id, default: 0] += 1
        }
        return counts
    }
}
