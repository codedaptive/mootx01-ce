import SwiftUI

/// A deliberately inert application shell for the application-hosted U7 test bundle.
///
/// The host supplies only Apple code-signing identity and entitlements. All proof
/// behavior remains compiled into the hosted test target, so the app exposes no
/// command, URL, menu customization, or product runtime mode.
@main
struct U7EntitledTestHostApp: App {
  var body: some Scene {
    WindowGroup {
      EmptyView()
    }
  }
}
