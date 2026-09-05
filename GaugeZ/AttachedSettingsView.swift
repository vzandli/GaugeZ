import AppKit
import SwiftUI

// MARK: - Attached settings

struct AttachedSettingsView: View {
    @EnvironmentObject private var store: UsageStore
    let actions: EdgePanelActions

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            GaugeZWordmark(size: 17)

            VStack(spacing: 7) {
                ForEach(ProviderID.allCases) { provider in
                    HStack(spacing: 10) {
                        ProviderLogo(provider: provider, size: 14)
                            .frame(width: 18)
                        Text(provider.displayName)
                            .font(.system(size: 12, weight: .medium))
                        Spacer()
                        Button("Open") { store.open(provider) }
                            .glassControl(enabled: store.glassEnabled)
                            .controlSize(.mini)
                        Toggle(
                            "Enable \(provider.displayName)",
                            isOn: Binding(
                                get: { store.enabledProviders.contains(provider) },
                                set: { store.setProvider(provider, enabled: $0) }
                            )
                        )
                        .labelsHidden()
                        .toggleStyle(RailToggleStyle(glass: store.glassEnabled))
                    }
                }
            }

            settingRow("Claude") {
                Picker("Claude source", selection: $store.claudeSource) {
                    ForEach(ClaudeSource.allCases) { Text($0.label).tag($0) }
                }
            }

            settingRow("Show") {
                Picker("Show", selection: $store.displayMode) {
                    ForEach(DisplayMode.allCases) { Text($0.label).tag($0) }
                }
            }

            // Four edge segments no longer fit beside the style picker in the card width,
            // so the two rows stack; a side-by-side pair overflows and gets clipped.
            settingRow("Edge") {
                Picker("Edge", selection: $store.edgeSide) {
                    ForEach(EdgeSide.allCases) { Text($0.label).tag($0) }
                }
            }

            settingRow("Style") {
                StableStylePicker(
                    isGlassEnabled: store.glassEnabled,
                    onChange: { store.glassEnabled = $0 }
                )
                .equatable()
            }

            if store.glassEnabled {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Glass Transparency")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.55))
                        Spacer()
                        Text("\(Int(round((1.0 - store.glassOpacity) * 100)))%")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.white.opacity(0.55))
                    }
                    Slider(
                        value: Binding(
                            get: { 1.0 - store.glassOpacity },
                            set: { store.glassOpacity = 1.0 - $0 }
                        ),
                        in: 0.0...1.0
                    )
                    .controlSize(.small)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            indicatorColorBlock

            GlassGroup(enabled: store.glassEnabled) {
                HStack {
                    Button("Refresh", action: store.refresh)
                        .glassControl(enabled: store.glassEnabled)
                    Spacer()
                    Button("Diagnostics…") {
                        NotificationCenter.default.post(name: .gaugezOpenSettings, object: nil)
                    }
                    .glassControl(enabled: store.glassEnabled)
                }
                .controlSize(.small)
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .foregroundStyle(.white)
        .frame(width: RailMetrics.attachmentWidth - RailMetrics.pointerDepth)
        .modifier(RailGlass.Surface(
            shape: RoundedRectangle(cornerRadius: 20, style: .continuous),
            glassOpacity: store.glassOpacity,
            tint: RailGlass.panelTint(opacity: store.glassOpacity),
            interactive: false,
            enabled: store.glassEnabled
        ))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("GaugeZ settings")
    }

    private var indicatorColorBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Indicator Color")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.55))
                Spacer()
                HStack(spacing: 2) {
                    ForEach(0..<store.indicatorVariants.count, id: \.self) { idx in
                        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                            .fill(store.indicatorVariants[idx])
                            .frame(width: 5, height: 5)
                    }
                }
                .padding(2)
                .background(
                    RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                        .fill(Color(red: 0.13, green: 0.13, blue: 0.13).opacity(0.92))
                        .overlay(
                            RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
                        )
                )
            }

            IndicatorColorPaletteView()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func settingRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        settingRowBody(title, content: content)
    }

    private func settingRowBody<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.55))
            content()
                .labelsHidden()
                .pickerStyle(.segmented)
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Configure the native segmented control completely before its first layout. SwiftUI's Picker
/// wrapper initially reports a narrower intrinsic width, then expands the first time any bound
/// setting changes. It also redraws its selected segment during every opacity update.
private struct StableStylePicker: NSViewRepresentable, Equatable {
    let isGlassEnabled: Bool
    let onChange: (Bool) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.isGlassEnabled == rhs.isGlassEnabled
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onChange: onChange)
    }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(
            labels: ["Liquid Glass", "Solid"],
            trackingMode: .selectOne,
            target: context.coordinator,
            action: #selector(Coordinator.selectionChanged(_:))
        )
        control.segmentDistribution = .fillEqually
        control.controlSize = .small
        control.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
        control.selectedSegment = isGlassEnabled ? 0 : 1
        control.setAccessibilityLabel("Style")
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.onChange = onChange
        let selectedSegment = isGlassEnabled ? 0 : 1
        if control.selectedSegment != selectedSegment {
            control.selectedSegment = selectedSegment
        }
    }

    final class Coordinator: NSObject {
        var onChange: (Bool) -> Void

        init(onChange: @escaping (Bool) -> Void) {
            self.onChange = onChange
        }

        @objc func selectionChanged(_ sender: NSSegmentedControl) {
            onChange(sender.selectedSegment == 0)
        }
    }
}

struct IndicatorColorPaletteView: View {
    @EnvironmentObject private var store: UsageStore

    private static let presets: [(name: String, hex: String)] = [
        ("Blue", "#407CDE"),
        ("Green", "#2EA44F"),
        ("Purple", "#8B5CF6"),
        ("Amber", "#F59E0B"),
        ("Red", "#EF4444"),
        ("Cyan", "#06B6D4"),
        ("White", "#FFFFFF"),
        ("Black", "#18181B")
    ]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Self.presets, id: \.hex) { preset in
                swatch(hex: preset.hex, name: preset.name)
            }
            customPickerButton
        }
        .onReceive(NotificationCenter.default.publisher(for: NSColorPanel.colorDidChangeNotification)) { _ in
            if NSColorPanel.shared.isVisible {
                store.indicatorColorHex = NSColorPanel.shared.color.hexString
            }
        }
    }

    private func swatch(hex: String, name: String) -> some View {
        let selected = isSelected(hex)
        let isWhite = hex.uppercased() == "#FFFFFF"
        let isBlack = hex.uppercased() == "#18181B" || hex.uppercased() == "#000000"

        return Button {
            store.indicatorColorHex = hex
        } label: {
            ZStack {
                Circle()
                    .fill(Color(hex: hex) ?? .blue)
                    .frame(width: 17, height: 17)
                    .overlay(
                        Circle()
                            .strokeBorder(
                                isWhite ? Color.gray.opacity(0.4) : (isBlack ? Color.white.opacity(0.25) : Color.clear),
                                lineWidth: 1
                            )
                    )
                if selected {
                    Circle()
                        .strokeBorder(Color.white, lineWidth: 2)
                        .frame(width: 21, height: 21)
                }
            }
            .frame(width: 21, height: 21)
        }
        .buttonStyle(.plain)
        .help(name)
    }

    private var customPickerButton: some View {
        let allHexes = Self.presets.map { $0.hex.uppercased() }
        let currentHex = store.indicatorColorHex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let isCustom = !allHexes.contains(currentHex)

        return Button {
            NSApp.activate(ignoringOtherApps: true)
            let panel = NSColorPanel.shared
            panel.level = NSWindow.Level(max(panel.level.rawValue, NSWindow.Level.statusBar.rawValue + 1))
            panel.showsAlpha = false
            panel.isContinuous = true
            panel.color = NSColor(Color(hex: store.indicatorColorHex) ?? .blue)
            panel.makeKeyAndOrderFront(nil)
        } label: {
            ZStack {
                Circle()
                    .fill(
                        AngularGradient(
                            gradient: Gradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red]),
                            center: .center
                        )
                    )
                    .frame(width: 17, height: 17)
                if isCustom {
                    Circle()
                        .strokeBorder(Color.white, lineWidth: 2)
                        .frame(width: 21, height: 21)
                }
            }
            .frame(width: 21, height: 21)
        }
        .buttonStyle(.plain)
        .help("Custom color…")
    }

    private func isSelected(_ hex: String) -> Bool {
        store.indicatorColorHex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == hex.uppercased()
    }
}

/// Switch that keeps its colour in a panel that never becomes the key window, where the
/// system switch would draw as inactive gray, styled with subtle glass depth when enabled.
///
/// Also used in the settings window instead of `.toggleStyle(.switch)`: on macOS 26 a single
/// native switch transiently allocates ~200 MB of graphics memory when its window opens
/// (measured with `heap`), while this style costs nothing measurable.
struct RailToggleStyle: ToggleStyle {
    var glass: Bool = true
    var onColor = Color(red: 0.18, green: 0.82, blue: 0.38)
    var width: CGFloat = 30
    var height: CGFloat = 18

    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule()
                    .fill(
                        configuration.isOn
                            ? onColor
                            : (glass ? Color.white.opacity(0.14) : Color.white.opacity(0.18))
                    )
                    .overlay(
                        Capsule()
                            .strokeBorder(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(glass ? 0.32 : 0.18),
                                        Color.white.opacity(glass ? 0.08 : 0.04)
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                ),
                                lineWidth: 0.5
                            )
                    )
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.3), radius: 1, y: 0.5)
                    .padding(2)
            }
            .frame(width: width, height: height)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.16), value: configuration.isOn)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
        }
    }
}

