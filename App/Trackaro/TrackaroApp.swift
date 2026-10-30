import SwiftUI

@main
struct TrackaroApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .frame(minWidth: 720, minHeight: 480)
                .task { model.start() }
        }
        .windowToolbarStyle(.unifiedCompact)
    }
}
