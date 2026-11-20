import AVFAudio

enum AppMicrophonePermission: Equatable {
    case undetermined
    case denied
    case granted
}

/// The containing app's microphone permission. The keyboard's WebKit capture
/// is attributed to the app's grant, so the app must hold it first.
protocol AppMicrophoneAccess {
    var permission: AppMicrophonePermission { get }
    /// Shows the system prompt when the permission is undetermined.
    func requestPermission() async -> Bool
}

struct SystemAppMicrophoneAccess: AppMicrophoneAccess {
    var permission: AppMicrophonePermission {
        let permission = AVAudioApplication.shared.recordPermission
        if permission == .granted {
            return .granted
        }
        if permission == .denied {
            return .denied
        }
        return .undetermined
    }

    func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }
}
