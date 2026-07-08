import Foundation
import AppIntents

// MARK: - Heavy-verb intents  (M-MXA-3R — the 27-gated surface)
//
// LongRunningIntent + CancellableIntent adoption over HeavyVerbCore. Same
// host-skew pattern as BatchCurationIntents.swift: 2027-wave symbols are
// absent from a macOS 26 runtime, so this whole file is @available 27 and
// the kit's 26 floor weak-links it; runtime verification (Live Activity
// progress + stop button, work item 3) happens on an OS-27 runtime via the
// M-MXA-4 lane. Execution semantics are testable today through the core.
//
// Cancellation ground rule (spec, verbatim intent): an interrupted import
// may not leave the estate violating the import guards. Both import verbs
// and dream BLOCK inside a single tool call whose guards are internal, so
// cancellation here means "abandon the wait, tell the user the work is
// finishing" — the transaction boundary is the whole call, and the system
// reclaiming us cannot corrupt the estate. Reindex is fire-and-poll; cancel
// stops the watcher, and the server-side single-flight task completes.

/// Shared progress watcher: counts outstanding drain work down while a
/// heavy verb runs, so the system's automatic Live Activity shows movement.
@available(macOS 27.0, iOS 27.0, *)
private func watchDrains(
    progress: Progress, caller: any MootToolCalling
) async {
    var peak = 0
    while !Task.isCancelled {
        let outstanding = HeavyVerbCore.outstandingWork(
            await HeavyVerbCore.drainSnapshots(caller: caller)
        )
        peak = max(peak, outstanding)
        if peak > 0 {
            progress.totalUnitCount = Int64(peak)
            progress.completedUnitCount = Int64(peak - outstanding)
        }
        if outstanding == 0 { return }
        try? await Task.sleep(for: .seconds(2))
    }
}

// MARK: ReindexEstateIntent

/// verb: reindex · rebuild missing derived indexes. Fire-and-poll: the tool
/// acks immediately; progress reads the drain queues until they settle.
@available(macOS 27.0, iOS 27.0, *)
public struct ReindexEstateIntent: AppIntent, LongRunningIntent, CancellableIntent {
    public static let title: LocalizedStringResource = "Reindex Memory Estate"
    public static let description = IntentDescription(
        "Rebuild the memory estate's search indexes.",
        categoryName: "Estate"
    )
    public static let isDiscoverable = true

    public var caller: (any MootToolCalling)?

    public init() {}
    public init(caller: (any MootToolCalling)? = nil) { self.caller = caller }

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let c = try await resolvedCaller(caller)
        let progress = self.progress
        let ack = try await performBackgroundTask {
            let ack = try await HeavyVerbCore.startReindex(caller: c)
            await watchDrains(progress: progress, caller: c)
            return ack
        } onCancel: { _ in
            // Reindex is server-side single-flight and not interruptible;
            // cancel only stops the progress watcher (see header).
        }
        return .result(dialog: IntentDialog(stringLiteral: ack))
    }
}

// MARK: ImportPalaceIntent

/// verb: palace import · blocking; the four import guards are inside the
/// call, so cancellation can never leave a partial-guard state.
@available(macOS 27.0, iOS 27.0, *)
public struct ImportPalaceIntent: AppIntent, LongRunningIntent, CancellableIntent {
    public static let title: LocalizedStringResource = "Import Memory Palace"
    public static let description = IntentDescription(
        "Import a MemPalace into the memory estate.",
        categoryName: "Estate"
    )
    public static let isDiscoverable = true
    /// Imports mutate the estate wholesale; not from a locked device.
    public static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Palace Path") public var palacePath: String

    public var caller: (any MootToolCalling)?

    public init() {}
    public init(palacePath: String, caller: (any MootToolCalling)? = nil) {
        self.palacePath = palacePath
        self.caller = caller
    }

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let c = try await resolvedCaller(caller)
        let progress = self.progress
        let report = try await performBackgroundTask {
            // background encode speed: yields to the host during very large
            // imports — the right default for an intent-driven run.
            async let watcher: Void = watchDrains(progress: progress, caller: c)
            let report = try await HeavyVerbCore.importPalace(
                path: palacePath, background: true, caller: c
            )
            _ = await watcher
            return report
        } onCancel: { _ in
            // The blocking import call completes server-side; abandoning the
            // wait cannot violate the import guards (transaction boundary is
            // the whole call).
        }
        return .result(dialog: IntentDialog(stringLiteral: report))
    }
}

// MARK: ImportVaultIntent

/// verb: vault import · same blocking/guard/cancellation shape as palace.
@available(macOS 27.0, iOS 27.0, *)
public struct ImportVaultIntent: AppIntent, LongRunningIntent, CancellableIntent {
    public static let title: LocalizedStringResource = "Import Vault"
    public static let description = IntentDescription(
        "Import a vault of notes into the memory estate.",
        categoryName: "Estate"
    )
    public static let isDiscoverable = true
    public static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Vault Path") public var vaultPath: String

    public var caller: (any MootToolCalling)?

    public init() {}
    public init(vaultPath: String, caller: (any MootToolCalling)? = nil) {
        self.vaultPath = vaultPath
        self.caller = caller
    }

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let c = try await resolvedCaller(caller)
        let progress = self.progress
        let report = try await performBackgroundTask {
            async let watcher: Void = watchDrains(progress: progress, caller: c)
            let report = try await HeavyVerbCore.importVault(
                path: vaultPath, background: true, caller: c
            )
            _ = await watcher
            return report
        } onCancel: { _ in
            // Same rationale as ImportPalaceIntent.
        }
        return .result(dialog: IntentDialog(stringLiteral: report))
    }
}

// MARK: DreamEstateIntent

/// verb: dream · accelerator rebuild + one dreaming cycle, blocking.
@available(macOS 27.0, iOS 27.0, *)
public struct DreamEstateIntent: AppIntent, LongRunningIntent, CancellableIntent {
    public static let title: LocalizedStringResource = "Dream"
    public static let description = IntentDescription(
        "Rebuild derived accelerators and run one dreaming cycle over the estate.",
        categoryName: "Estate"
    )
    public static let isDiscoverable = true

    public var caller: (any MootToolCalling)?

    public init() {}
    public init(caller: (any MootToolCalling)? = nil) { self.caller = caller }

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let c = try await resolvedCaller(caller)
        let progress = self.progress
        let report = try await performBackgroundTask {
            async let watcher: Void = watchDrains(progress: progress, caller: c)
            let report = try await HeavyVerbCore.dream(caller: c)
            _ = await watcher
            return report
        } onCancel: { _ in
            // Blocking single call; abandoning the wait is guard-safe.
        }
        return .result(dialog: IntentDialog(stringLiteral: report))
    }
}

/// Shared caller fallback (same shape every intent in this kit uses).
@MainActor
private func resolvedCaller(_ injected: (any MootToolCalling)?) async throws -> any MootToolCalling {
    if let injected { return injected }
    return try await IntentRuntimeBridge.shared.bridge()
}
