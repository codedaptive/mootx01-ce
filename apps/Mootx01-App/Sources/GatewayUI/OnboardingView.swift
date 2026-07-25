import SwiftUI

// MARK: - OnboardingView (FAB5-FR Part 1)
//
// Shown on first launch only; never again once hasCompletedOnboarding is true.
// Three-step guided flow: Welcome → one guided capture → one guided recall → done.
// Skippable at any step. ≤3 taps to complete (Start → Capture → Done).

struct OnboardingView: View {
    @Bindable var model: AppModel
    @State private var step = 0

    var body: some View {
        NavigationStack {
            Group {
                switch step {
                case 0: welcomeStep
                case 1: captureStep
                default: recallStep
                }
            }
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Skip")) {
                        model.hasCompletedOnboarding = true
                    }
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Step 0 — Welcome

    private var welcomeStep: some View {
        VStack(spacing: 32) {
            Spacer()
            Image(systemName: "brain.head.profile")
                .font(.system(size: 72))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(spacing: 12) {
                Text(String(localized: "Your memory, here."))
                    .font(.largeTitle.bold())
                    .multilineTextAlignment(.center)
                Text(String(localized: "Capture anything. Recall it instantly. In under a minute, we'll show you how."))
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            Spacer()
            // FAB5-L1 D1: cap CTA to modalCTAMaxWidth and center it so the button
            // doesn't span ~960pt on iPad Pro landscape. On iPhone the button fills
            // the padded width unchanged (iPhone width < modalCTAMaxWidth).
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                Button {
                    step = 1
                } label: {
                    Text(String(localized: "Get Started"))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: UIAdaptivity.modalCTAMaxWidth)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 48)
        }
    }

    // MARK: Step 1 — Guided capture

    private var captureStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                stepHeader(
                    icon: "tray.and.arrow.down",
                    title: String(localized: "Save a memory"),
                    subtitle: String(localized: "Type anything — a note, an idea, a fact. Tap Capture.")
                )

                GroupBox(String(localized: "Memory content")) {
                    TextEditor(text: $model.captureContent)
                        .font(.body)
                        .frame(height: 120)
                        .scrollContentBackground(.hidden)
                        .padding(4)
                }

                HStack {
                    Spacer()
                    Button {
                        Task {
                            await model.doCapture()
                            step = 2
                        }
                    } label: {
                        Label(
                            model.bridge == nil
                                ? String(localized: "Connecting…")
                                : String(localized: "Capture"),
                            systemImage: "tray.and.arrow.down"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(model.bridge == nil)
                }
            }
            .padding(24)
        }
    }

    // MARK: Step 2 — Guided recall

    private var recallStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                stepHeader(
                    icon: "tray.and.arrow.up",
                    title: String(localized: "Recall it back"),
                    subtitle: String(localized: "Your memory was saved. Tap Recall to read it back.")
                )

                if let call = model.lastCaptureCall, !call.isError {
                    Label {
                        Text(String(localized: "Memory saved successfully."))
                            .font(.callout)
                    } icon: {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }

                Button {
                    Task {
                        model.recallQuery = "MOOTx01"
                        await model.doRecall()
                    }
                } label: {
                    Label(String(localized: "Recall"), systemImage: "magnifyingglass")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(model.bridge == nil)

                if let call = model.lastRecallCall {
                    GroupBox(String(localized: "Result")) {
                        Text(call.text.isEmpty ? String(localized: "(no text content)") : call.text)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(6)
                    }
                }

                HStack {
                    Spacer()
                    Button {
                        model.hasCompletedOnboarding = true
                    } label: {
                        Text(String(localized: "Done"))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    Spacer()
                }
                .padding(.top, 8)
            }
            .padding(24)
        }
    }

    // MARK: Shared header component

    private func stepHeader(icon: String, title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon)
                .font(.title)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text(title)
                .font(.title2.bold())
            Text(subtitle)
                .font(.body)
                .foregroundStyle(.secondary)
        }
    }
}
