import FoundationModels
import MootFoundationModelsKit
import MootGateway
import MootIntentKit
import SwiftUI

// MARK: - Worker launcher model
//
// The six Apple Intelligence workers, their availability, and the text their
// results render to. Kept as value types beside the view so the launcher's
// behaviour is assertable without rendering a view — the availability rules and
// the result text are logic, and logic that only exists inside a `body` cannot
// be tested.

/// Whether the on-device model can run. Injected rather than read inside the
/// launcher logic so both states are reachable in a test on any machine.
public enum ModelAvailability: String, Sendable, Equatable, CaseIterable {
    case available
    case unavailable

    /// Reads the system model once, at the call site that is about to launch.
    static var current: ModelAvailability {
        SystemLanguageModel.default.availability == .available ? .available : .unavailable
    }
}

/// The six workers the Intelligence surface launches.
public enum WorkerLauncherKind: String, Sendable, Equatable, CaseIterable, Identifiable {
    case summarize
    case extractFacts
    case classify
    case reviewPrep
    case compare
    case handoff

    public var id: String { rawValue }

    /// Row label.
    var title: String {
        switch self {
        case .summarize:
            return String(localized: "intelligence.worker.summarize.title", defaultValue: "Summarize recent work")
        case .extractFacts:
            return String(localized: "intelligence.worker.extractFacts.title", defaultValue: "Extract facts")
        case .classify:
            return String(localized: "intelligence.worker.classify.title", defaultValue: "Classify this text")
        case .reviewPrep:
            return String(localized: "intelligence.worker.reviewPrep.title", defaultValue: "Morning brief")
        case .compare:
            return String(localized: "intelligence.worker.compare.title", defaultValue: "Compare two bodies")
        case .handoff:
            return String(localized: "intelligence.worker.handoff.title", defaultValue: "Draft a handoff")
        }
    }

    /// SF Symbol for the row. Paired with a text label, never the only signal.
    var symbol: String {
        switch self {
        case .summarize: return "text.alignleft"
        case .extractFacts: return "point.3.connected.trianglepath.dotted"
        case .classify: return "tag"
        case .reviewPrep: return "sun.horizon"
        case .compare: return "arrow.left.arrow.right"
        case .handoff: return "paperplane"
        }
    }

    /// What the editor box above must contain for this worker to run.
    /// `nil` for the workers that need nothing.
    var inputRequirement: String? {
        switch self {
        case .summarize, .extractFacts, .reviewPrep:
            return nil
        case .classify:
            return String(localized: "intelligence.worker.classify.needs", defaultValue: "Type the text to classify above.")
        case .compare:
            return String(
                localized: "intelligence.worker.compare.needs",
                defaultValue: "Paste both bodies above, separated by a line containing only ---"
            )
        case .handoff:
            return String(localized: "intelligence.worker.handoff.needs", defaultValue: "Type the objective above.")
        }
    }
}

/// Whether a launcher row can run, and on which path.
public enum WorkerLauncherState: String, Sendable, Equatable, CaseIterable {
    /// Apple Intelligence is available and the worker has what it needs.
    case ready
    /// The worker has what it needs, but Apple Intelligence is off — running it
    /// produces the deterministic fallback result.
    case fallbackOnly
    /// The editor box does not yet hold what this worker needs. Not runnable on
    /// either path, which is why this outranks `fallbackOnly`.
    case needsInput

    /// Row caption. Text, not colour: state is never communicated by colour alone.
    var label: String {
        switch self {
        case .ready:
            return String(localized: "intelligence.state.ready", defaultValue: "Ready")
        case .fallbackOnly:
            return String(localized: "intelligence.state.fallbackOnly", defaultValue: "Without Apple Intelligence")
        case .needsInput:
            return String(localized: "intelligence.state.needsInput", defaultValue: "Needs input")
        }
    }

    /// `needsInput` rows cannot run at all; the other two can.
    var isRunnable: Bool { self != .needsInput }
}

/// One launcher row: a worker, its state, and the caption explaining the state.
public struct WorkerLauncherEntry: Sendable, Equatable, Identifiable {
    public let kind: WorkerLauncherKind
    public let state: WorkerLauncherState

    public var id: String { kind.rawValue }

    /// Caption under the row title. For a blocked row it is the specific thing
    /// the editor box is missing, which is more useful than "Needs input".
    public var caption: String {
        state == .needsInput ? (kind.inputRequirement ?? state.label) : state.label
    }

    /// All six rows, in declaration order, resolved against the current model
    /// availability and the current editor text.
    ///
    /// `needsInput` wins over `fallbackOnly` on purpose: a missing objective or a
    /// missing second body blocks the deterministic path too, so offering the
    /// fallback would be offering a run that cannot produce anything.
    public static func entries(
        modelAvailability: ModelAvailability,
        editorText: String
    ) -> [WorkerLauncherEntry] {
        WorkerLauncherKind.allCases.map { kind in
            let satisfied: Bool
            switch kind {
            case .summarize, .extractFacts, .reviewPrep:
                satisfied = true
            case .classify, .handoff:
                satisfied = !editorText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .compare:
                satisfied = WorkerLauncherEntry.compareBodies(from: editorText) != nil
            }
            let state: WorkerLauncherState
            if !satisfied {
                state = .needsInput
            } else {
                state = modelAvailability == .available ? .ready : .fallbackOnly
            }
            return WorkerLauncherEntry(kind: kind, state: state)
        }
    }

    /// Split the editor text into two research bodies on a line containing only
    /// `---`. Returns `nil` unless there is exactly one such separator with
    /// non-empty text on both sides — a comparison needs two bodies, and
    /// guessing at a third boundary would silently drop material.
    static func compareBodies(from text: String) -> (left: ResearchBody, right: ResearchBody)? {
        let halves = text.components(separatedBy: "\n").split(
            whereSeparator: { $0.trimmingCharacters(in: .whitespaces) == "---" }
        )
        guard halves.count == 2 else { return nil }
        let left = halves[0].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let right = halves[1].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !left.isEmpty, !right.isEmpty else { return nil }
        return (
            ResearchBody(
                label: String(localized: "intelligence.compare.firstLabel", defaultValue: "First body"),
                text: left
            ),
            ResearchBody(
                label: String(localized: "intelligence.compare.secondLabel", defaultValue: "Second body"),
                text: right
            )
        )
    }
}

// MARK: - Result rendering
//
// Worker output as the text the response pane shows. Section headings are
// localized; everything between them is estate content or worker output, carried
// as produced.

enum WorkerResultText {

    static func summary(_ suggestion: SummarySuggestion) -> String {
        suggestion.summary
    }

    /// Every triple is marked proposed, because every triple this app extracts is
    /// a candidate for review and is never filed automatically.
    static func triples(_ result: ExtractFactsResult) -> String {
        guard !result.triples.isEmpty else {
            return String(
                localized: "intelligence.result.noTriples",
                defaultValue: "No candidate facts were proposed."
            )
        }
        let marker = String(localized: "intelligence.result.proposedMarker", defaultValue: "proposed")
        return result.triples
            .map { "\($0.subject) — \($0.predicate) → \($0.object)  [\(marker)]" }
            .joined(separator: "\n")
    }

    static func classification(_ suggestion: ClassificationSuggestion) -> String {
        guard !suggestion.suggestedRoom.isEmpty || !suggestion.suggestedTags.isEmpty else {
            return String(
                localized: "intelligence.result.noClassification",
                defaultValue: "No room or tags were suggested."
            )
        }
        let roomHeading = String(localized: "intelligence.result.room", defaultValue: "Room")
        let tagsHeading = String(localized: "intelligence.result.tags", defaultValue: "Tags")
        return "\(roomHeading): \(suggestion.suggestedRoom)\n\(tagsHeading): \(suggestion.suggestedTags.joined(separator: ", "))"
    }

    /// The brief, then the surfaces it came from. The surface list is the report's
    /// own, so a reader can always see which tools the prose stands on.
    static func brief(_ brief: ReviewBrief) -> String {
        var text = brief.headline + "\n\n" + brief.narrative
        if !brief.citedSurfaces.isEmpty {
            let heading = String(localized: "intelligence.result.surfaces", defaultValue: "Read from")
            text += "\n\n\(heading): " + brief.citedSurfaces.map(\.rawValue).joined(separator: ", ")
        }
        return text
    }

    /// Disagreements are rendered before synthesis, with both positions in full.
    /// The function stays whole because it IS the section order: reading it top to
    /// bottom is how a reviewer checks that no category was dropped from the pane.
    ///
    /// The comparison layer refuses to dissolve a conflict, and this view refuses
    /// to bury one: a synthesis candidate is printed with the disputes it leaves
    /// open, and a dispute no candidate acknowledged is called out by name.
    static func comparison(_ result: CompareResult) -> String {
        var blocks: [String] = []

        if let notice = result.notice {
            blocks.append(notice)
        }

        if !result.agreements.isEmpty {
            let heading = String(localized: "intelligence.result.agreements", defaultValue: "Both agree")
            blocks.append(heading + ":\n" + result.agreements
                .map { "• \($0.topic): \($0.statement)" }
                .joined(separator: "\n"))
        }

        if !result.disagreements.isEmpty {
            let heading = String(localized: "intelligence.result.disagreements", defaultValue: "They disagree")
            blocks.append(heading + ":\n" + result.disagreements
                .map { "• \($0.topic)\n    \($0.leftLabel): \($0.leftPosition)\n    \($0.rightLabel): \($0.rightPosition)" }
                .joined(separator: "\n"))
        }

        if !result.synthesisCandidates.isEmpty {
            let heading = String(localized: "intelligence.result.synthesis", defaultValue: "Synthesis candidates")
            let openHeading = String(localized: "intelligence.result.leavesOpen", defaultValue: "leaves open")
            blocks.append(heading + ":\n" + result.synthesisCandidates
                .map { candidate in
                    let open = candidate.acknowledgedDisagreementIDs.isEmpty
                        ? ""
                        : "\n    (\(openHeading): \(candidate.acknowledgedDisagreementIDs.joined(separator: ", ")))"
                    return "• \(candidate.statement)\(open)"
                }
                .joined(separator: "\n"))
        }

        let unacknowledged = result.unacknowledgedDisagreements
        if !unacknowledged.isEmpty {
            let heading = String(
                localized: "intelligence.result.unaddressed",
                defaultValue: "No synthesis candidate addresses"
            )
            blocks.append(heading + ": " + unacknowledged.map(\.topic).joined(separator: ", "))
        }

        return blocks.joined(separator: "\n\n")
    }

    /// The assembled draft, which already contains its own citations.
    static func handoff(_ draft: HandoffDraft) -> String {
        draft.body
    }
}

// MARK: - IntelligenceView

public struct IntelligenceView: View {
    @State private var prompt = ""
    @State private var response = ""
    @State private var isResponding = false
    @State private var allowOneCapture = false
    @State private var session: LanguageModelSession?
    @State private var captureAuthorization = OneShotCaptureAuthorization()
    @State private var spotlightIndexer: MootSpotlightIndexer?
    /// Resolved when the view appears and after each run, so a user who enables
    /// Apple Intelligence in Settings sees the rows change state on return.
    @State private var modelAvailability = ModelAvailability.current

    public init() {}

    public var body: some View {
        // FAB5-L1 D2: two-frame centering caps the content at readableContentMaxWidth
        // on iPad regular-width layouts. On iPhone the VStack naturally fills its
        // narrower container (iPhone width < readableContentMaxWidth).
        VStack(alignment: .leading, spacing: 12) {
            ScrollView {
                Text(response.isEmpty ? String(localized: "Ask about your memories") : response)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.gatewayEditorField)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            TextEditor(text: $prompt)
                .font(.body)
                .frame(minHeight: 84, maxHeight: 140)
                .padding(6)
                .background(Color.gatewayEditorField)
                .clipShape(RoundedRectangle(cornerRadius: 6))

            HStack {
                Toggle(String(localized: "Allow saving to memory"), isOn: $allowOneCapture)
                    .toggleStyle(.switch)
                Spacer()
                Button {
                    Task { await respond() }
                } label: {
                    Label(
                        isResponding ? String(localized: "Thinking") : String(localized: "Ask"),
                        systemImage: "arrow.up.circle.fill"
                    )
                }
                .buttonStyle(.borderedProminent)
                .disabled(isResponding || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            workerLauncher
        }
        .frame(maxWidth: UIAdaptivity.readableContentMaxWidth)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding()
        .onAppear { modelAvailability = ModelAvailability.current }
    }

    // MARK: Launcher

    /// All six workers, each with its availability state. Adaptive columns so the
    /// grid is two-up on iPhone and wider on iPad without a size-class branch.
    private var workerLauncher: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "intelligence.workers.heading", defaultValue: "Workers"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 168), spacing: 8)],
                alignment: .leading,
                spacing: 8
            ) {
                ForEach(WorkerLauncherEntry.entries(
                    modelAvailability: modelAvailability, editorText: prompt)
                ) { entry in
                    workerRow(entry)
                }
            }
        }
    }

    private func workerRow(_ entry: WorkerLauncherEntry) -> some View {
        Button {
            Task { await run(entry.kind) }
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: entry.kind.symbol)
                    .font(.body)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.kind.title)
                        .font(.subheadline.weight(.semibold))
                    Text(entry.caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            // 44pt floor: every launcher row is a touch target.
            .frame(minHeight: 44)
            .padding(8)
            .background(Color.gatewayEditorField)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .disabled(isResponding || !entry.state.isRunnable)
        // The visual row is an icon plus two text lines; VoiceOver reads it as one
        // control whose label carries both the worker and why it can or cannot run.
        .accessibilityElement(children: .combine)
        // A localized format rather than string concatenation, so a translation
        // controls how the two parts are joined.
        .accessibilityLabel(String(
            localized: "intelligence.worker.accessibilityLabel",
            defaultValue: "\(entry.kind.title). \(entry.caption)"
        ))
    }

    // MARK: Running a worker

    /// Runs one worker through `runSafe`, so the UI receives a result on both the
    /// model path and the fallback path and never a thrown error. A failure to
    /// reach the estate bridge at all is shown as text, matching `respond()`.
    ///
    /// A `ready` row can still return a fallback result: on real estate content
    /// Apple's guardrail declines some material even with Apple Intelligence
    /// available. `runSafe` gives no reason back, so each worker's fallback text
    /// explains itself rather than the row's caption predicting the path.
    ///
    /// The `switch` stays in one function because every branch is the same three
    /// lines — build input, `runSafe`, render — and the six sitting together is
    /// what makes a missing or mis-wired worker obvious at a glance.
    @MainActor
    private func run(_ kind: WorkerLauncherKind) async {
        isResponding = true
        defer {
            isResponding = false
            modelAvailability = ModelAvailability.current
        }
        let content = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let caller = try await GatewayRuntime.shared.bridge()
            switch kind {
            case .summarize:
                let input = SummarizeInput(query: content.isEmpty ? "recent work" : content)
                response = WorkerResultText.summary(
                    await SummarizeWorker().runSafe(input: input, caller: caller))

            case .extractFacts:
                let input = ExtractFactsInput(query: content.isEmpty ? "facts people decisions" : content)
                response = WorkerResultText.triples(
                    await ExtractFactsWorker().runSafe(input: input, caller: caller))

            case .classify:
                response = WorkerResultText.classification(
                    await ClassifyWorker().runSafe(input: ClassifyInput(content: content), caller: caller))

            case .reviewPrep:
                response = WorkerResultText.brief(
                    await morningBrief(caller: caller))

            case .compare:
                guard let bodies = WorkerLauncherEntry.compareBodies(from: prompt) else { return }
                let input = CompareInput(left: bodies.left, right: bodies.right)
                response = WorkerResultText.comparison(
                    await CompareWorker().runSafe(input: input, caller: caller))

            case .handoff:
                let input = HandoffInput(objective: content)
                response = WorkerResultText.handoff(
                    await HandoffWorker().runSafe(input: input, caller: caller))
            }
        } catch {
            response = error.localizedDescription
        }
    }

    /// Builds this morning's review through the Review builders, then narrates it.
    ///
    /// The report is built first because ReviewPrepWorker reads a report, not the
    /// estate. A section whose surface is slow or refuses comes back empty with
    /// the substrate's own notice, and the brief describes it that way — on a
    /// large estate `moot_memory_search` can outrun the transport's default
    /// timeout, and a degraded section is the correct visible outcome.
    @MainActor
    private func morningBrief(caller: any MootToolCalling) async -> ReviewBrief {
        let builder = ReviewBuilderFactory.builder(
            for: .morning,
            configuration: ReviewConfiguration(),
            schedule: ReviewSchedule()
        )
        // A view may read the clock; the builder may not, which is why `now` is
        // passed in from here.
        let report = await builder.build(
            now: Date(), reader: MootToolCallingReviewReader(caller: caller))
        return await ReviewPrepWorker().runSafe(
            input: ReviewPrepInput(report: report), caller: caller)
    }

    @MainActor
    private func respond() async {
        let request = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty else { return }
        isResponding = true
        do {
            if allowOneCapture {
                await captureAuthorization.arm()
            } else {
                await captureAuthorization.disarm()
            }
            let activeSession: LanguageModelSession
            if let session {
                activeSession = session
            } else {
                let caller = try await GatewayRuntime.shared.bridge()
                let indexer = MootSpotlightIndexer(caller: caller)
                _ = try? await indexer.refreshEligible()
                spotlightIndexer = indexer
                #if arch(arm64)
                let spotlightTools: [any Tool] = [MootSpotlightSearch.makeTool(delegate: indexer)]
                #else
                let spotlightTools: [any Tool] = []
                #endif
                let created = MootMemoryAssistant.makeSystemSession(
                    caller: caller,
                    captureAuthorization: captureAuthorization,
                    additionalTools: spotlightTools
                )
                session = created
                activeSession = created
            }
            let result = try await activeSession.respond(to: request)
            response = result.content
            prompt = ""
        } catch {
            response = error.localizedDescription
        }
        // Approval is scoped to this response even when the model never uses
        // the capture tool. It must never remain armed for a later prompt.
        await captureAuthorization.disarm()
        allowOneCapture = false
        isResponding = false
    }
}
