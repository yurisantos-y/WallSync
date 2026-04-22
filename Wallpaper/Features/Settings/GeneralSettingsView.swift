import SwiftUI

struct GeneralSettingsView: View {
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        WallpaperPageScrollView {
            WallpaperPageHeader(
                "Geral",
                subtitle: "Preferencias basicas do app, persistencia local e fluxo padrao de abertura."
            )

            WallpaperSectionCard(
                "Comportamento do app",
                subtitle: "Defina como o Wallpaper inicializa e se comporta ao abrir."
            ) {
                VStack(alignment: .leading, spacing: 14) {
                    Toggle(
                        "Iniciar wallpapers quando o app abrir",
                        isOn: Binding(
                            get: { coordinator.preferences.startOnLaunch },
                            set: { coordinator.updateStartOnLaunch($0) }
                        )
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
