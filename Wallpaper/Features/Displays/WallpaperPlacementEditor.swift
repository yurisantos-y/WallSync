import SwiftUI

struct WallpaperPlacementEditor: View {
    @Environment(AppCoordinator.self) private var coordinator

    let display: DisplayTarget

    var body: some View {
        WallpaperGlassCard(padding: 18, cornerRadius: 24) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(display.localizedName)
                            .font(.title3.weight(.semibold))
                        Text("\(Int(display.frame.width))x\(Int(display.frame.height)) • \(display.maximumFramesPerSecond) Hz")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if display.isPrimary {
                        WallpaperStatusPill(label: "Principal", color: .blue)
                    }
                }

                displayStatusRow

                VStack(alignment: .leading, spacing: 6) {
                    Text("Wallpaper efetivo")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(effectiveAssetLabel)
                        .font(.headline)
                    Text(sourceLabel)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Picker(
                    "Wallpaper",
                    selection: Binding<UUID?>(
                        get: { coordinator.assignedAssetID(for: display) },
                        set: { coordinator.assignAsset($0, to: display) }
                    )
                ) {
                    Text("Usar fallback/global").tag(Optional<UUID>.none)
                    ForEach(coordinator.assets) { asset in
                        Text(asset.displayName).tag(Optional(asset.id))
                    }
                }
                .pickerStyle(.menu)
                .disabled(coordinator.assets.isEmpty)

                Picker(
                    "Modo",
                    selection: Binding(
                        get: { coordinator.contentMode(for: display) },
                        set: { coordinator.updateContentMode($0, for: display) }
                    )
                ) {
                    Text("Aspect Fill").tag(WallpaperPlacement.ContentMode.aspectFill)
                    Text("Aspect Fit").tag(WallpaperPlacement.ContentMode.aspectFit)
                }
                .pickerStyle(.segmented)

                HStack {
                    Button("Usar fallback global") {
                        coordinator.assignAsset(nil, to: display)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!coordinator.hasDisplayOverride(for: display))

                    Spacer()

                    if let session = coordinator.session(for: display) {
                        Text("Sessao: \(session.playbackState.displayLabel) • \(session.energyMode.displayLabel)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Sem sessao ativa")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var effectiveAssetLabel: String {
        coordinator.effectiveAsset(for: display)?.displayName ?? "Nenhum wallpaper definido"
    }

    private var sourceLabel: String {
        if coordinator.hasDisplayOverride(for: display) {
            return "Origem: atribuicao especifica para este display"
        }

        if coordinator.globalAssetID() != nil {
            return "Origem: fallback do wallpaper global"
        }

        return "Origem: sem fallback configurado"
    }

    private var displayStatusRow: some View {
        HStack(spacing: 8) {
            WallpaperStatusPill(
                label: coordinator.hasDisplayOverride(for: display) ? "Override" : "Global",
                color: coordinator.hasDisplayOverride(for: display) ? .blue : .gray
            )

            if coordinator.isDisplayFullscreen(display) {
                WallpaperStatusPill(label: "Fullscreen", color: .orange)
            }

            if let session = coordinator.session(for: display) {
                WallpaperStatusPill(label: session.playbackState.displayLabel, color: session.playbackState.color)
                WallpaperStatusPill(label: session.energyMode.displayLabel, color: session.energyMode.color)
            } else {
                WallpaperStatusPill(label: "Idle", color: .gray)
            }
        }
    }
}

private extension RenderSession.PlaybackState {
    var displayLabel: String {
        switch self {
        case .idle:
            return "Idle"
        case .preparing:
            return "Preparing"
        case .animating:
            return "Animating"
        case .poster:
            return "Poster"
        case .paused:
            return "Paused"
        case .failed:
            return "Failed"
        }
    }

    var color: Color {
        switch self {
        case .animating:
            return .green
        case .poster:
            return .orange
        case .paused, .idle:
            return .gray
        case .preparing:
            return .blue
        case .failed:
            return .red
        }
    }
}

private extension RenderSession.EnergyMode {
    var displayLabel: String {
        switch self {
        case .animate:
            return "Animate"
        case .poster:
            return "Poster"
        case .suspend:
            return "Suspend"
        }
    }

    var color: Color {
        switch self {
        case .animate:
            return .green
        case .poster:
            return .orange
        case .suspend:
            return .gray
        }
    }
}
