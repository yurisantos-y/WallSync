import SwiftUI

/// The pages of the main window.
enum MainDestination: Hashable {
    case library
    case displays
    case playlist(UUID)
    case settings
}

/// The main window: a sidebar with the four places of the app and the page
/// of the selected one. Everything is built from standard controls and
/// system backgrounds, so an idle window costs nothing to composite.
struct MainWindowView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @State private var selection: MainDestination? = .library
    @State private var isDropTargeted = false

    var body: some View {
        NavigationSplitView {
            MainSidebar(selection: $selection)
                .navigationSplitViewColumnWidth(min: 190, ideal: 215, max: 280)
        } detail: {
            detail
                .safeAreaInset(edge: .top, spacing: 0) {
                    if let message = coordinator.lastErrorMessage {
                        ErrorBanner(message: message) { coordinator.dismissError() }
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .animation(.easeOut(duration: 0.2), value: coordinator.lastErrorMessage)
        }
        // Video files can be dropped anywhere on the window.
        .dropDestination(for: URL.self) { urls, _ in
            let videos = urls.filter(AssetImportPipeline.isImportable)
            guard !videos.isEmpty else { return false }
            coordinator.importVideos(at: videos)
            selection = .library
            return true
        } isTargeted: { isDropTargeted = $0 }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .onChange(of: coordinator.playlists.map(\.id)) { _, ids in
            if case let .playlist(id)? = selection, !ids.contains(id) {
                selection = .library
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection ?? .library {
        case .library:
            LibraryView()
        case .displays:
            DisplaysView()
        case let .playlist(id):
            if let playlist = coordinator.playlist(withID: id) {
                PlaylistDetailView(playlist: playlist)
                    .id(id)
            } else {
                LibraryView()
            }
        case .settings:
            SettingsView()
        }
    }
}

private struct MainSidebar: View {
    @Environment(AppCoordinator.self) private var coordinator
    @Binding var selection: MainDestination?

    var body: some View {
        List(selection: $selection) {
            Section {
                Label("Library", systemImage: "photo.on.rectangle")
                    .tag(MainDestination.library)
                Label("Displays", systemImage: "display.2")
                    .tag(MainDestination.displays)
            }

            Section("Playlists") {
                ForEach(coordinator.playlists) { playlist in
                    PlaylistSidebarRow(
                        playlist: playlist,
                        isInRotation: coordinator.resolution.activePlaylistIDs.contains(playlist.id)
                    )
                    .tag(MainDestination.playlist(playlist.id))
                    .contextMenu {
                        Button("Delete", role: .destructive) {
                            coordinator.deletePlaylist(playlist.id)
                        }
                    }
                }

                Button {
                    selection = .playlist(coordinator.createPlaylist().id)
                } label: {
                    Label("New playlist", systemImage: "plus")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(Text("A playlist changes the wallpaper by itself."))
            }

            Section {
                Label("Settings", systemImage: "gearshape")
                    .tag(MainDestination.settings)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SidebarStatusFooter()
        }
    }
}

private struct PlaylistSidebarRow: View {
    let playlist: WallpaperPlaylist
    let isInRotation: Bool

    var body: some View {
        HStack(spacing: 6) {
            Label(playlist.name.isEmpty ? String(localized: "Untitled playlist") : playlist.name, systemImage: playlist.kind.systemImage)
                .lineLimit(1)
            Spacer(minLength: 0)
            if isInRotation {
                StatusDot(color: .green)
                    .help(Text("In rotation"))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(isInRotation ? Text("In rotation") : Text(verbatim: ""))
    }
}

extension WallpaperPlaylist.Kind {
    var systemImage: String {
        switch self {
        case .interval: return "timer"
        case .timeOfDay: return "sun.horizon"
        case .appearance: return "circle.lefthalf.filled"
        }
    }
}

/// What the wallpapers are doing right now, visible from every page, with
/// the one control that affects all of them.
private struct SidebarStatusFooter: View {
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        let summary = coordinator.statusSummary
        let isPaused = coordinator.runtimeState.isUserPaused

        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                StatusDot(color: summary.color)
                Text(summary.localizedLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button {
                    coordinator.setUserPaused(!isPaused)
                } label: {
                    Image(systemName: isPaused ? "play.fill" : "pause.fill")
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.borderless)
                .disabled(coordinator.activeSessions.isEmpty && !isPaused)
                .help(isPaused ? Text("Resume all wallpapers") : Text("Pause all wallpapers"))
                .accessibilityLabel(isPaused ? Text("Resume all wallpapers") : Text("Pause all wallpapers"))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }
}

/// Shows the latest error on every page until the user dismisses it.
struct ErrorBanner: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .accessibilityHidden(true)

            Text(message)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(Text("Dismiss"))
            .help(Text("Dismiss"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.red.opacity(0.12))
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Error"))
    }
}
