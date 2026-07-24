import FoundationModels
import MootFoundationModelsKit
import MootGateway
import SwiftUI

public struct IntelligenceView: View {
    @State private var prompt = ""
    @State private var response = ""
    @State private var isResponding = false
    @State private var allowOneCapture = false
    @State private var session: LanguageModelSession?
    @State private var captureAuthorization = OneShotCaptureAuthorization()
    @State private var spotlightIndexer: MootSpotlightIndexer?

    public init() {}

    public var body: some View {
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
        }
        .padding()
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
