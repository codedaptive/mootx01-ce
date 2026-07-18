// SASConfirmationView.swift
//
// FED-OD-3: Short Authentication String confirmation UI.
//
// Displays the derived SAS pattern (4 emoji+color pairs) and presents
// Confirm / Reject buttons. Both devices must show identical patterns for
// the pairing to be trustworthy. If the patterns differ, a MITM swapped
// an ephemeral key during the QR ceremony — the user taps Reject.
//
// Design ref: decision §3 "both screens render the same short-authentication-string
// pattern (color/emoji derived from the transcript); both users confirm."
//
// Localization: all user-visible strings use String(localized:) per project rule.

import SwiftUI
import MootGateway

// MARK: - SASConfirmationView

/// Displays a 4-item SAS pattern and solicits the user's confirmation.
///
/// Each item in the pattern is rendered as an emoji overlaid on a
/// colored background. Both devices derive the same pattern iff the
/// QR ceremony was not subject to a MITM attack.
///
/// The user verbally (or visually) confirms both screens show the same
/// four symbols, then taps Confirm. If anything differs, they tap Reject.
///
/// This view is intentionally non-interactive except for the two buttons —
/// the user does not need to type or enter anything, reducing confirmation
/// friction while preserving the security guarantee.
public struct SASConfirmationView: View {
    let sasPattern: [SASEntry]
    let onConfirm: () async -> Void
    let onReject: () async -> Void

    @State private var isProcessing = false

    public init(
        sasPattern: [SASEntry],
        onConfirm: @escaping () async -> Void,
        onReject: @escaping () async -> Void
    ) {
        self.sasPattern = sasPattern
        self.onConfirm = onConfirm
        self.onReject = onReject
    }

    public var body: some View {
        VStack(spacing: 28) {
            // Header
            VStack(spacing: 8) {
                Text(String(localized: "federation.sas.title",
                            defaultValue: "Compare Codes"))
                    .font(.title2.bold())

                Text(String(localized: "federation.sas.instruction",
                            defaultValue: "Both devices must show the same four symbols. If they match, tap Confirm."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            // SAS pattern grid
            SASPatternView(entries: sasPattern)

            // Action buttons
            VStack(spacing: 12) {
                Button {
                    guard !isProcessing else { return }
                    isProcessing = true
                    Task { await onConfirm() }
                } label: {
                    Label(
                        String(localized: "federation.sas.confirm",
                               defaultValue: "Codes Match — Confirm Pairing"),
                        systemImage: "checkmark.shield.fill"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityHint(
                    String(localized: "federation.sas.confirm.hint",
                           defaultValue: "Tap after confirming both devices show the same four symbols."))
                .disabled(isProcessing)

                Button(role: .destructive) {
                    guard !isProcessing else { return }
                    isProcessing = true
                    Task { await onReject() }
                } label: {
                    Label(
                        String(localized: "federation.sas.reject",
                               defaultValue: "Codes Don't Match — Cancel"),
                        systemImage: "xmark.shield.fill"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .accessibilityHint(
                    String(localized: "federation.sas.reject.hint",
                           defaultValue: "Tap if the symbols differ. The pairing will be cancelled."))
                .disabled(isProcessing)
            }
            .padding(.horizontal)

            if isProcessing {
                ProgressView()
                    .accessibilityLabel(
                        String(localized: "federation.sas.processing",
                               defaultValue: "Processing…"))
            }
        }
        .padding()
    }
}

// MARK: - SASPatternView

/// Renders the four SAS entries as a horizontal row of symbol tiles.
///
/// Each tile shows:
///   - A coloured background (from SASDeriver.colorPalette)
///   - The emoji character centred on the tile (from SASDeriver.emojiPalette)
///
/// The tile background colour is resolved from the palette name using SwiftUI's
/// named-colour mechanism. If a palette name does not match a named asset, the
/// tile uses a neutral fill — never a crash.
///
/// Accessibility: each tile has a combined label "emoji, color" so VoiceOver
/// users can compare without looking at the screen.
struct SASPatternView: View {
    let entries: [SASEntry]

    var body: some View {
        HStack(spacing: 12) {
            ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                SASSymbolTile(entry: entry)
            }
        }
        .accessibilityLabel(
            String(localized: "federation.sas.pattern.label",
                   defaultValue: "Security pattern: ") +
            entries.map { tileAccessibilityLabel(for: $0) }.joined(separator: ", ")
        )
        // Let VoiceOver read the combined label above rather than each tile individually
        .accessibilityElement(children: .ignore)
    }

    private func tileAccessibilityLabel(for entry: SASEntry) -> String {
        let emoji = SASDeriver.emojiPalette.indices.contains(entry.emojiIndex)
            ? SASDeriver.emojiPalette[entry.emojiIndex] : "?"
        let color = SASDeriver.colorPalette.indices.contains(entry.colorIndex)
            ? SASDeriver.colorPalette[entry.colorIndex] : "unknown"
        // e.g. "🌊 blue" — spoken by VoiceOver for comparison
        return "\(emoji) \(color)"
    }
}

// MARK: - SASSymbolTile

/// One cell in the 4-tile SAS display.
struct SASSymbolTile: View {
    let entry: SASEntry

    private var emoji: String {
        SASDeriver.emojiPalette.indices.contains(entry.emojiIndex)
            ? SASDeriver.emojiPalette[entry.emojiIndex] : "?"
    }

    private var tileColor: Color {
        // Map the palette name to a SwiftUI Color.
        // Defensive: if the index is out of range, use a neutral grey.
        guard SASDeriver.colorPalette.indices.contains(entry.colorIndex) else {
            return .gray.opacity(0.2)
        }
        switch SASDeriver.colorPalette[entry.colorIndex] {
        case "red":    return Color.red.opacity(0.25)
        case "orange": return Color.orange.opacity(0.25)
        case "yellow": return Color.yellow.opacity(0.25)
        case "green":  return Color.green.opacity(0.25)
        case "teal":   return Color.teal.opacity(0.25)
        case "blue":   return Color.blue.opacity(0.25)
        case "violet": return Color.purple.opacity(0.25)
        case "pink":   return Color.pink.opacity(0.25)
        default:       return Color.gray.opacity(0.2)
        }
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(tileColor)
            Text(emoji)
                .font(.system(size: 36))
        }
        .frame(width: 64, height: 64)
    }
}
