// ClientRowView.swift
//
// A single row in the client list: checkbox, name, and status badges
// (detected / already wired). Tapping the row toggles the checkbox.

import SwiftUI

struct ClientRowView: View {
    let item: ClientItem
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 12) {
                Image(systemName: item.isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(item.isSelected ? Color.accentColor : .secondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.client.displayName)
                        .font(.body)
                        .foregroundStyle(.primary)

                    HStack(spacing: 6) {
                        if item.isDetected {
                            StatusBadge(text: "Installed", color: .green)
                        } else {
                            StatusBadge(text: "Not found", color: .secondary)
                        }

                        if item.isAlreadyWired {
                            StatusBadge(text: "Already connected", color: .blue)
                        }
                    }
                }

                Spacer()
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(item.isSelected ? Color.accentColor.opacity(0.06) : .clear)
        )
        .opacity(item.isDetected ? 1.0 : 0.5)
    }
}

/// A small pill-shaped status indicator.
private struct StatusBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(color.opacity(0.12))
            )
    }
}
