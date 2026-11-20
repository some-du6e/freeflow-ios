import SwiftUI

@main
struct FreeFlowApp: App {
    @StateObject private var model: FreeFlowAppModel

    init() {
        // UI tests configure the shared state before any UI exists, so the
        // keyboard process sees the same settings (DESIGN §5.2).
        #if DEBUG
        let microphoneFlagIsOverridden = FreeFlowUITestHooks.applyLaunchArguments().setsMicrophoneFlag
        #else
        let microphoneFlagIsOverridden = false
        #endif
        // Same model migrations the keyboard runs when it resolves a
        // configuration, so Settings shows the migrated model IDs.
        DictationConfiguration.migrateLegacyModelSettings(in: SettingsStore.shared.defaults)
        NetworkMonitor.shared.start()
        AppAudioRecorder.removeLeftoverRecordings()
        _model = StateObject(wrappedValue: FreeFlowAppModel(
            environment: .live,
            microphoneFlagIsOverridden: microphoneFlagIsOverridden
        ))
    }

    var body: some Scene {
        WindowGroup {
            FreeFlowRootView()
                .environmentObject(model)
        }
    }
}
