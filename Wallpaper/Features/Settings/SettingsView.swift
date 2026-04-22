import SwiftUI

struct SettingsView: View {
    @State private var selection: SettingsDestination = .library

    var body: some View {
        NavigationSplitView {
            WallpaperSidebar(selection: $selection)
                .navigationSplitViewColumnWidth(min: 250, ideal: 280, max: 320)
        } detail: {
            ZStack {
                WallpaperWindowBackground()
                detailView(for: selection)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .navigationSplitViewStyle(.balanced)
        .background(WallpaperWindowBackground())
    }

    @ViewBuilder
    private func detailView(for destination: SettingsDestination) -> some View {
        switch destination {
        case .library:
            LibraryView()
        case .displays:
            DisplaysView()
        case .general:
            GeneralSettingsView()
        case .energy:
            EnergySettingsView()
        case .startup:
            StartupSettingsView()
        }
    }
}

enum SettingsDestination: String, CaseIterable, Hashable, Identifiable {
    case library
    case displays
    case general
    case energy
    case startup

    var id: String { rawValue }

    var title: String {
        switch self {
        case .library:
            return "Biblioteca"
        case .displays:
            return "Displays"
        case .general:
            return "Geral"
        case .energy:
            return "Energia"
        case .startup:
            return "Inicializacao"
        }
    }

    var subtitle: String {
        switch self {
        case .library:
            return "Gerencie seus videos e escolha o wallpaper global."
        case .displays:
            return "Ajuste atribuicoes, fallback e runtime por monitor."
        case .general:
            return "Preferencias do app e operacao local."
        case .energy:
            return "Politicas de bateria, oclusao e fullscreen."
        case .startup:
            return "Controle abertura automatica e login item."
        }
    }

    var systemImage: String {
        switch self {
        case .library:
            return "film.stack"
        case .displays:
            return "display.2"
        case .general:
            return "gearshape"
        case .energy:
            return "bolt"
        case .startup:
            return "power"
        }
    }

    var group: SidebarGroup {
        switch self {
        case .library, .displays:
            return .workspace
        case .general, .energy, .startup:
            return .preferences
        }
    }
}

enum SidebarGroup: String, CaseIterable, Identifiable {
    case workspace
    case preferences

    var id: String { rawValue }

    var title: String {
        switch self {
        case .workspace:
            return "Workspace"
        case .preferences:
            return "Preferencias"
        }
    }

    var destinations: [SettingsDestination] {
        SettingsDestination.allCases.filter { $0.group == self }
    }
}

struct WallpaperSidebar: View {
    @Binding var selection: SettingsDestination
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Label("Wallpaper", systemImage: "sparkles.rectangle.stack.fill")
                    .font(.title2.weight(.semibold))
                Text("Um painel mais nativo do macOS para biblioteca, displays e energia.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)

            List {
                ForEach(SidebarGroup.allCases) { group in
                    Section(group.title) {
                        ForEach(group.destinations) { destination in
                            Button {
                                selection = destination
                            } label: {
                                SidebarDestinationRow(
                                    destination: destination,
                                    isSelected: selection == destination
                                )
                            }
                            .buttonStyle(.plain)
                            .listRowInsets(EdgeInsets(top: 2, leading: 10, bottom: 2, trailing: 10))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .background(Color.clear)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            ZStack(alignment: .trailing) {
                Rectangle()
                    .fill(.thinMaterial)
                LinearGradient(
                    colors: [
                        Color.white.opacity(colorScheme == .dark ? 0.06 : 0.34),
                        Color.accentColor.opacity(colorScheme == .dark ? 0.03 : 0.06)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Rectangle()
                    .fill(Color.white.opacity(colorScheme == .dark ? 0.10 : 0.42))
                    .frame(width: 1)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }
    }
}

private struct SidebarDestinationRow: View {
    let destination: SettingsDestination
    let isSelected: Bool

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: destination.systemImage)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 18)

            Text(destination.title)
                .font(.system(size: 13, weight: .medium))

            Spacer(minLength: 0)
        }
        .foregroundStyle(isSelected ? .primary : .secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .background(selectionBackground)
    }

    @ViewBuilder
    private var selectionBackground: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.accentColor.opacity(colorScheme == .dark ? 0.22 : 0.14))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.white.opacity(colorScheme == .dark ? 0.10 : 0.30), lineWidth: 0.8)
                }
        } else {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.clear)
        }
    }
}

struct WallpaperWindowBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)

            LinearGradient(
                colors: backgroundGradient,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .opacity(colorScheme == .dark ? 0.96 : 0.92)

            Circle()
                .fill(Color.accentColor.opacity(colorScheme == .dark ? 0.22 : 0.16))
                .frame(width: 420, height: 420)
                .blur(radius: 130)
                .offset(x: -300, y: -260)

            Circle()
                .fill(Color.orange.opacity(colorScheme == .dark ? 0.16 : 0.11))
                .frame(width: 360, height: 360)
                .blur(radius: 120)
                .offset(x: 310, y: -180)

            Circle()
                .fill(Color.white.opacity(colorScheme == .dark ? 0.08 : 0.26))
                .frame(width: 520, height: 520)
                .blur(radius: 170)
                .offset(x: 200, y: 320)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private var backgroundGradient: [Color] {
        if colorScheme == .dark {
            return [
                Color(red: 0.08, green: 0.10, blue: 0.13),
                Color(red: 0.09, green: 0.14, blue: 0.18),
                Color(red: 0.13, green: 0.12, blue: 0.10)
            ]
        }

        return [
            Color(red: 0.88, green: 0.92, blue: 0.97),
            Color(red: 0.95, green: 0.96, blue: 0.98),
            Color(red: 0.98, green: 0.95, blue: 0.91)
        ]
    }
}

struct WallpaperPageScrollView<Content: View>: View {
    @ViewBuilder private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                content
            }
            .frame(maxWidth: 1040, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
        }
        .scrollIndicators(.hidden)
    }
}

struct WallpaperPageHeader: View {
    private let title: String
    private let subtitle: String
    private let accessory: AnyView

    init(_ title: String, subtitle: String) {
        self.title = title
        self.subtitle = subtitle
        accessory = AnyView(EmptyView())
    }

    init<Accessory: View>(_ title: String, subtitle: String, @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.subtitle = subtitle
        self.accessory = AnyView(accessory())
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.largeTitle.weight(.bold))
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 16)

            accessory
        }
    }
}

struct WallpaperGlassCard<Content: View>: View {
    private let padding: CGFloat
    private let cornerRadius: CGFloat
    @ViewBuilder private let content: Content

    @Environment(\.colorScheme) private var colorScheme

    init(
        padding: CGFloat = 20,
        cornerRadius: CGFloat = 24,
        @ViewBuilder content: () -> Content
    ) {
        self.padding = padding
        self.cornerRadius = cornerRadius
        self.content = content()
    }

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(.ultraThinMaterial)

                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color.white.opacity(colorScheme == .dark ? 0.04 : 0.26))

                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(colorScheme == .dark ? 0.10 : 0.42),
                                    Color.white.opacity(0.02),
                                    Color.accentColor.opacity(colorScheme == .dark ? 0.05 : 0.07)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                    )
                }
                .allowsHitTesting(false)
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        Color.white.opacity(colorScheme == .dark ? 0.14 : 0.55),
                        lineWidth: 1
                    )
                    .allowsHitTesting(false)
            }
            .shadow(
                color: Color.black.opacity(colorScheme == .dark ? 0.30 : 0.12),
                radius: 24,
                x: 0,
                y: 12
            )
    }
}

struct WallpaperSectionCard<Content: View>: View {
    private let title: String
    private let subtitle: String?
    @ViewBuilder private let content: Content

    init(
        _ title: String,
        subtitle: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        WallpaperGlassCard {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.title3.weight(.semibold))
                    if let subtitle {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                content
            }
        }
    }
}

struct WallpaperStatusPill: View {
    let label: String
    let color: Color

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Text(label)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(color.opacity(colorScheme == .dark ? 0.20 : 0.12))
            )
            .overlay {
                Capsule(style: .continuous)
                    .stroke(color.opacity(colorScheme == .dark ? 0.28 : 0.18), lineWidth: 0.8)
            }
            .foregroundStyle(color)
    }
}
