import Observation
import SwiftUI

// MARK: - CommunityOperationsWorkspaceView  (APP-08 — Operations Workspace)
//
// Complete, self-contained macOS SwiftUI workspace hosting the four shipped
// Community features:
//   • Review Center      (ReviewCenterView / ReviewCenterModel / ReviewCenterPort)
//   • Obsidian Sync      (ObsidianSyncView  / ObsidianSyncModel / ObsidianSyncPort)
//   • Transfer           (TransferView      / TransferModel      / TransferPort)
//   • LAN Control        (LANControlView    / LANControlModel    / LANControlPort)
//
// Navigation: stable sidebar/section navigation. Section identifiers are
// explicit string constants — never derived from locale-sorted strings —
// guaranteeing deterministic order across language settings.
//
// Injection discipline: all four ports are required at init time. No default
// arguments, no singleton construction, no production port instantiation
// inside this file. The app-level wiring (CommunityContentView integration)
// is an INTEGRATION-owned step (INTEGRATION-02/03). This view is the complete
// Fable-half deliverable and is fully exercisable via injection.
//
// State survival: feature models are owned by CommunityOperationsWorkspaceModel
// and constructed exactly once. Switching between workspace sections does NOT
// destroy or re-create models — in-progress review sessions and running transfer
// jobs survive section switches.
//
// Accessibility: each section entry carries an explicit accessibility label
// and system image. The workspace itself has a stable accessibility identifier.
// All display strings pass through String(localized:) — zero unlocalized text.
//
// Swift 6 / macOS-only: all mutable workspace state is @MainActor-isolated.
// No estate/DB imports; no MootGateway, PersistenceKit, LocusKit, or
// GeniusLocusKit references. No Pro/Fulcrum/iCloud/federation/ProductDock
// references.
//
// INTEGRATION NOTE: embedding this view inside a CommunityContentView
// destination or equivalent NavigationSplitView detail column is an
// integration-owned step (INTEGRATION-02/03). This view renders as a
// complete NavigationSplitView on its own — no outer navigation required.

// MARK: - WorkspaceSection

/// One navigation entry in the sidebar, with a stable ID that never changes
/// across locale or model re-instantiation.
///
/// IDs use a dotted-namespace convention: "workspace.<feature>".
/// They are literal string constants — NOT derived from display labels —
/// so locale or L10n changes cannot reorder or alias entries.
public struct WorkspaceSection: Identifiable, Sendable {
    /// Stable identifier; used as the sidebar selection value and as the
    /// accessibility identifier for the row.
    public let id: String
    /// Localization key resolved to display text by the view layer.
    public let label: String
    /// SF Symbols name for the sidebar icon.
    public let systemImage: String
}

// MARK: - CommunityOperationsWorkspaceModel

/// Observable model that owns all four feature models and drives the workspace
/// sidebar selection. Constructed once per workspace lifetime; feature models
/// are never re-created on section switches.
///
/// Thread safety: @MainActor — all state mutations are confined to the main actor,
/// matching the @Observable + SwiftUI requirement for mutation-on-main.
@MainActor
@Observable
public final class CommunityOperationsWorkspaceModel {

    // MARK: - Section catalog (stable order, explicit IDs)
    //
    // Declared as a constant array so order is fixed at source level.
    // Never derived from locale-sorted strings or dynamic data.
    // Order: Review → Obsidian → Transfer → LAN.

    /// All workspace sections in their declared stable order.
    public let sections: [WorkspaceSection] = [
        WorkspaceSection(
            id: "workspace.review",
            label: String(localized: "Review Center"),
            systemImage: "checklist"
        ),
        WorkspaceSection(
            id: "workspace.obsidian",
            label: String(localized: "Obsidian Sync"),
            systemImage: "arrow.triangle.2.circlepath"
        ),
        WorkspaceSection(
            id: "workspace.transfer",
            label: String(localized: "Transfer"),
            systemImage: "arrow.up.arrow.down.circle"
        ),
        WorkspaceSection(
            id: "workspace.lan",
            label: String(localized: "LAN Control"),
            systemImage: "network"
        ),
    ]

    // MARK: - Active section

    /// The currently selected section ID. Defaults to the first section (Review).
    /// Never set to a value not present in `sections` — callers enforce this via
    /// binding through List selection.
    public var activeSection: String = "workspace.review"

    // MARK: - Feature models (constructed once; survive section switches)
    //
    // Each model is final and held for the entire workspace lifetime.
    // Switching sections sets `activeSection` but does NOT replace these
    // references. State accumulated inside each model (e.g. an in-progress
    // review session, a running transfer job ID) therefore survives navigation.

    /// Review Center model — constructed once from the injected ReviewCenterPort.
    public let reviewModel: ReviewCenterModel

    /// Obsidian Sync model — constructed once from the injected ObsidianSyncPort.
    public let obsidianModel: ObsidianSyncModel

    /// Transfer model — constructed once from the injected TransferPort.
    public let transferModel: TransferModel

    /// LAN Control model — constructed once from the injected LANControlPort.
    public let lanModel: LANControlModel

    // MARK: - Accessibility

    /// Stable accessibility identifier for the workspace container.
    /// The view attaches this to its outermost container so accessibility
    /// trees and UI tests can locate the workspace without relying on a
    /// display-language-sensitive label.
    public let accessibilityIdentifier: String = "community.operations.workspace"

    // MARK: - Init
    //
    // All four ports are REQUIRED. No default arguments are provided — the
    // call site (app-level integration or test harness) is responsible for
    // supplying concrete conformers. This enforces injection discipline at
    // compile time; the workspace never constructs a port itself.

    /// - Parameters:
    ///   - reviewPort:   Injected ReviewCenterPort conformer (INTEGRATION-02 adapter in production).
    ///   - obsidianPort: Injected ObsidianSyncPort conformer  (INTEGRATION-02 adapter in production).
    ///   - transferPort: Injected TransferPort conformer       (INTEGRATION-02 adapter in production).
    ///   - lanPort:      Injected LANControlPort conformer     (INTEGRATION-02 adapter in production).
    public init(
        reviewPort: any ReviewCenterPort,
        obsidianPort: any ObsidianSyncPort,
        transferPort: any TransferPort,
        lanPort: any LANControlPort
    ) {
        // Each sub-model is constructed once here; never replaced later.
        reviewModel   = ReviewCenterModel(port: reviewPort)
        obsidianModel = ObsidianSyncModel(port: obsidianPort)
        transferModel = TransferModel(port: transferPort)
        lanModel      = LANControlModel(port: lanPort)
    }
}

// MARK: - CommunityOperationsWorkspaceView

/// The top-level macOS workspace view. Hosts the four Community feature views
/// behind a stable sidebar. The sidebar selection drives `activeSection` in
/// the workspace model; the detail column renders the corresponding feature view.
///
/// INTEGRATION NOTE: app-level navigation embedding (placing this view inside a
/// CommunityContentView destination or equivalent) is an INTEGRATION-owned step
/// (INTEGRATION-02/03). This view is the complete Fable-half deliverable and is
/// fully exercisable via injection.
#if os(macOS)
@MainActor
public struct CommunityOperationsWorkspaceView: View {

    /// The workspace model — injected by the call site (no singletons, no
    /// production construction inside this view).
    @Bindable private var workspaceModel: CommunityOperationsWorkspaceModel

    /// - Parameter workspaceModel: the injected workspace model. Never constructed here.
    public init(workspaceModel: CommunityOperationsWorkspaceModel) {
        self.workspaceModel = workspaceModel
    }

    public var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detailView
        }
        .accessibilityIdentifier(workspaceModel.accessibilityIdentifier)
    }

    // MARK: - Sidebar

    /// Sidebar list of workspace sections in their declared stable order.
    /// Selection is a String (the section's stable ID), not a locale-derived value.
    @ViewBuilder
    private var sidebar: some View {
        List(
            workspaceModel.sections,
            selection: Binding(
                get: { workspaceModel.activeSection },
                set: { if let newValue = $0 { workspaceModel.activeSection = newValue } }
            )
        ) { section in
            Label(
                String(localized: String.LocalizationValue(section.label)),
                systemImage: section.systemImage
            )
            .tag(section.id)
            // Each row carries an explicit accessibility label (the localized
            // display name) and an identifier (the stable section ID) so
            // accessibility tools and UI tests can locate rows without relying
            // on display text in any language.
            .accessibilityLabel(String(localized: String.LocalizationValue(section.label)))
            .accessibilityIdentifier(section.id)
        }
        .navigationTitle(String(localized: "Operations"))
    }

    // MARK: - Detail

    /// Renders the feature view for the currently selected section.
    /// The feature model is passed from the workspace model — never re-constructed here —
    /// so state accumulated in the model (in-progress session, running job) survives
    /// switching back and forth between sections.
    @ViewBuilder
    private var detailView: some View {
        switch workspaceModel.activeSection {
        case "workspace.review":
            // ReviewCenterView receives the long-lived reviewModel; navigation
            // into session views within the review feature is handled by the
            // feature view's own NavigationStack.
            ReviewCenterView(model: workspaceModel.reviewModel)

        case "workspace.obsidian":
            // ObsidianSyncView is macOS-only (guarded by #if os(macOS) in its
            // own file); this view is also macOS-only so the guard is satisfied.
            ObsidianSyncView(model: workspaceModel.obsidianModel)

        case "workspace.transfer":
            // TransferView is macOS-only; same guard logic applies.
            TransferView(model: workspaceModel.transferModel)

        case "workspace.lan":
            // LANControlView is macOS-only; same guard logic applies.
            LANControlView(model: workspaceModel.lanModel)

        default:
            // Fallback for any unexpected selection value — should never occur
            // because `activeSection` is always set from a section in the catalog.
            ContentUnavailableView(
                String(localized: "Select a section"),
                systemImage: "sidebar.left"
            )
        }
    }
}
#endif
