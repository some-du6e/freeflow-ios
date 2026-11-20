import XCTest

final class FreeFlowUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunchShowsTestField() throws {
        let app = XCUIApplication()
        app.launch()

        // A freshly booted CI simulator can take about 30 seconds to answer
        // the first accessibility query, so leave plenty of headroom.
        let testField = app.descendants(matching: .any).matching(identifier: "freeflow.app.testField").firstMatch
        XCTAssertTrue(testField.waitForExistence(timeout: 120), "The test field did not appear after launch")

        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "01-launch"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
