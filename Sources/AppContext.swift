import Foundation

struct AppContext {
    let appName: String?
    let bundleIdentifier: String?
    let windowTitle: String?
    let selectedText: String?
    let currentActivity: String
    let contextSystemPrompt: String?
    let contextPrompt: String?
    let screenshotDataURL: String?
    let screenshotMimeType: String?
    let screenshotError: String?

    var contextSummary: String {
        currentActivity
    }

    var summaryForPostProcessing: String {
        ContextInferenceFailure.usableSummary(currentActivity)
    }
}
