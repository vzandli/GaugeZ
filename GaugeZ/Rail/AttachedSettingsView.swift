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
                ForEach(store.providerOrder) { provider in
                    HStack(spacing: 10) {
                        ProviderLogo(provider: provider, size: 14)
                            .frame(width: 18)
                        Text(provider.displayName)
                            .font(.system(size: 12, weight: .medium))
                        Spacer()
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

            settingRow("Show") {
                Picker("Show", selection: $store.displayMode) {
                    ForEach(DisplayMode.allCases) { Text($0.label).tag($0) }
                }
            }

            // Set-once choices (Claude source, surface, notch size) live in the Settings window;
            // the card keeps only what gets flipped in the moment.
            settingRow("Edge") {
                Picker("Edge", selection: $store.edgeSide) {
                    ForEach(EdgeSide.allCases) { Text($0.label).tag($0) }
                }
            }

            indicatorColorBlock

            GlassGroup(enabled: store.glassEnabled) {
                HStack {
                    Button("Refresh", action: store.refresh)
                        .glassControl(enabled: store.glassEnabled)
                    Spacer()
                    Button("Preferences…") {
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

