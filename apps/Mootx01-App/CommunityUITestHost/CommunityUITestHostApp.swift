import MootCommunityUI
import MootCommunityUITestSupport
import SwiftUI

@main
struct CommunityUITestHostApp: App {
    @State private var model = CommunityUITestModelFactory.makeReadyModel()

    var body: some Scene {
        WindowGroup {
            CommunityContentView(model: model)
                .frame(minWidth: 900, minHeight: 680)
                .task { await model.start() }
        }
    }
}
