import AppKit
import SwiftUI

struct LibraryView: View {
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        WallpaperPageScrollView {
            WallpaperPageHeader(
                "Biblioteca",
                subtitle: "Importe videos locais, classifique os assets e defina o wallpaper global."
            ) {
                Button("Importar video") {
                    coordinator.importVideo()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }

            if let error = coordinator.lastErrorMessage {
                WallpaperGlassCard {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.red)
                }
            }

            if coordinator.assets.isEmpty {
                WallpaperGlassCard {
                    ContentUnavailableView(
                        "Nenhum video importado",
                        systemImage: "film.stack",
                        description: Text("Comece importando um MP4 ou MOV para montar a biblioteca do wallpaper.")
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 30)
                }
            } else {
                LazyVStack(spacing: 14) {
                    ForEach(coordinator.assets) { asset in
                        assetCard(for: asset)
                    }
                }
            }
        }
    }

    private func statusColor(for asset: WallpaperAsset) -> Color {
        switch asset.eligibility.tier {
        case .safe:
            return .green
        case .warning:
            return .orange
        case .unsupported:
            return .red
        }
    }

    private func assetCard(for asset: WallpaperAsset) -> some View {
        WallpaperGlassCard(padding: 18, cornerRadius: 26) {
            HStack(alignment: .top, spacing: 18) {
                AssetPosterThumbnailView(url: coordinator.posterURL(for: asset))

                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(asset.displayName)
                                .font(.title3.weight(.semibold))
                            Text(AssetInspector.technicalSummary(for: asset))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }

                        Spacer(minLength: 12)

                        WallpaperStatusPill(
                            label: AssetInspector.statusText(for: asset),
                            color: statusColor(for: asset)
                        )
                    }

                    if !asset.eligibility.reasonCodes.isEmpty {
                        Text("Motivos: \(asset.eligibility.reasonCodes.joined(separator: ", "))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 10) {
                        if coordinator.globalAssetID() == asset.id {
                            WallpaperStatusPill(label: "Global ativo", color: .blue)
                        }

                        if asset.hasAudio {
                            WallpaperStatusPill(label: "Audio removido no playback", color: .gray)
                        }
                    }

                    HStack(spacing: 10) {
                        Button("Usar em todos os displays") {
                            coordinator.setGlobalAsset(asset.id)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(asset.eligibility.tier == .unsupported)

                        Button("Remover", role: .destructive) {
                            coordinator.removeAsset(asset)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
    }
}

private struct AssetPosterThumbnailView: View {
    let url: URL?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if let url, let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                LinearGradient(
                    colors: placeholderGradient,
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .overlay(
                    Image(systemName: "film")
                        .font(.system(size: 26, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9))
                )
            }
        }
        .frame(width: 220, height: 124)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.12 : 0.35), lineWidth: 1)
                .allowsHitTesting(false)
        }
    }

    private var placeholderGradient: [Color] {
        if colorScheme == .dark {
            return [
                Color(red: 0.18, green: 0.24, blue: 0.33),
                Color(red: 0.22, green: 0.19, blue: 0.17)
            ]
        }

        return [
            Color(red: 0.87, green: 0.90, blue: 0.95),
            Color(red: 0.96, green: 0.89, blue: 0.78)
        ]
    }
}
