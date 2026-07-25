import SwiftUI
import MootGateway

// MARK: - ReviewCenterView  (FAB5-G2 — the Review tab's shell)
//
// The Standard-profile Review tab: a segmented picker across the shipped
// reviews, each rendering a FAB5-G1 `ReviewReport` below it (Kong ruling A).
// Peer-level surfaces, not a drill-down list — so there is a picker rather than
// a master/detail navigation stack. The `NavigationStack` here exists only to
// carry the title and the Refresh control, which is how `PacketListView` (the
// most recent view cluster in this app) gets both.
//
// The loading state machine, the clock read, and the report cache live in
// `ReviewCenterModel` below rather than in the `View` struct, so all three are
// testable without rendering anything.

public struct ReviewCenterView: View {
    @State private var center: ReviewCenterModel
    @State private var selection: ReviewKind

    /// - Parameter model: the app model, read for its live bridge. The Review
    ///   Center never mutates it.
    public init(model: AppModel) {
        let center = ReviewCenterModel(appModel: model)
        _center = State(initialValue: center)
        _selection = State(initialValue: center.kinds[0])
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                picker
                Divider()
                content
            }
            .navigationTitle(String(localized: "Review"))
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await center.reload(selection) }
                    } label: {
                        Label(
                            String(localized: "Refresh"),
                            systemImage: "arrow.clockwise")
                    }
                    .disabled(center.state(for: selection) == .loading)
                }
            }
        }
        // Build on first selection of a review, not eagerly for all of them: a
        // report is several tool calls against a live estate, and the user is
        // looking at exactly one.
        .task(id: selection) { await center.loadIfNeeded(selection) }
    }

    // MARK: Picker

    private var picker: some View {
        Picker(String(localized: "Review"), selection: $selection) {
            ForEach(center.kinds, id: \.self) { kind in
                Text(ReviewDisplayStrings.name(for: kind)).tag(kind)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal)
        .padding(.vertical, 8)
        .frame(maxWidth: UIAdaptivity.readableContentMaxWidth)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch center.state(for: selection) {
        case .idle, .loading:
            centered {
                ProgressView(String(localized: "Building review"))
            }
        case .disconnected:
            centered {
                VStack(spacing: 12) {
                    Image(systemName: "bolt.horizontal.circle")
                        .font(.system(size: 40))
                        .foregroundStyle(.orange)
                    Text(String(localized: "Not attached to an estate"))
                        .font(.headline)
                    Text(String(localized: "Reviews read your memories through the running estate. Once it attaches, this fills in."))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
                .frame(maxWidth: UIAdaptivity.readableContentMaxWidth)
            }
        case .loaded(let report):
            reportView(for: report)
        }
    }

    /// The per-review view. Each kind has a named view so review-specific chrome
    /// has a home; Weekly is the one that adds suggestion actions.
    @ViewBuilder
    private func reportView(for report: ReviewReport) -> some View {
        switch report.kind {
        case .dashboard: DashboardView(report: report)
        case .morning: MorningReviewView(report: report)
        case .endOfDay, .weekly:
            // Not reachable while `ReviewCenterModel.shippedKinds` holds only the
            // two reviews above; the switch is exhaustive because `ReviewKind`
            // is, and rendering the shared view is the correct behaviour for any
            // report that does reach here.
            ReviewReportView(report: report)
        }
    }

    private func centered<Content: View>(
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - ReviewCenterModel

/// Owns the four reviews' load states, the report cache, and the clock read.
///
/// Split out of the `View` so the state machine can be driven directly by a
/// test: construct it with a stub reader and a fixed clock, call
/// `loadIfNeeded(_:)`, and assert on `state(for:)`.
@MainActor
@Observable
final class ReviewCenterModel {

    /// Where one review's report stands.
    ///
    /// There is deliberately NO failure case. A FAB5-G1 builder never throws and
    /// always returns a report: a refused or timed-out surface becomes a section
    /// notice inside the report (`ReviewBuilder.swift`, invariant 2), so
    /// "the estate said no" is rendered as an explained section, not as a failed
    /// screen. The only state the view layer can be in that is not a report is
    /// having no estate to ask — `disconnected`.
    enum LoadState: Equatable {
        case idle
        case loading
        /// No bridge is attached yet, so no builder can be called at all.
        case disconnected
        case loaded(ReviewReport)
    }

    /// The reviews this build ships, in picker order.
    static let shippedKinds: [ReviewKind] = [.dashboard, .morning]

    let kinds: [ReviewKind]

    private var states: [ReviewKind: LoadState]
    private let configuration: ReviewConfiguration
    private let schedule: ReviewSchedule
    /// The live read seam, or nil when nothing is attached. Resolved per build
    /// rather than once at init, because the bridge attaches asynchronously
    /// after launch (`AppModel.start()`).
    private let makeReader: () -> (any ReviewSurfaceReading)?
    /// Injected so a test gets a deterministic `now`; the builders take `now` as
    /// a parameter and never read the clock themselves.
    private let clock: () -> Date

    /// Designated initializer — the seam tests use.
    init(
        kinds: [ReviewKind] = ReviewCenterModel.shippedKinds,
        configuration: ReviewConfiguration = ReviewConfiguration(),
        schedule: ReviewSchedule = ReviewSchedule(),
        clock: @escaping () -> Date = { Date() },
        makeReader: @escaping () -> (any ReviewSurfaceReading)?
    ) {
        self.kinds = kinds
        self.configuration = configuration
        self.schedule = schedule
        self.clock = clock
        self.makeReader = makeReader
        self.states = kinds.reduce(into: [:]) { states, kind in
            states[kind] = .idle
        }
    }

    /// Production initializer: reads the app's live bridge each time a build
    /// starts.
    convenience init(appModel: AppModel) {
        self.init(makeReader: { [weak appModel] in
            guard let bridge = appModel?.bridge else { return nil }
            return MootToolCallingReviewReader(caller: bridge)
        })
    }

    func state(for kind: ReviewKind) -> LoadState {
        states[kind] ?? .idle
    }

    /// Build `kind`'s report unless it is already built or building. Switching
    /// back to an already-built review shows the cached report — a review is a
    /// snapshot, and rebuilding it on every segment tap would re-run several
    /// lens calls for no new information.
    func loadIfNeeded(_ kind: ReviewKind) async {
        switch state(for: kind) {
        case .loaded, .loading:
            return
        case .idle, .disconnected:
            await build(kind)
        }
    }

    /// Rebuild `kind` from the estate, discarding the cached report. The
    /// Refresh control's only job.
    func reload(_ kind: ReviewKind) async {
        guard state(for: kind) != .loading else { return }
        await build(kind)
    }

    private func build(_ kind: ReviewKind) async {
        guard let reader = makeReader() else {
            states[kind] = .disconnected
            return
        }
        states[kind] = .loading
        let builder = ReviewBuilderFactory.builder(
            for: kind, configuration: configuration, schedule: schedule)
        // The one clock read per build. Truncated to a whole second because the
        // G1 wire coders carry no fractional part, so a sub-second `generatedAt`
        // would not survive an encode/decode round-trip identically
        // (ReviewModels.swift, "RESOLUTION IS WHOLE SECONDS").
        let now = Date(timeIntervalSince1970: clock().timeIntervalSince1970.rounded(.down))
        let report = await builder.build(now: now, reader: reader)
        states[kind] = .loaded(report)
    }
}
