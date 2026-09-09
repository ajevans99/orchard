import XCTest

final class OrchardUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testActiveWindowIsPinnedAndSearchable() async throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        addTeardownBlock {
            app.terminate()
        }

        let testWindow = app.windows["Orchard UI Tests"]
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertTrue(testWindow.exists)

        let activeRow = testWindow.descendants(matching: .any)["window-row-ui-active"]
        let finderRow = testWindow.descendants(matching: .any)["window-row-ui-finder"]
        XCTAssertTrue(activeRow.exists)
        XCTAssertTrue(finderRow.exists)
        XCTAssertEqual(activeRow.textFields.firstMatch.value as? String, "Hello, Orchard")
        XCTAssertTrue(activeRow.staticTexts["ACTIVE"].exists)
        XCTAssertLessThan(activeRow.frame.minY, finderRow.frame.minY)

        let searchField = testWindow.textFields.firstMatch
        XCTAssertTrue(searchField.exists)
        XCTAssertEqual(searchField.placeholderValue, "Find a window")
        searchField.click()
        searchField.typeText("Finder")

        try await Task.sleep(for: .milliseconds(250))
        XCTAssertTrue(finderRow.exists)
        XCTAssertFalse(activeRow.exists)
    }

    @MainActor
    func testIdentityInspectorShowsActiveWindow() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        addTeardownBlock { app.terminate() }

        let menu = app.windows["Orchard UI Tests"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        menu.buttons["inspect-window-identity"].click()

        let inspector = app.windows["Window Identity"]
        XCTAssertTrue(inspector.waitForExistence(timeout: 5))
        XCTAssertTrue(inspector.staticTexts["Live window only"].exists)
        XCTAssertTrue(inspector.staticTexts["Hello, Orchard"].exists)
        XCTAssertTrue(inspector.staticTexts["ui-active"].exists)
        XCTAssertTrue(inspector.staticTexts["Recent identity decisions"].exists)
    }

    @MainActor
    func testLaunchPerformance() throws {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            let app = XCUIApplication()
            app.launchArguments = ["--ui-testing"]
            app.launch()
        }
    }
}
