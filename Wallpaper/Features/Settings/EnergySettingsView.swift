import SwiftUI

struct EnergySettingsView: View {
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        WallpaperPageScrollView {
            WallpaperPageHeader(
                "Energia",
                subtitle: "Refine como o wallpaper reage a bateria, oclusao e estados que exigem menos processamento."
            )

            WallpaperSectionCard(
                "Politicas automaticas",
                subtitle: "Essas opcoes ajudam a reduzir atividade quando o sistema esta em contextos sensiveis."
            ) {
                VStack(alignment: .leading, spacing: 14) {
                    Toggle(
                        "Reduzir atividade na bateria",
                        isOn: Binding(
                            get: { coordinator.preferences.reduceOnBattery },
                            set: { coordinator.updateReduceOnBattery($0) }
                        )
                    )

                    Divider()

                    Toggle(
                        "Pausar quando o display estiver totalmente ocluido",
                        isOn: Binding(
                            get: { coordinator.preferences.pauseWhenOccluded },
                            set: { coordinator.updatePauseWhenOccluded($0) }
                        )
                    )

                    Divider()

                    Toggle(
                        "Pausar ao entrar em fullscreen",
                        isOn: Binding(
                            get: { coordinator.preferences.pauseWhenFullscreen },
                            set: { coordinator.updatePauseWhenFullscreen($0) }
                        )
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            WallpaperSectionCard(
                "Perfil energetico",
                subtitle: "Escolha a estrategia de fallback aplicada quando o sistema pedir um modo mais conservador."
            ) {
                Picker(
                    "Perfil energetico",
                    selection: Binding(
                        get: { coordinator.preferences.fallbackMode },
                        set: { coordinator.updateFallbackMode($0) }
                    )
                ) {
                    Text("Balanced").tag(UserPreferences.FallbackMode.balanced)
                    Text("Battery Saver").tag(UserPreferences.FallbackMode.batterySaver)
                }
                .pickerStyle(.menu)
            }
        }
    }
}
