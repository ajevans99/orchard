import SwiftUI

@main
struct OrchardApp: App {
    @StateObject private var controller = OrchardController()

    var body: some Scene {
        MenuBarExtra {
            ContentView(controller: controller)
        } label: {
            Image(systemName: "square.dashed.inset.filled")
        }
        .menuBarExtraStyle(.window)
    }
}
