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
            Image("MenuBarIcon")
                .renderingMode(.template)
                .accessibilityLabel("Orchard")
        }
        .menuBarExtraStyle(.window)
    }
}

nonisolated enum OrchardInstallation {
    static func requiresMoveToApplications(
        bundleURL: URL = Bundle.main.bundleURL,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Bool {
        let bundlePath = bundleURL.resolvingSymlinksInPath().standardizedFileURL.path
        let applicationDirectories = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            homeDirectory.appendingPathComponent("Applications", isDirectory: true),
        ]

        return !applicationDirectories.contains { directory in
            let directoryPath = directory.resolvingSymlinksInPath().standardizedFileURL.path
            return bundlePath.hasPrefix(directoryPath + "/")
        }
    }
}

@MainActor
private final class OrchardAppDelegate: NSObject, NSApplicationDelegate {
    private var testWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
            showTestWindow()
            return
        }

        #if !DEBUG
        if OrchardInstallation.requiresMoveToApplications() {
            showMoveToApplicationsAlert()
        }
        #endif
    }

    private func showTestWindow() {
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

    private func showMoveToApplicationsAlert() {
        NSApplication.shared.activate()

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Move Orchard to Applications"
        alert.informativeText = """
        Orchard needs a stable installation path before macOS can grant Accessibility access.

        Quit Orchard, move Orchard.app into Applications, then reopen it before enabling Accessibility.
        """
        alert.addButton(withTitle: "Open Applications Folder")
        alert.addButton(withTitle: "Quit")

        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(
                URL(fileURLWithPath: "/Applications", isDirectory: true)
            )
        }
        NSApplication.shared.terminate(nil)
    }
}
