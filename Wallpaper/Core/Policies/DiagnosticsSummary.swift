import Foundation

/// Builds the plain-text diagnostics report. It is deliberately not
/// localized so that reports are comparable across users.
enum DiagnosticsSummary {
    static func text(
        appVersion: String,
        runtimeState: AppRuntimeState,
        preferences: UserPreferences,
        sessions: [RenderSession],
        assets: [WallpaperAsset]
    ) -> String {
        var lines: [String] = []
        lines.append("WallSync \(appVersion)")
        lines.append(
            "power=\(runtimeState.powerSource.rawValue) lowPowerMode=\(runtimeState.lowPowerMode) thermal=\(thermalLabel(runtimeState.thermalState))"
        )
        lines.append(
            "preferences: reduceOnBattery=\(preferences.reduceOnBattery) pauseWhenFullscreen=\(preferences.pauseWhenFullscreen) pauseWhenOccluded=\(preferences.pauseWhenOccluded) fallbackMode=\(preferences.fallbackMode.rawValue)"
        )
        lines.append("displays=\(runtimeState.activeDisplays.count) sessions=\(sessions.count) assets=\(assets.count)")

        let sessionsByDisplay = Dictionary(
            sessions.map { ($0.displayTarget.displayUUID, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        for display in runtimeState.activeDisplays {
            lines.append("")
            lines.append(
                "[\(display.localizedName)] \(Int(display.frame.width))x\(Int(display.frame.height)) @\(display.backingScaleFactor)x \(display.maximumFramesPerSecond) Hz\(display.isPrimary ? " primary" : "")"
            )

            guard let session = sessionsByDisplay[display.displayUUID] else {
                lines.append("  no session")
                continue
            }

            lines.append(line(for: session))
            lines.append("  video: \(videoDescription(for: session))")
        }

        return lines.joined(separator: "\n")
    }

    static func line(for session: RenderSession) -> String {
        "  energy=\(session.energyMode.rawValue) reason=\(session.modeReason.rawValue) playback=\(session.playbackState.rawValue) window=\(session.windowState.rawValue) source=\(session.playbackSource?.rawValue ?? "none")"
    }

    static func videoDescription(for session: RenderSession) -> String {
        guard let size = session.videoPixelSize else { return "unknown" }
        let fps = session.videoFrameRate.map { String(format: "%.0f fps", $0) } ?? "? fps"
        return "\(Int(size.width))x\(Int(size.height)) \(fps) \(session.videoCodec ?? "?")"
    }

    static func thermalLabel(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
}
