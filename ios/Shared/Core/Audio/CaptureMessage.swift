import Foundation

/// One `pcm` message from the capture page: 16 kHz mono signed 16-bit little-endian PCM,
/// base64-encoded, from one ScriptProcessor callback.
struct PCMChunk: Equatable {
    /// The capture session the native side assigned in `ffCapture.start`.
    let session: Int
    let sequence: Int
    let frameCount: Int
    let base64: String
    /// RMS of roughly 21 ms blocks at the device rate, on AudioRecorder's linear scale.
    let levels: [Float]
    /// The last chunk of a stopped session; it carries the resampler's tail.
    let isFinal: Bool
}

/// A message the capture page posts to `window.webkit.messageHandlers.ffCapture`.
///
/// `init(body:)` parses `WKScriptMessage.body`, which WebKit delivers as an NSDictionary of
/// NSString, NSNumber and NSArray values. The page is our own code, but its messages are
/// still validated: anything malformed is rejected, and free-form strings are reduced to a
/// short, log-safe token.
enum CaptureMessage: Equatable {
    /// The page script ran and the bridge is installed.
    case ready(pageVersion: Int, hasSyntheticSource: Bool)
    /// The audio graph is running. Rates are in Hz; `captureRate` is 0 when unknown.
    case started(session: Int, contextRate: Double, captureRate: Double, isSynthetic: Bool)
    case pcm(PCMChunk)
    /// The session ended in the page, after `stop`, `cancel`, or on its own.
    case ended(session: Int, reason: String, frames: Int)
    /// The session never started. `name` is the JavaScript error name, e.g. NotAllowedError.
    case failed(session: Int, name: String)

    /// The longest `lv` array accepted; the page sends about two per chunk.
    static let maxLevelsPerChunk = 64
    static let maxTokenLength = 64

    init?(body: Any) {
        guard let fields = body as? [String: Any], let type = fields["t"] as? String else { return nil }
        switch type {
        case "ready":
            self = .ready(
                pageVersion: Self.integer(fields["v"]) ?? 0,
                hasSyntheticSource: Self.boolean(fields["synthetic"]) ?? false
            )
        case "started":
            guard let session = Self.integer(fields["sid"]),
                  let contextRate = Self.number(fields["rate"]), contextRate > 0 else { return nil }
            let captureRate = Self.number(fields["captureRate"]) ?? 0
            self = .started(
                session: session,
                contextRate: contextRate,
                captureRate: captureRate >= 0 ? captureRate : 0,
                isSynthetic: Self.boolean(fields["synthetic"]) ?? false
            )
        case "pcm":
            guard let session = Self.integer(fields["sid"]),
                  let sequence = Self.integer(fields["seq"]), sequence >= 0,
                  let frameCount = Self.integer(fields["n"]), frameCount >= 0,
                  let base64 = fields["b64"] as? String,
                  let rawLevels = fields["lv"] as? [Any], rawLevels.count <= Self.maxLevelsPerChunk,
                  let isFinal = Self.boolean(fields["final"]) else { return nil }
            var levels: [Float] = []
            levels.reserveCapacity(rawLevels.count)
            for rawLevel in rawLevels {
                guard let level = Self.number(rawLevel), level >= 0 else { return nil }
                levels.append(Float(level))
            }
            self = .pcm(PCMChunk(
                session: session,
                sequence: sequence,
                frameCount: frameCount,
                base64: base64,
                levels: levels,
                isFinal: isFinal
            ))
        case "ended":
            guard let session = Self.integer(fields["sid"]) else { return nil }
            self = .ended(
                session: session,
                reason: Self.token(fields["reason"]),
                frames: max(0, Self.integer(fields["frames"]) ?? 0)
            )
        case "failed":
            guard let session = Self.integer(fields["sid"]) else { return nil }
            self = .failed(session: session, name: Self.token(fields["name"]))
        default:
            return nil
        }
    }

    /// The session a message belongs to; nil for page-level messages.
    var session: Int? {
        switch self {
        case .ready:
            return nil
        case .started(let session, _, _, _), .ended(let session, _, _), .failed(let session, _):
            return session
        case .pcm(let chunk):
            return chunk.session
        }
    }

    enum FailureKind: Equatable {
        /// WebKit refused the microphone, usually because the containing app lacks permission.
        case permissionDenied
        /// The platform can't capture here, e.g. Lockdown Mode or an unsupported audio rate.
        case unsupported
    }

    /// Classifies a `failed` message's error name.
    static func failureKind(forName name: String) -> FailureKind {
        name == "NotAllowedError" ? .permissionDenied : .unsupported
    }

    // MARK: Field parsing

    private static func numberObject(_ value: Any?) -> NSNumber? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number as CFTypeRef) != CFBooleanGetTypeID() else { return nil }
        return number
    }

    /// A finite number. Booleans are not numbers here.
    static func number(_ value: Any?) -> Double? {
        guard let value = numberObject(value)?.doubleValue, value.isFinite else { return nil }
        return value
    }

    /// A finite integral number in the range JavaScript represents exactly.
    static func integer(_ value: Any?) -> Int? {
        guard let value = number(value), value == value.rounded(), abs(value) <= 9_007_199_254_740_991 else {
            return nil
        }
        return Int(value)
    }

    static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number as CFTypeRef) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    /// A short token made only of letters, digits, `.`, `_` and `-`, so page-supplied
    /// reasons and error names are safe to log. Anything else becomes "unknown".
    static func token(_ value: Any?) -> String {
        guard let string = value as? String else { return "unknown" }
        var token = String.UnicodeScalarView()
        var length = 0
        for scalar in string.unicodeScalars where isTokenScalar(scalar) {
            token.append(scalar)
            length += 1
            if length == maxTokenLength { break }
        }
        return length == 0 ? "unknown" : String(token)
    }

    private static func isTokenScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "a"..."z", "A"..."Z", "0"..."9", ".", "_", "-":
            return true
        default:
            return false
        }
    }
}
