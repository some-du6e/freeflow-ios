import Foundation

/// Decides one fixed gain for a finished recording before upload. WebKit's capture applies
/// no automatic gain, so quiet speech is lifted towards a target level. The rules:
/// never attenuate, never push the peak above -1 dBFS, cap the boost at +24 dB, keep the
/// noise floor at or below -50 dBFS, and leave recordings with no speech above the floor
/// alone, because boosted hiss baits Whisper into transcribing "Thank you."
///
/// The limits are first estimates and need tuning on a device. Debug logs may print the
/// summary numbers and the decision, never audio.
enum UploadGainPolicy {
    struct Limits: Equatable {
        var peakCeilingDBFS: Float = -1
        var speechTargetDBFS: Float = -20
        var maxGainDB: Float = 24
        var maxNoiseFloorAfterGainDBFS: Float = -50
        var minSpeechDBFS: Float = -70
        var minSpeechOverFloorDB: Float = 6
        /// Smaller gains aren't worth rewriting the file for.
        var minGainDB: Float = 0.5
    }

    enum Decision: Equatable {
        case unchanged(Reason)
        case apply(gainDB: Float)

        enum Reason: String, Equatable {
            case empty
            /// Silence, or nothing rises far enough above the noise floor.
            case noSpeech = "no-speech"
            /// Already loud enough, or a boost would clip or raise the noise floor too far.
            case noHeadroom = "no-headroom"
        }

        /// The gain to apply in dB; 0 when unchanged.
        var gainDB: Float {
            if case .apply(let gainDB) = self { return gainDB }
            return 0
        }
    }

    static func decide(_ summary: LoudnessSummary, limits: Limits = Limits()) -> Decision {
        guard summary.frames > 0 else { return .unchanged(.empty) }
        guard summary.speechDBFS >= limits.minSpeechDBFS,
              summary.speechDBFS - summary.noiseFloorDBFS >= limits.minSpeechOverFloorDB else {
            return .unchanged(.noSpeech)
        }
        let gain = min(
            limits.maxGainDB,
            limits.peakCeilingDBFS - summary.peakDBFS,
            limits.speechTargetDBFS - summary.speechDBFS,
            limits.maxNoiseFloorAfterGainDBFS - summary.noiseFloorDBFS
        )
        guard gain >= limits.minGainDB else { return .unchanged(.noHeadroom) }
        return .apply(gainDB: gain)
    }
}
