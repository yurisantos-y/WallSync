import SwiftUI

@main
struct WallpaperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("WallSync", id: "main") {
            MainWindowSceneView()
                .environment(appDelegate.coordinator)
                .frame(minWidth: 780, minHeight: 520)
        }
        .defaultSize(width: 1040, height: 680)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
    }
}

private struct MainWindowSceneView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        MainWindowView()
            .task {
                coordinator.registerOpenMainWindowAction {
                    openWindow(id: "main")
                }
            }
    }
}
