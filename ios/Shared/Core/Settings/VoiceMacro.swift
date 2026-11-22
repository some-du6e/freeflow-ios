import Foundation

/// A spoken command that inserts a fixed payload instead of the transcript.
/// Same shape and JSON encoding as the macOS `VoiceMacro` in
/// Sources/AppState.swift, stored under `FreeFlowSettingKey.voiceMacros`.
struct VoiceMacro: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var command: String
    var payload: String
}

enum VoiceMacroCodec {
    static func decode(_ data: Data?) -> [VoiceMacro] {
        guard let data, let macros = try? JSONDecoder().decode([VoiceMacro].self, from: data) else {
            return []
        }
        return macros
    }

    static func encode(_ macros: [VoiceMacro]) -> Data? {
        try? JSONEncoder().encode(macros)
    }
}
