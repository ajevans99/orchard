import Testing
@testable import Orchard

struct OrchardTests {
    @Test func windowIdentifiersAreStableAndDistinct() {
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

    @Test func customTitleOverridesNativeTitle() {
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
