// Mootx01SetupApp.swift
//
// Entry point for the MOOTx01 setup assistant. Single-window SwiftUI app
// launched by the macOS .pkg postinstall script to wire MCP clients.
// Also usable standalone: `swift run Mootx01Setup`.

import SwiftUI

@main
struct Mootx01SetupApp: App {
    var body: some Scene {
        WindowGroup {
            SetupView()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: 520, height: 560)
    }
}
