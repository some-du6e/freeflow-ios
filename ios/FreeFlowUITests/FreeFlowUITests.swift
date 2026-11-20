import XCTest

final class FreeFlowUITests: FreeFlowUITestCase {
    @MainActor
    func testLaunchShowsTestField() throws {
        let app = launchFreeFlow()
        let testField = element(FreeFlowAccessibilityID.App.testField, in: app)
        XCTAssertTrue(
            testField.waitForExistence(timeout: Self.firstQueryTimeout),
            "The test field did not appear after launch"
        )
        capture("launch")
    }

    /// The app and keyboard reach CI's mock provider over plain HTTP on
    /// 127.0.0.1. The test runner has no App Transport Security exceptions,
    /// like the keyboard extension, so this also shows whether ATS lets such
    /// a bundle reach the mock.
    func testMockProviderIsReachableFromSimulator() throws {
        switch MockProvider.send("GET", "/healthz") {
        case .failure(let error as URLError) where error.code == .appTransportSecurityRequiresSecureConnection:
            report("ATS blocked plain HTTP to \(MockProvider.origin) from a bundle without ATS exceptions")
            throw XCTSkip("App Transport Security blocks plain HTTP to the mock provider from the test runner")
        case .failure(let error):
            XCTFail("The mock provider at \(MockProvider.origin) is not reachable: \(error)")
            return
        case .success(let response):
            XCTAssertEqual(response.status, 200, "The mock provider's health check failed")
        }
        report("ATS allowed plain HTTP to \(MockProvider.origin) from a bundle without ATS exceptions")

        switch MockProvider.send("GET", "/v1/models", apiKey: MockProvider.apiKey) {
        case .failure(let error):
            XCTFail("GET /v1/models failed: \(error)")
        case .success(let response):
            XCTAssertEqual(response.status, 200, "GET /v1/models with the test key should succeed")
        }
        switch MockProvider.send("GET", "/v1/models", apiKey: "not-the-test-key") {
        case .failure(let error):
            XCTFail("GET /v1/models failed: \(error)")
        case .success(let response):
            XCTAssertEqual(response.status, 401, "The mock provider should reject other keys")
        }
    }
}
