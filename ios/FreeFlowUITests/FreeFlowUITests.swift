import XCTest

final class FreeFlowUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunchShowsTestField() throws {
        let app = XCUIApplication()
        app.launch()

        let testField = app.descendants(matching: .any).matching(identifier: "testField").firstMatch
        XCTAssertTrue(testField.waitForExistence(timeout: 30), "testField did not appear after launch")

        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "01-launch"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
