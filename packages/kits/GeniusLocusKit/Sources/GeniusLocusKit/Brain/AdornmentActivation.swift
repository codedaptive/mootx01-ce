import AdornmentLib
import Foundation
import LocusKit
import OSLog

private let activationLog = Logger(subsystem: "com.mootx01.kit", category: "GeniusLocusKit")

// MARK: - Active-minter adornment orchestration (GENIUSLOCUSKIT_INTERFACE 2.0.0)
//
// These methods expose the LocusKit normalized adornment store through the
// GeniusLocusKit actor boundary. The coordinator delegates registration,
// activation, and active reads to the open estate without caching:
//
//  - Registration and activation writes route through the LocusKit
//    DrawerStore so all mutations land in the `adornment_minters` table,
//    never in actor-level state.
//  - The `activeAdornments` projection is call-scoped: the actor MUST NOT
//    cache an active set across result-composition calls (SPEC § 16.2).
//
// `runAdornmentPass` is the public entry point for BOTH the production
// scheduled path AND the harness `moot_run_adornment_pass` dark tool.
// The old `runAdornmentPass(handle:now:) -> Int` and its harness overload
// are retired; callers read `AdornmentPassResult` directly.

public extension GeniusLocusKit {

    // MARK: - Registration

    /// Register or replace one adornment minter for the given estate.
    ///
    /// Delegates to `Estate.registerAdornmentMinter(_:)` which upserts the
    /// minter row in the estate's `adornment_minters` table. An unknown minter
    /// ID inserts a new row; a known ID replaces all fields except `is_active`
    /// (activation is a separate `setAdornmentMinterActive` call).
    ///
    /// - Parameters:
    ///   - handle: the estate to register the minter in. Must be open.
    ///   - minter: the complete descriptor to register.
    /// - Throws: `GeniusLocusKitError.estateNotOpen` if `handle` is stale.
    func registerAdornmentMinter(
        in handle: EstateHandle,
        minter: AdornmentMinterDescriptor
    ) async throws {
        let estateObj = try estate(for: handle)
        activationLog.debug(
            "registerAdornmentMinter: id=\(minter.id) name=\(minter.name) active=\(minter.isActive)")
        try await estateObj.registerAdornmentMinter(minter)
    }

    // MARK: - Activation

    /// Set the active flag for one minter. Returns 1 when the minter exists,
    /// 0 when it does not (no-op, not an error).
    ///
    /// Delegates to `Estate.setAdornmentMinterActive(id:active:)`. The
    /// activation lookup is call-scoped — the process MUST NOT cache an active
    /// set across result-composition calls (GENIUSLOCUSKIT_SPEC § 16.2).
    ///
    /// - Parameters:
    ///   - handle: the open estate.
    ///   - minterID: identifier of the minter to toggle.
    ///   - active: `true` to activate, `false` to deactivate.
    /// - Returns: 1 if the row existed, 0 if no such minter is registered.
    /// - Throws: `GeniusLocusKitError.estateNotOpen` if `handle` is stale.
    @discardableResult
    func setAdornmentMinterActive(
        in handle: EstateHandle,
        minterID: String,
        active: Bool
    ) async throws -> Int {
        let estateObj = try estate(for: handle)
        activationLog.debug(
            "setAdornmentMinterActive: id=\(minterID) active=\(active)")
        return try await estateObj.setAdornmentMinterActive(id: minterID, active: active)
    }

    /// Atomically replace the active minter set in one transaction.
    ///
    /// Deactivates ALL current minters then activates only the listed IDs.
    /// Returns the count of rows that were activated. An unknown ID in the
    /// set fails WITHOUT mutation — either all listed IDs are known or the
    /// entire transaction is rolled back and an error is thrown.
    ///
    /// Multi-minter activation sets are replaced in one transaction so
    /// composition observes the complete old or new set — never a partial
    /// intermediate state (GENIUSLOCUSKIT_SPEC § 16.1).
    ///
    /// - Parameters:
    ///   - handle: the open estate.
    ///   - minterIDs: the complete set of minter IDs that should be active.
    ///     An empty set deactivates all minters.
    /// - Returns: total rows updated in the replacement transaction
    ///   (deactivations plus activations, per `Estate.setActiveAdornmentMinters`).
    /// - Throws: `GeniusLocusKitError.estateNotOpen` if `handle` is stale;
    ///   store errors if any ID is unknown (transaction rolled back).
    @discardableResult
    func setActiveAdornmentMinters(
        in handle: EstateHandle,
        minterIDs: Set<String>
    ) async throws -> Int {
        let estateObj = try estate(for: handle)
        activationLog.debug(
            "setActiveAdornmentMinters: ids=\(minterIDs.sorted().joined(separator: ","))")
        return try await estateObj.setActiveAdornmentMinters(ids: minterIDs)
    }

    // MARK: - Active-adornment projection

    /// Return the active adornments for a batch of drawers.
    ///
    /// Delegates to `Estate.activeAdornments(drawerIDs:)`, which issues a
    /// single joined batch read. The returned mapping contains every stored
    /// adornment whose minter is currently active, ordered by minter ID within
    /// each drawer entry. It can contain no entry, one value, or many values
    /// for each drawer.
    ///
    /// This is the ONLY result-composition read (GENIUSLOCUSKIT_SPEC § 16.2).
    /// The activation lookup is call-scoped; callers MUST NOT cache the result
    /// across composition calls.
    ///
    /// - Parameters:
    ///   - handle: the open estate.
    ///   - drawerIDs: drawer IDs to query. Empty input returns an empty map.
    /// - Returns: `[drawerID: [StoredAdornment]]` — zero, one, or many active
    ///   adornments per drawer, in ascending minter-ID order.
    /// - Throws: `GeniusLocusKitError.estateNotOpen` if `handle` is stale.
    func activeAdornments(
        in handle: EstateHandle,
        drawerIDs: [String]
    ) async throws -> [String: [StoredAdornment]] {
        let estateObj = try estate(for: handle)
        return try await estateObj.activeAdornments(drawerIDs: drawerIDs)
    }

    // MARK: - AdornmentPass entry points

    /// Run one adornment pass against the addressed estate.
    ///
    /// Production path and harness overload combined. The `maxAdornmentLength`
    /// parameter is `Optional`: `nil` uses the product constant
    /// `ADORNMENT_MAX_LENGTH` (AdornmentLib). The ceiling is resolved at ONE
    /// point — here — so callers (including the moot_run_adornment_pass dark
    /// tool) pass `nil` when no override is set and never resolve the default
    /// themselves.
    ///
    /// Batch size defaults to `AdornmentPass.defaultBatchSize` (50 pairs).
    ///
    /// - Parameters:
    ///   - handle: the estate to adorn. Must be open.
    ///   - batchSize: maximum (drawer, minter) pairs per invocation.
    ///   - maxAdornmentLength: character-count ceiling override, or nil for
    ///     the product default `ADORNMENT_MAX_LENGTH`.
    ///   - now: deterministic clock from the caller.
    /// - Returns: `AdornmentPassResult` with adornedPairs / failedPairs / skippedPairs.
    /// - Throws: `GeniusLocusKitError.estateNotOpen` if `handle` is stale.
    func runAdornmentPass(
        handle: EstateHandle,
        batchSize: Int = AdornmentPass.defaultBatchSize,
        maxAdornmentLength: Int? = nil,
        now: Date
    ) async throws -> AdornmentPassResult {
        let estateObj = try estate(for: handle)
        // Resolve the length ceiling: nil → product constant.
        // This is the single resolution point for ADORNMENT_MAX_LENGTH;
        // callers forward nil when no override is set.
        let length = maxAdornmentLength ?? ADORNMENT_MAX_LENGTH
        // Custom generator resolver threads the resolved ceiling so the
        // harness ceiling override is honored end-to-end. Generation drives
        // the resident GoldMiner exactly like AdornmentPass.run's default
        // resolver: installed engine, else the explicit MOOT_MINT_CMD
        // harness engine, else the platform default (Apple's on-device
        // model), else nil
        // (pair counted failed, retried next pass). This is the inline
        // default-minter path (Bob ruling 2026-08-28) — the command seam is
        // one engine the miner can resolve, never the only one.
        return try await AdornmentPass.run(
            estate: estateObj,
            batchSize: batchSize,
            generatorResolver: { minter, drawer in
                await mintAdornmentMapReduce(
                    drawerContent: drawer.content,
                    eventDate: drawer.eventTime.ISO8601Format(),
                    maxLength: length
                ) { prompt in
                    guard let raw = await GoldMiner.shared.mintOne(prompt: prompt) else {
                        return nil
                    }
                    // Mechanical truncation at the resolved ceiling: engines
                    // return raw text; the seam owns the ceiling.
                    let candidate = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    return candidate.isEmpty ? nil : String(candidate.prefix(length))
                }
            },
            now: now)
    }

    // MARK: - Default-minter registration

    /// Ensure the platform-default adornment minter is registered in the
    /// estate (Bob ruling 2026-08-28: default minters run inline — Swift's
    /// default is the Apple FoundationModels recipe).
    ///
    /// Idempotent per open: `registerAdornmentMinter` is an upsert that
    /// NEVER retoggles `is_active` on an existing row, so a fresh estate
    /// gets the default registered ACTIVE, while an operator who
    /// deactivated it stays deactivated across reopens. The row id is the
    /// composed recipe id (`apple-fm-p<N>-s<N>`), the same identity the
    /// engine stamps on its adornment rows.
    ///
    /// - Parameter handle: the open estate.
    /// - Throws: `GeniusLocusKitError.estateNotOpen` if `handle` is stale.
    func ensureDefaultAdornmentMinter(in handle: EstateHandle) async throws {
        let recipe = MinterRecipe.apple
        try await registerAdornmentMinter(
            in: handle,
            minter: recipe.descriptor(id: recipe.id, isActive: true))
    }
}
