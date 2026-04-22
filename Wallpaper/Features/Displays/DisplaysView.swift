import SwiftUI

struct DisplaysView: View {
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        WallpaperPageScrollView {
            WallpaperPageHeader(
                "Displays",
                subtitle: "Cada monitor recebe uma janela dedicada em nivel de desktop. Defina um wallpaper global, aplique overrides locais e acompanhe o estado de runtime por display."
            )

            globalAssignmentCard

            if coordinator.runtimeState.activeDisplays.isEmpty {
                WallpaperGlassCard {
                    ContentUnavailableView(
                        "Nenhum display encontrado",
                        systemImage: "display",
                        description: Text("Conecte um monitor ou aguarde a topologia do sistema estabilizar.")
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 30)
                }
            } else {
                LazyVStack(spacing: 14) {
                    ForEach(coordinator.runtimeState.activeDisplays) { display in
                        WallpaperPlacementEditor(display: display)
                    }
                }
            }
        }
    }

    private var globalAssignmentCard: some View {
        WallpaperSectionCard(
            "Padrao global",
            subtitle: "O wallpaper global entra como fallback automatico quando um monitor nao tem atribuicao especifica."
        ) {
            HStack(alignment: .top) {
                Spacer()

                VStack(alignment: .trailing, spacing: 8) {
                    WallpaperStatusPill(
                        label: "\(coordinator.runtimeState.activeDisplays.count) displays",
                        color: .blue
                    )
                    WallpaperStatusPill(
                        label: "\(coordinator.activeSessions.count) sessoes",
                        color: .green
                    )
                }
            }

            Picker(
                "Wallpaper global",
                selection: Binding<UUID?>(
                    get: { coordinator.globalAssetID() },
                    set: { coordinator.setGlobalAsset($0) }
                )
            ) {
                Text("Sem wallpaper global").tag(Optional<UUID>.none)
                ForEach(coordinator.assets) { asset in
                    Text(asset.displayName).tag(Optional(asset.id))
                }
            }
            .pickerStyle(.menu)

            HStack(spacing: 10) {
                WallpaperStatusPill(
                    label: coordinator.runtimeState.powerSource == .battery ? "Bateria" : "Tomada",
                    color: coordinator.runtimeState.powerSource == .battery ? .orange : .green
                )
                WallpaperStatusPill(
                    label: "Thermal \(coordinator.runtimeState.thermalState.displayLabel)",
                    color: coordinator.runtimeState.thermalState == .nominal ? .green : .orange
                )

                if !coordinator.runtimeState.fullscreenDisplayUUIDs.isEmpty {
                    WallpaperStatusPill(
                        label: "\(coordinator.runtimeState.fullscreenDisplayUUIDs.count) fullscreen",
                        color: .orange
                    )
                }
            }
        }
    }
}

private extension ProcessInfo.ThermalState {
    var displayLabel: String {
        switch self {
        case .nominal:
            return "Nominal"
        case .fair:
            return "Fair"
        case .serious:
            return "Serious"
        case .critical:
            return "Critical"
        @unknown default:
            return "Unknown"
        }
    }
}
