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
    /// 127.0.0.1. The report records the runner's own App Transport Security
    /// keys, so the result says whether ATS lets a bundle without exceptions,
    /// like the keyboard extension, reach the mock.
    func testMockProviderIsReachableFromSimulator() throws {
        let runnerATS = Bundle.main.object(forInfoDictionaryKey: "NSAppTransportSecurity")
        let atsKeys = runnerATS.map { "ATS keys \(String(describing: $0))" } ?? "no ATS keys"
        switch MockProvider.send("GET", "/healthz") {
        case .failure(let error as URLError) where error.code == .appTransportSecurityRequiresSecureConnection:
            report("ATS blocked plain HTTP to \(MockProvider.origin) from the test runner (\(atsKeys))")
            throw XCTSkip("App Transport Security blocks plain HTTP to the mock provider from the test runner")
        case .failure(let error):
            XCTFail("The mock provider at \(MockProvider.origin) is not reachable: \(error)")
            return
        case .success(let response):
            XCTAssertEqual(response.status, 200, "The mock provider's health check failed")
        }
        report("ATS allowed plain HTTP to \(MockProvider.origin) from the test runner (\(atsKeys))")

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
