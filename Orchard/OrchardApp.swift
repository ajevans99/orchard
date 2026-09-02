import AppKit
import SwiftUI

@main
struct OrchardApp: App {
    @NSApplicationDelegateAdaptor(OrchardAppDelegate.self) private var appDelegate
    @StateObject private var controller: OrchardController

    init() {
        OrchardTelemetry.configure()
        _controller = StateObject(wrappedValue: OrchardController())
        OrchardTelemetry.track(
            .appLaunched(accessibilityTrusted: AXIsProcessTrusted())
        )
    }

    var body: some Scene {
        MenuBarExtra {
            ContentView(controller: controller)
        } label: {
            Image(systemName: "square.dashed.inset.filled")
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
private final class OrchardAppDelegate: NSObject, NSApplicationDelegate {
    private var testWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard ProcessInfo.processInfo.arguments.contains("--ui-testing") else { return }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 600),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Orchard UI Tests"
        window.contentView = NSHostingView(rootView: ContentView(controller: OrchardController()))
        window.center()
        window.makeKeyAndOrderFront(nil)
        testWindow = window
    }
}
