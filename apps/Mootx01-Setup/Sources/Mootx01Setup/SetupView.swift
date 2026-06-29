// SetupView.swift
//
// The main view for the setup assistant. Shows detected MCP clients
// with checkboxes, a connect button, and transitions to a completion
// screen. Designed to feel native and minimal — one screen, one action.

import SwiftUI

struct SetupView: View {
    @State private var viewModel = SetupViewModel()

    var body: some View {
        VStack(spacing: 0) {
            // Header
            header
                .padding(.top, 32)
                .padding(.bottom, 20)
                .padding(.horizontal, 32)

            Divider()

            // Content area
            switch viewModel.phase {
            case .detecting:
                detectingView
            case .selecting:
                selectingView
            case .installing:
                installingView
            case .complete:
                completionView
            case .error(let message):
                errorView(message)
            }
        }
        .frame(minWidth: 520, maxWidth: 520, minHeight: 480)
        .background(.background)
        .onAppear {
            viewModel.detect()
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "memorychip")
                .font(.system(size: 40))
                .foregroundStyle(Color.accentColor)

            Text("MOOTx01 Setup")
                .font(.title.bold())

            Text("Connect your AI clients to MOOTx01")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Detecting

    private var detectingView: some View {
        VStack {
            Spacer()
            ProgressView("Scanning for AI clients…")
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Selecting

    private var selectingView: some View {
        VStack(spacing: 0) {
            // Client list
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(viewModel.clients) { item in
                        ClientRowView(item: item) {
                            viewModel.toggle(item.id)
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
            }

            Divider()

            // Footer with action buttons
            HStack {
                if viewModel.detectedCount > 0 {
                    Text("\(viewModel.detectedCount) client\(viewModel.detectedCount == 1 ? "" : "s") detected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("No AI clients detected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Skip") {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut(.cancelAction)

                Button("Connect") {
                    viewModel.install()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!viewModel.canInstall)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
    }

    // MARK: - Installing

    private var installingView: some View {
        VStack {
            Spacer()
            ProgressView("Connecting clients…")
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Complete

    private var completionView: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)

            Text("Setup Complete")
                .font(.title2.bold())

            if !viewModel.results.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(viewModel.results, id: \.self) { name in
                        Label(name, systemImage: "checkmark")
                            .font(.body)
                            .foregroundStyle(.primary)
                    }
                }
            }

            if !viewModel.skipped.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(viewModel.skipped, id: \.self) { msg in
                        Label(msg, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }

            Text("Restart your AI clients to start using MOOTx01.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.top, 8)

            Spacer()

            Divider()

            HStack {
                Spacer()
                Button("Done") {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
    }

    // MARK: - Error

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.red)

            Text("Something went wrong")
                .font(.title2.bold())

            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Spacer()

            Divider()

            HStack {
                Spacer()
                Button("Close") {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
    }
}
