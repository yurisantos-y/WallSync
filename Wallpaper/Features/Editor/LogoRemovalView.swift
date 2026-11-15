import SwiftUI

extension WatermarkStrategy {
    var localizedLabel: String {
        switch self {
        case .reframe: return String(localized: "Reframed: the logo is outside the picture")
        case .unblend: return String(localized: "Translucent logo un-mixed")
        case .temporal: return String(localized: "Filled from neighboring frames")
        case .spatial: return String(localized: "Filled from the surroundings")
        }
    }
}

/// The "logo" page of the editor: mark the areas, see a comparison, apply.
struct LogoRemovalView: View {
    @Bindable var model: AssetEditorModel
    @State private var draft: CGRect?
    @State private var comparisonIndex = 0
    @State private var showsAfter = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.comparison.isEmpty {
                canvas
                Text("Drag over each logo, date stamp or fixed text to mark it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                comparisonView
            }

            HStack(spacing: 12) {
                if model.isAnalyzing {
                    ProgressView(value: model.analysisProgress)
                        .frame(width: 160)
                        .accessibilityLabel(Text("Analyzing the video"))
                    Button("Stop") { model.cancelAnalysis() }
                } else if model.comparison.isEmpty {
                    Button("Suggest") { model.detectLogos() }
                        .help(Text("Looks for areas that stay the same while the rest of the video changes."))
                    Button("Compare before and after") { model.compare() }
                        .disabled(model.regions.isEmpty)
                } else {
                    Button("Edit areas") { model.clearComparison() }
                }

                if let note = model.logoNote {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let offer = model.reframeOffer {
                HStack(spacing: 10) {
                    Image(systemName: "crop")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text("Zooming in slightly puts the logo outside the picture, with nothing filled in. It gives up \(Int((offer.areaLoss * 100).rounded()))% of the picture.")
                        .font(.caption)
                    Button("Reframe instead") { model.acceptReframe() }
                        .controlSize(.small)
                }
            } else if model.crop != nil {
                HStack(spacing: 10) {
                    Text(WatermarkStrategy.reframe.localizedLabel)
                        .font(.caption)
                    Button("Undo reframing") { model.clearReframe() }
                        .controlSize(.small)
                }
            }

            Text("Use this only with videos you have the right to use and modify.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Marking

    private var aspect: CGFloat {
        max(model.asset.pixelSize.width, 1) / max(model.asset.pixelSize.height, 1)
    }

    private var canvas: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack(alignment: .topLeading) {
                if let image = model.stillImage {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .frame(width: size.width, height: size.height)
                } else {
                    Color.black
                    ProgressView()
                        .frame(width: size.width, height: size.height)
                }

                if let crop = model.crop {
                    // Everything outside the reframed picture is dimmed.
                    Path { path in
                        path.addRect(CGRect(origin: .zero, size: size))
                        path.addRect(scaled(crop, to: size))
                    }
                    .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
                    .allowsHitTesting(false)
                }

                ForEach(Array(model.regions.enumerated()), id: \.offset) { index, region in
                    let frame = scaled(region, to: size)
                    Rectangle()
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                        .background(Color.accentColor.opacity(0.18))
                        .frame(width: frame.width, height: frame.height)
                        .offset(x: frame.minX, y: frame.minY)
                        .allowsHitTesting(false)

                    Button {
                        model.removeRegion(at: index)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .offset(x: min(frame.maxX - 8, size.width - 18), y: max(frame.minY - 10, 0))
                    .accessibilityLabel(Text("Remove marked area \(index + 1)"))
                }

                if let draft {
                    let frame = scaled(draft, to: size)
                    Rectangle()
                        .strokeBorder(Color.white, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                        .frame(width: frame.width, height: frame.height)
                        .offset(x: frame.minX, y: frame.minY)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 3)
                    .onChanged { value in
                        draft = CGRect(
                            x: min(value.startLocation.x, value.location.x) / size.width,
                            y: min(value.startLocation.y, value.location.y) / size.height,
                            width: abs(value.location.x - value.startLocation.x) / size.width,
                            height: abs(value.location.y - value.startLocation.y) / size.height
                        )
                    }
                    .onEnded { _ in
                        if let draft { model.addRegion(draft) }
                        draft = nil
                    }
            )
        }
        .aspectRatio(aspect, contentMode: .fit)
        .frame(maxHeight: 360)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("A frame of the video. Drag to mark a logo."))
    }

    private func scaled(_ rect: CGRect, to size: CGSize) -> CGRect {
        CGRect(x: rect.minX * size.width, y: rect.minY * size.height, width: rect.width * size.width, height: rect.height * size.height)
    }

    // MARK: - Comparison

    private var comparisonView: some View {
        let pairs = model.comparison
        let pair = pairs[min(comparisonIndex, pairs.count - 1)]

        return VStack(alignment: .leading, spacing: 10) {
            Image(decorative: showsAfter ? pair.after : pair.before, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxHeight: 360)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityLabel(showsAfter ? Text("The frame after removal") : Text("The frame before removal"))

            HStack(spacing: 12) {
                Picker("Version", selection: $showsAfter) {
                    Text("Before").tag(false)
                    Text("After").tag(true)
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .labelsHidden()
                .accessibilityLabel(Text("Version"))

                if pairs.count > 1 {
                    Picker("Moment", selection: $comparisonIndex) {
                        ForEach(pairs.indices, id: \.self) { index in
                            Text(EditorFormat.time(pairs[index].time)).tag(index)
                        }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                    .labelsHidden()
                    .accessibilityLabel(Text("Moment"))
                }

                Spacer()
            }

            if !model.comparisonStrategies.isEmpty {
                let labels = Set(model.comparisonStrategies).sorted { $0.rawValue < $1.rawValue }.map(\.localizedLabel)
                Text("Method: \(labels.joined(separator: ", "))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
