import SwiftUI

@main
struct SyncTwinApp: App {
    @StateObject private var controller = SyncTwinController()

    var body: some Scene {
        WindowGroup {
            ContentView(controller: controller)
        }
        .windowResizability(.contentSize)
    }
}
