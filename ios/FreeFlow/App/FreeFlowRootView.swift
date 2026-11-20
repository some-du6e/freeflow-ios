import SwiftUI
import UIKit

/// Onboarding until setup is done, then the tabs. The recorder covers
/// either, so the keyboard's fallback works even mid-setup.
struct FreeFlowRootView: View {
    @EnvironmentObject private var app: FreeFlowAppModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if app.hasCompletedSetup {
                FreeFlowTabsView(app: app)
                    .ignoresSafeArea()
            } else {
                OnboardingView(app: app)
            }
        }
        .fullScreenCover(item: $app.activeRecorder) { recorder in
            RecorderView(model: recorder)
                .environmentObject(app)
        }
        .onOpenURL { url in
            openRecorder(for: url)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                app.sceneBecameActive()
            case .background:
                app.sceneEnteredBackground()
            default:
                break
            }
        }
    }
}

extension FreeFlowRootView {
    /// A sheet or alert left open in a tab would stop the recorder from
    /// being presented, and the keyboard would wait for a result that never
    /// comes. Close them first, then open the recorder.
    fileprivate func openRecorder(for url: URL) {
        guard FreeFlowURLRoute(url: url) != nil else { return }
        guard app.activeRecorder == nil, FreeFlowPresentation.isPresenting else {
            app.handle(url: url)
            return
        }
        app.closeOtherPresentations()
        Task {
            await FreeFlowPresentation.wait(timeout: 2) { !FreeFlowPresentation.isPresenting }
            app.handle(url: url)
        }
    }
}

/// What the window currently presents. SwiftUI presents every sheet and
/// alert, including those from the tabs' hosting controllers, from the
/// window's root view controller.
@MainActor
enum FreeFlowPresentation {
    static var isPresenting: Bool {
        rootViewController?.presentedViewController != nil
    }

    static var rootViewController: UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.compactMap { $0.keyWindow }.first ?? scenes.flatMap(\.windows).first
        return window?.rootViewController
    }

    /// Polls `condition` every 50 ms until it holds or `timeout` passes.
    static func wait(timeout: TimeInterval, until condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }
}

/// The three tabs, in a UIKit tab bar controller so each tab button carries
/// its DESIGN §5.1 accessibility identifier (SwiftUI's `tabItem` drops
/// identifiers set on its label).
struct FreeFlowTabsView: UIViewControllerRepresentable {
    @ObservedObject var app: FreeFlowAppModel

    func makeCoordinator() -> Coordinator {
        Coordinator(app: app)
    }

    func makeUIViewController(context: Context) -> UITabBarController {
        let controller = UITabBarController()
        controller.delegate = context.coordinator
        controller.viewControllers = FreeFlowAppTab.allCases.map { tab in
            let host = UIHostingController(rootView: rootView(for: tab))
            host.tabBarItem = Self.makeTabBarItem(for: tab)
            return host
        }
        controller.selectedIndex = app.selectedTab.rawValue
        return controller
    }

    func updateUIViewController(_ controller: UITabBarController, context: Context) {
        context.coordinator.app = app
        let index = app.selectedTab.rawValue
        if controller.selectedIndex != index {
            controller.selectedIndex = index
        }
    }

    static func makeTabBarItem(for tab: FreeFlowAppTab) -> UITabBarItem {
        let item = UITabBarItem(
            title: tab.title,
            image: UIImage(systemName: tab.systemImage),
            selectedImage: UIImage(systemName: tab.selectedSystemImage)
        )
        item.tag = tab.rawValue
        item.accessibilityIdentifier = tab.accessibilityIdentifier
        return item
    }

    private func rootView(for tab: FreeFlowAppTab) -> AnyView {
        switch tab {
        case .home:
            AnyView(HomeView().environmentObject(app))
        case .history:
            AnyView(HistoryScreen().environmentObject(app))
        case .settings:
            AnyView(SettingsScreen(environment: app.environment).environmentObject(app))
        }
    }

    @MainActor
    final class Coordinator: NSObject, UITabBarControllerDelegate {
        var app: FreeFlowAppModel

        init(app: FreeFlowAppModel) {
            self.app = app
        }

        func tabBarController(_ tabBarController: UITabBarController, didSelect viewController: UIViewController) {
            guard let tab = FreeFlowAppTab(rawValue: tabBarController.selectedIndex),
                  app.selectedTab != tab else {
                return
            }
            app.selectedTab = tab
        }
    }
}
