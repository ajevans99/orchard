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
}
