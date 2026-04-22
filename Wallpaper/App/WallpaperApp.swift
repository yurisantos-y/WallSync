import SwiftUI

@main
struct WallpaperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("WallSync", id: "main") {
            MainWindowSceneView()
                .environment(appDelegate.coordinator)
                .frame(minWidth: 1080, minHeight: 720)
        }
        .defaultSize(width: 1180, height: 780)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
    }
}

private struct MainWindowSceneView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        SettingsView()
            .task {
                coordinator.registerOpenMainWindowAction {
                    openWindow(id: "main")
                }
            }
    }
}
