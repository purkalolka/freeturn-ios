import SwiftUI

@main
struct FreeTurnApp: App {
    init() { NotificationHandler.shared.setup() }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
