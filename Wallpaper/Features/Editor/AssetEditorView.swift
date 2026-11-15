import AVFoundation
import SwiftUI

/// Sheet for the non-destructive edits of one wallpaper. Applying stores the
/// recipe; the optimizer then writes a new rendition in the background.
struct AssetEditorView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.dismiss) private var dismiss
    @State private var model: AssetEditorModel
    @State private var page = Page.loop

    private enum Page: Hashable {
        case loop
        case logo
    }

    init(asset: WallpaperAsset) {
        _model = State(initialValue: AssetEditorModel(asset: asset))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Edit video")
                        .font(.title2.weight(.semibold))
                    Text(model.asset.displayName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker("Editor page", selection: $page) {
                    Text("Loop").tag(Page.loop)
                    Text("Remove logo or mark").tag(Page.logo)
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .labelsHidden()
                .accessibilityLabel(Text("Editor page"))
            }

            if page == .loop || model.phase != .ready {
                preview
                if model.phase == .ready {
                    loopControls
                }
            } else {
                LogoRemovalView(model: model)
            }

            Divider()

            HStack {
                Button("Reset") { model.reset() }
                    .disabled(model.phase != .ready)
                    .help(Text("Use the whole video, without a crossfade or any removal."))

                Spacer()

                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Button("Apply") {
                    coordinator.updateEditRecipe(model.recipe, for: model.asset.id)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(model.phase != .ready || !model.hasChanges)
            }
        }
        .padding(24)
        .frame(width: 760)
        .task { await model.open(coordinator: coordinator) }
        .onDisappear { model.close() }
    }

    @ViewBuilder
    private var preview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.black)

            switch model.phase {
            case .loading:
                ProgressView()
            case .ready:
                PlayerLayerView(player: model.player)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .accessibilityLabel(Text("Preview of the edited loop"))
            case .unavailable:
                ContentUnavailableView(
                    "Original file unavailable",
                    systemImage: "questionmark.folder",
                    description: Text("Edits are made from the original video, which cannot be reached. The current version keeps playing.")
                )
            }
        }
        .aspectRatio(max(model.asset.pixelSize.width, 1) / max(model.asset.pixelSize.height, 1), contentMode: .fit)
        .frame(maxHeight: 360)
        .frame(maxWidth: .infinity)
    }

    private var loopControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            LoopTimeline(model: model)

            HStack(spacing: 16) {
                Text("Start \(EditorFormat.time(model.selectionStart))")
                Text("End \(EditorFormat.time(model.selectionEnd))")
                Spacer()
                Text("Loop length \(EditorFormat.time(model.resultDuration))")
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Text("Crossfade")
                Slider(
                    value: Binding(
                        get: { model.crossfade },
                        set: { model.setCrossfade($0) }
                    ),
                    in: 0...max(model.maximumCrossfade, 0.1),
                    onEditingChanged: { editing in
                        if !editing { model.rebuildPreview(fromSeam: true) }
                    }
                )
                .accessibilityLabel(Text("Crossfade"))
                .accessibilityValue(Text(EditorFormat.seconds(model.crossfade)))
                Text(EditorFormat.seconds(model.crossfade))
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 52, alignment: .trailing)
            }
            .help(Text("The end of the loop dissolves into its beginning, so the video repeats without a visible jump."))

            HStack(spacing: 12) {
                if model.isSuggesting {
                    ProgressView(value: model.suggestionProgress)
                        .frame(width: 160)
                        .accessibilityLabel(Text("Looking for loop points"))
                    Button("Stop") { model.cancelSuggestion() }
                } else {
                    Button("Suggest") { model.suggest() }
                        .help(Text("Finds the start and end points that match best."))
                }

                Button("Play the seam") { model.rebuildPreview(fromSeam: true) }
                    .help(Text("Plays the last moments of the loop followed by its beginning."))

                if let note = model.suggestionNote {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

enum EditorFormat {
    /// `m:ss.t`
    static func time(_ seconds: TimeInterval) -> String {
        let value = max(0, seconds)
        let minutes = Int(value) / 60
        let rest = value - Double(minutes * 60)
        return String(format: "%d:%04.1f", minutes, rest)
    }

    static func seconds(_ seconds: TimeInterval) -> String {
        Measurement(value: seconds, unit: UnitDuration.seconds)
            .formatted(.measurement(width: .narrow, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(1))))
    }
}

/// The selection on the video's timeline: two handles and, shaded at the
/// end, the part that dissolves into the beginning.
private struct LoopTimeline: View {
    @Bindable var model: AssetEditorModel

    private let handleWidth: CGFloat = 12

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width - handleWidth, 1)
            let duration = max(model.duration, 0.001)
            let startX = CGFloat(model.selectionStart / duration) * width
            let endX = CGFloat(model.selectionEnd / duration) * width
            let fadeWidth = CGFloat(model.crossfade / duration) * width

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.secondary.opacity(0.18))

                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.accentColor.opacity(0.35))
                    .frame(width: max(endX - startX, 0))
                    .offset(x: startX + handleWidth / 2)

                // Both dissolve zones: the head that fades in, the tail it
                // fades over.
                if fadeWidth > 0 {
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.35))
                        .frame(width: fadeWidth)
                        .offset(x: startX + handleWidth / 2)
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.35))
                        .frame(width: fadeWidth)
                        .offset(x: endX + handleWidth / 2 - fadeWidth)
                }

                handle(label: Text("Loop start"), value: model.selectionStart)
                    .offset(x: startX)
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .named("timeline"))
                            .onChanged { model.setStart(Double(($0.location.x - handleWidth / 2) / width) * duration) }
                            .onEnded { _ in model.rebuildPreview(fromSeam: true) }
                    )
                    .accessibilityAdjustableAction { direction in
                        model.setStart(model.selectionStart + (direction == .increment ? 0.1 : -0.1))
                        model.rebuildPreview(fromSeam: true)
                    }

                handle(label: Text("Loop end"), value: model.selectionEnd)
                    .offset(x: endX)
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .named("timeline"))
                            .onChanged { model.setEnd(Double(($0.location.x - handleWidth / 2) / width) * duration) }
                            .onEnded { _ in model.rebuildPreview(fromSeam: true) }
                    )
                    .accessibilityAdjustableAction { direction in
                        model.setEnd(model.selectionEnd + (direction == .increment ? 0.1 : -0.1))
                        model.rebuildPreview(fromSeam: true)
                    }
            }
            .coordinateSpace(name: "timeline")
        }
        .frame(height: 40)
    }

    private func handle(label: Text, value: TimeInterval) -> some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(Color.accentColor)
            .frame(width: handleWidth)
            .overlay {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.white.opacity(0.9))
                    .frame(width: 2, height: 16)
            }
            .contentShape(Rectangle().inset(by: -6))
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityValue(Text(EditorFormat.time(value)))
    }
}

/// Hosts an `AVPlayerLayer`; the editor needs no playback controls.
struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PlayerLayerHostView {
        let view = PlayerLayerHostView()
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ view: PlayerLayerHostView, context: Context) {
        if view.playerLayer.player !== player {
            view.playerLayer.player = player
        }
    }

    static func dismantleNSView(_ view: PlayerLayerHostView, coordinator: ()) {
        view.playerLayer.player = nil
    }
}

final class PlayerLayerHostView: NSView {
    let playerLayer = AVPlayerLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = NSColor.black.cgColor
        layer = playerLayer
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
