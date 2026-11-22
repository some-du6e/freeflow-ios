import Foundation

/// URLs the app handles. The keyboard's fallback opens
/// `freeflow://dictate?session=<uuid>` (DESIGN §5.4).
enum FreeFlowURLRoute: Equatable {
    /// Record in the app. With a session, the result is handed back to the
    /// keyboard that asked for it; without one, it stays in the app.
    case dictate(sessionID: UUID?)

    static let scheme = "freeflow"

    init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        // freeflow://dictate puts "dictate" in the host; accept freeflow:dictate too.
        let target = (components.host ?? components.path)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()
        guard target == "dictate" else { return nil }

        let session = components.queryItems?
            .first(where: { $0.name == "session" })?
            .value
            .flatMap { UUID(uuidString: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        self = .dictate(sessionID: session)
    }
}
