import Foundation
import MootCommunityGateway
import Observation

/// State and actions for the open Community application surface.
///
/// This model can only reach the Community gateway module. Pro services are
/// absent from its dependency graph rather than disabled by a runtime flag.
@MainActor
@Observable
public final class CommunityAppModel {
    public var recallQuery = ""
    public var recallResult = ""
    public private(set) var connectionState: CommunityDaemonConnectionState = .starting
    public private(set) var estateIdentity: EstateIdentity?
    public let setupModel: CommunitySetupModel
    public let captureModel: CommunityCaptureModel
    public let operationsWorkspaceModel: CommunityOperationsWorkspaceModel
    public let reviewCenterModel: ReviewCenterModel
    public let obsidianSyncModel: ObsidianSyncModel
    public let transferModel: TransferModel
    public let lanControlModel: LANControlModel

    public var isEstateReady: Bool {
        guard case .ready(let identity) = connectionState,
              case .daemon(let connectedEstateID, _) = identity,
              case .ready(let receipt) = setupModel.state else { return false }
        return bridge != nil && receipt.estate.id == connectedEstateID
    }

    public var status: String {
        switch connectionState {
        case .unavailable:
            return String(localized: "Resident daemon unavailable")
        case .starting:
            return String(localized: "Connecting to resident daemon…")
        case .shuttingDown:
            return String(localized: "Resident daemon is shutting down")
        case .migrating:
            return String(localized: "Estate migration in progress")
        case .recovering:
            return String(localized: "Estate recovery in progress")
        case .blocked(let reason):
            return "\(String(localized: "Resident daemon is blocked")): \(reason)"
        case .ready:
            switch setupModel.state {
            case .checking:
                return String(localized: "Checking estate readiness…")
            case .needsCreation:
                return String(localized: "Estate setup required")
            case .chooseExisting:
                return String(localized: "Choose an existing estate")
            case .missingKey:
                return String(localized: "Estate key recovery required")
            case .corrupt:
                return String(localized: "Estate recovery required")
            case .incompatible:
                return String(localized: "Estate version is incompatible")
            case .migrationRequired, .migrating:
                return String(localized: "Estate migration required")
            case .cancelled:
                return String(localized: "Estate setup paused")
            case .blocked:
                return String(localized: "Estate setup blocked")
            case .ready:
                return String(localized: "Connected")
            }
        case .incompatible:
            return String(localized: "Daemon contract incompatible")
        case .authenticationFailed:
            return String(localized: "Daemon authentication failed")
        case .handshakeFailed:
            return String(localized: "Daemon identity check failed")
        case .updateDaemonRequired:
            return String(localized: "Daemon update required")
        case .updateAppRequired:
            return String(localized: "Application update required")
        }
    }

    // The shared call surface, not the concrete bridge: this model makes tool
    // calls and never needs storage.
    private var bridge: (any MootEstateCalling)?
    private let connector: any CommunityDaemonConnecting
    private let liveCaptureService: DaemonCommunityCaptureService?
    private let featureCallerBox: CommunityFeatureCallerBox
    private var connectionAttempt = UUID()

    public init(
        connector: (any CommunityDaemonConnecting)? = nil,
        setupService: (any CommunityEstateLifecycleServicing)? = nil,
        captureService: (any CommunityCaptureServicing)? = nil,
        reviewPort: (any ReviewCenterPort)? = nil,
        obsidianPort: (any ObsidianSyncPort)? = nil,
        transferPort: (any TransferPort)? = nil,
        lanPort: (any LANControlPort)? = nil
    ) {
        self.connector = connector ?? CommunityDaemonConnections.live()
        let liveFeatureCallerBox = CommunityFeatureCallerBox()
        featureCallerBox = liveFeatureCallerBox
        setupModel = CommunitySetupModel(
            service: setupService ?? DaemonCommunityEstateLifecycleService(
                callerBox: liveFeatureCallerBox
            )
        )
        if let captureService {
            liveCaptureService = nil
            captureModel = CommunityCaptureModel(service: captureService)
        } else {
            let live = DaemonCommunityCaptureService()
            liveCaptureService = live
            captureModel = CommunityCaptureModel(service: live)
        }
        let workspace = CommunityOperationsWorkspaceModel(
            reviewPort: reviewPort ?? DaemonReviewCenterPort(callerBox: liveFeatureCallerBox),
            obsidianPort: obsidianPort ?? DaemonObsidianSyncPort(callerBox: liveFeatureCallerBox),
            transferPort: transferPort ?? DaemonTransferPort(callerBox: liveFeatureCallerBox),
            lanPort: lanPort ?? DaemonLANControlPort(callerBox: liveFeatureCallerBox)
        )
        operationsWorkspaceModel = workspace
        reviewCenterModel = workspace.reviewModel
        obsidianSyncModel = workspace.obsidianModel
        transferModel = workspace.transferModel
        lanControlModel = workspace.lanModel
    }

    public func start() async {
        let attempt = UUID()
        connectionAttempt = attempt
        connectionState = .starting
        bridge = nil
        estateIdentity = nil
        await liveCaptureService?.attach(nil)
        await featureCallerBox.attach(nil)

        let connection = await connector.connect()
        guard connectionAttempt == attempt else { return }
        connectionState = connection.state
        guard case .ready(let identity) = connection.state,
              let caller = connection.caller else {
            return
        }
        bridge = caller
        estateIdentity = identity
        await liveCaptureService?.attach(caller)
        await featureCallerBox.attach(caller)
        await setupModel.refresh()
        guard setupReceiptMatches(identity) else {
            if case .ready = setupModel.state {
                connectionState = .blocked(reason: "estate-identity-mismatch")
                bridge = nil
                estateIdentity = nil
                await liveCaptureService?.attach(nil)
                await featureCallerBox.attach(nil)
            }
            return
        }
        await captureModel.loadChoices()
        let reviewKindToRestore = reviewCenterModel.activeSession?.kind
        await reviewCenterModel.loadDashboard()
        if let reviewKindToRestore {
            await reviewCenterModel.loadSession(kind: reviewKindToRestore)
        }
        await obsidianSyncModel.loadStatus()
        await obsidianSyncModel.loadAuthorizationState()
        await transferModel.refreshImportJobStatus()
        await transferModel.refreshExportJobStatus()
        await lanControlModel.loadServingStatus()
        await lanControlModel.loadServingPolicy()
    }

    /// Keep the displayed estate bound to the currently authenticated daemon.
    /// The scene owns this task, so closing it cancels the loop. A failed ping
    /// discards the caller before reconnecting; there is no embedded fallback.
    public func maintainConnection() async {
        await start()
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(5))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }

            if let bridge, case .ready = connectionState {
                let ping = await bridge.call(method: "ping", params: nil)
                if ping.isError { await start() }
            } else {
                await start()
            }
        }
    }

    public func recall() async {
        guard let bridge, isEstateReady else { return }
        let result = await bridge.callToolFull("moot_memory_search", arguments: [
            "query": .string(recallQuery),
            "limit": .integer(20),
        ])
        recallResult = result.text
    }

    /// Re-run the authenticated connection ceremony after setup reports a
    /// ready receipt. The daemon must republish and prove the same estate
    /// identity before the main content surface opens.
    public func setupBecameReady() async {
        guard case .ready = setupModel.state else { return }
        await start()
    }

    private func setupReceiptMatches(_ identity: EstateIdentity) -> Bool {
        guard case .ready(let receipt) = setupModel.state,
              case .daemon(let estateID, _) = identity else { return false }
        return receipt.estate.id == estateID
    }

}
