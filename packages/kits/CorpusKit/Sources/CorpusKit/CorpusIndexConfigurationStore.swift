#if CORPUSKIT_STANDALONE_PASSAGES
// CorpusIndexConfigurationStore.swift
//
// Standalone-only authority for the passage-window policy bound to one
// CorpusKit database. This source compiles to nothing in the GLK/MOOTx01
// build because that build does not enable the StandalonePassages trait.

import PersistenceKit

extension CorpusIndexUnitPolicy {
    static let passageTokenizerID = "corpus-alphanumeric-v1"
    static let passagePolicyVersion: Int64 = 1

    var persistedFingerprint: String {
        switch self {
        case .wholeContent:
            return "whole-content-v1"
        case .tokenWindows(let window, let overlap):
            return "token-windows-v1:\(Self.passageTokenizerID):\(window):\(overlap)"
        }
    }

    var persistedWindow: Int? {
        guard case .tokenWindows(let window, _) = self else { return nil }
        return window
    }

    var persistedOverlap: Int? {
        guard case .tokenWindows(_, let overlap) = self else { return nil }
        return overlap
    }
}

/// Persists exactly one active index-unit policy per standalone database.
///
/// Reopening with a different policy is rejected rather than silently
/// interpreting rows under new boundaries. A caller must explicitly rebuild
/// the derived generation before binding a replacement policy.
public actor CorpusIndexConfigurationStore {
    public static let schemaDeclaration = SchemaDeclaration(
        kitID: "CorpusKitIndexConfiguration",
        version: 1,
        tables: [
            TableDeclaration(
                name: "corpus_index_configuration",
                columns: [
                    .int("singleton_id", nullable: false),
                    .int("policy_version", nullable: false),
                    .text("policy_fingerprint", nullable: false),
                    .text("tokenizer_id", nullable: false),
                    .int("window_tokens", nullable: true),
                    .int("overlap_tokens", nullable: true),
                ],
                primaryKey: ["singleton_id"]),
        ])

    private let storage: any Storage

    public init(storage: any Storage) {
        self.storage = storage
    }

    public func fingerprint() async throws -> String? {
        let rows = try await storage.rowStore.query(
            table: "corpus_index_configuration",
            where: .eq(
                Column(table: "corpus_index_configuration", name: "singleton_id"),
                .int(1)),
            orderBy: [], limit: 1, offset: nil)
        guard let row = rows.first,
              case let .text(fingerprint)? = row["policy_fingerprint"] else {
            return nil
        }
        return fingerprint
    }

    /// Bind the database on first open, or prove an existing binding matches.
    public func bind(_ policy: CorpusIndexUnitPolicy) async throws {
        let requested = policy.persistedFingerprint
        if let existing = try await fingerprint() {
            guard existing == requested else {
                throw CorpusKitError.invalidConfiguration(
                    "standalone database is indexed with policy \(existing), but "
                    + "the caller requested \(requested); explicitly rebuild the "
                    + "derived generation before changing passage windows")
            }
            return
        }

        if case .tokenWindows = policy {
            let checkpoints = try await storage.rowStore.count(
                table: "corpus_index_state", where: nil)
            let indexedUnits = try await storage.rowStore.count(
                table: "iix_doclens", where: nil)
            guard checkpoints == 0, indexedUnits == 0 else {
                throw CorpusKitError.invalidConfiguration(
                    "existing standalone derived state has no bound passage policy; "
                    + "open it as whole-content or explicitly rebuild before enabling "
                    + "passage windows")
            }
        }

        var values: [String: TypedValue] = [
            "singleton_id": .int(1),
            "policy_version": .int(CorpusIndexUnitPolicy.passagePolicyVersion),
            "policy_fingerprint": .text(requested),
            "tokenizer_id": .text(CorpusIndexUnitPolicy.passageTokenizerID),
        ]
        if let window = policy.persistedWindow {
            values["window_tokens"] = .int(Int64(window))
        }
        if let overlap = policy.persistedOverlap {
            values["overlap_tokens"] = .int(Int64(overlap))
        }
        do {
            _ = try await storage.rowStore.insert(
                table: "corpus_index_configuration", values: values)
        } catch {
            // Another opener may have won the singleton insert. Accept only
            // an identical binding; a different winner is a hard mismatch.
            if let winner = try await fingerprint() {
                guard winner == requested else {
                    throw CorpusKitError.invalidConfiguration(
                        "standalone database was concurrently bound to policy \(winner), but "
                        + "the caller requested \(requested)")
                }
                return
            }
            throw error
        }
    }
}
#endif
