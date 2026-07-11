import Foundation
import AppIntents
import UniformTypeIdentifiers

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
private actor HeavyVerbWatchState {
    private var operationFinished = false

    func finish() {
        operationFinished = true
    }

    func isFinished() -> Bool {
        operationFinished
    }
}

@available(macOS 27.0, iOS 27.0, *)
private func watchDrains(
    progress: Progress,
    caller: any MootToolCalling,
    state: HeavyVerbWatchState
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
        // The first poll often happens before the verb has enqueued work. Do
        // not interpret that startup zero as completion; wait until the verb
        // itself has returned and the queues have then settled.
        if outstanding == 0, await state.isFinished() { return }
        try? await Task.sleep(for: .seconds(2))
    }
}

@available(macOS 27.0, iOS 27.0, *)
private func runWatchingDrains(
    progress: Progress,
    caller: any MootToolCalling,
    operation: @escaping @Sendable () async throws -> String
) async throws -> String {
    let state = HeavyVerbWatchState()
    async let watcher: Void = watchDrains(progress: progress, caller: caller, state: state)
    do {
        let result = try await operation()
        await state.finish()
        _ = await watcher
        return result
    } catch {
        await state.finish()
        _ = await watcher
        throw error
    }
}

// MARK: ReindexEstateIntent

/// verb: reindex · rebuild missing derived indexes. Fire-and-poll: the tool
/// acks immediately; progress reads the drain queues until they settle.
@available(macOS 27.0, iOS 27.0, *)
public struct ReindexEstateIntent: MootEstateIntent, LongRunningIntent, CancellableIntent {
    public static let title: LocalizedStringResource = "Reindex Memory Estate"
    public static let description = IntentDescription(
        "Rebuild the memory estate's search indexes.",
        categoryName: "Estate"
    )
    public static let isDiscoverable = true
    public static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    public static let allowedExecutionTargets: IntentExecutionTargets = .main

    public var caller: (any MootToolCalling)?

    public init() {}
    public init(caller: (any MootToolCalling)? = nil) { self.caller = caller }

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let c = try await resolvedCaller(caller)
        let progress = self.progress
        let ack = try await performBackgroundTask {
            try await runWatchingDrains(progress: progress, caller: c) {
                try await HeavyVerbCore.startReindex(caller: c)
            }
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
public struct ImportPalaceIntent: MootEstateIntent, LongRunningIntent, CancellableIntent {
    public static let title: LocalizedStringResource = "Import Memory Palace"
    public static let description = IntentDescription(
        "Import a MemPalace into the memory estate.",
        categoryName: "Estate"
    )
    public static let isDiscoverable = true
    /// Imports mutate the estate wholesale; not from a locked device.
    public static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    public static let allowedExecutionTargets: IntentExecutionTargets = .main

    @Parameter(title: "Palace", supportedContentTypes: [.folder])
    public var palace: IntentFile

    public var caller: (any MootToolCalling)?

    public init() {}
    public init(palace: IntentFile, caller: (any MootToolCalling)? = nil) {
        self.palace = palace
        self.caller = caller
    }

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let c = try await resolvedCaller(caller)
        let progress = self.progress
        let report = try await performBackgroundTask {
            try await palace.withFile(contentType: .folder, allowOpenInPlace: true) { url, _ in
                // background encode speed: yields to the host during very
                // large imports — the right default for an intent-driven run.
                try await runWatchingDrains(progress: progress, caller: c) {
                    try await HeavyVerbCore.importPalace(
                        path: url.path, background: true, caller: c
                    )
                }
            }
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
public struct ImportVaultIntent: MootEstateIntent, LongRunningIntent, CancellableIntent {
    public static let title: LocalizedStringResource = "Import Vault"
    public static let description = IntentDescription(
        "Import a vault of notes into the memory estate.",
        categoryName: "Estate"
    )
    public static let isDiscoverable = true
    public static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    public static let allowedExecutionTargets: IntentExecutionTargets = .main

    @Parameter(title: "Vault", supportedContentTypes: [.folder])
    public var vault: IntentFile

    public var caller: (any MootToolCalling)?

    public init() {}
    public init(vault: IntentFile, caller: (any MootToolCalling)? = nil) {
        self.vault = vault
        self.caller = caller
    }

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let c = try await resolvedCaller(caller)
        let progress = self.progress
        let report = try await performBackgroundTask {
            try await vault.withFile(contentType: .folder, allowOpenInPlace: true) { url, _ in
                try await runWatchingDrains(progress: progress, caller: c) {
                    try await HeavyVerbCore.importVault(
                        path: url.path, background: true, caller: c
                    )
                }
            }
        } onCancel: { _ in
            // Same rationale as ImportPalaceIntent.
        }
        return .result(dialog: IntentDialog(stringLiteral: report))
    }
}

// MARK: DreamEstateIntent

/// verb: dream · accelerator rebuild + one dreaming cycle, blocking.
@available(macOS 27.0, iOS 27.0, *)
public struct DreamEstateIntent: MootEstateIntent, LongRunningIntent, CancellableIntent {
    public static let title: LocalizedStringResource = "Dream"
    public static let description = IntentDescription(
        "Rebuild derived accelerators and run one dreaming cycle over the estate.",
        categoryName: "Estate"
    )
    public static let isDiscoverable = true
    public static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    public static let allowedExecutionTargets: IntentExecutionTargets = .main

    public var caller: (any MootToolCalling)?

    public init() {}
    public init(caller: (any MootToolCalling)? = nil) { self.caller = caller }

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let c = try await resolvedCaller(caller)
        let progress = self.progress
        let report = try await performBackgroundTask {
            try await runWatchingDrains(progress: progress, caller: c) {
                try await HeavyVerbCore.dream(caller: c)
            }
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
