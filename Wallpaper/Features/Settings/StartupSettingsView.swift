import SwiftUI

struct StartupSettingsView: View {
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        WallpaperPageScrollView {
            WallpaperPageHeader(
                "Inicializacao",
                subtitle: "Controle o login item do macOS e acompanhe o estado atual de ativacao."
            )

            WallpaperSectionCard(
                "Abertura automatica",
                subtitle: "Quando ativado, o app inicia junto com sua sessao de usuario."
            ) {
                VStack(alignment: .leading, spacing: 0) {
                    Toggle(
                        "Abrir ao iniciar sessao",
                        isOn: Binding(
                            get: { coordinator.preferences.launchAtLogin },
                            set: { coordinator.updateLaunchAtLogin($0) }
                        )
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            WallpaperSectionCard(
                "Estado atual",
                subtitle: "Esse status reflete o retorno mais recente do sistema para o login item."
            ) {
                LabeledContent("Status") {
                    WallpaperStatusPill(label: statusLabel, color: statusColor)
                }
            }
        }
    }

    private var statusLabel: String {
        switch coordinator.startupLoginState {
        case .enabled:
            return "Ativado"
        case .disabled:
            return "Desativado"
        case .requiresApproval:
            return "Aguardando aprovacao do sistema"
        }
    }

    private var statusColor: Color {
        switch coordinator.startupLoginState {
        case .enabled:
            return .green
        case .disabled:
            return .gray
        case .requiresApproval:
            return .orange
        }
    }
}
