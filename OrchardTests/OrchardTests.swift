import Testing
@testable import Orchard

struct OrchardTests {
    @Test @MainActor func windowIdentifiersAreStableAndDistinct() {
        let first = WindowIdentifier.make(
            bundleIdentifier: "com.apple.dt.Xcode",
            nativeTitle: "Orchard"
        )
        let repeated = WindowIdentifier.make(
            bundleIdentifier: "com.apple.dt.Xcode",
            nativeTitle: "Orchard"
        )
        let secondWindow = WindowIdentifier.make(
            bundleIdentifier: "com.apple.dt.Xcode",
            nativeTitle: "Orchard",
            occurrence: 1
        )

        #expect(first == repeated)
        #expect(first != secondWindow)
        #expect(first.count == 8)
    }

    @Test @MainActor func customTitleOverridesNativeTitle() {
        let record = WindowRecord(
            id: "12345678",
            appName: "Xcode",
            bundleIdentifier: "com.apple.dt.Xcode",
            nativeTitle: "Orchard",
            customTitle: "CLI work",
            color: .green
        )

        #expect(record.displayTitle == "CLI work")
    }

    @Test @MainActor func telemetryEventsHaveStablePrivacySafePayloads() {
        let menuEvent = OrchardTelemetryEvent.menuPresented(
            windowCount: 4,
            labeledWindowCount: 2,
            accessibilityTrusted: true
        )
        let focusEvent = OrchardTelemetryEvent.windowFocused(
            source: .commandLine,
            succeeded: false
        )

        #expect(menuEvent.signalName == "menu.presented")
        #expect(
            menuEvent.parameters == [
                "windowCount": "4",
                "labeledWindowCount": "2",
                "accessibilityTrusted": "true",
            ]
        )
        #expect(focusEvent.signalName == "window.focused")
        #expect(
            focusEvent.parameters == [
                "source": "commandLine",
                "succeeded": "false",
            ]
        )
        #expect(
            OrchardTelemetryEvent.windowColorChanged(color: .purple).parameters
                == ["color": "purple"]
        )
    }
}
