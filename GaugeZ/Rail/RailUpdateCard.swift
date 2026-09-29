import SwiftUI

/// **A new version, offered on the rail** instead of in an alert nobody asked for: Update
/// hands it to the updater to download and install, Later puts it off for this version and
/// leaves a red dot on the settings button to come back to it.
struct RailUpdateCard: View {
    @EnvironmentObject private var store: UsageStore
    @EnvironmentObject private var updates: UpdateManager
    let actions: EdgePanelActions

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Color(red: 0.27, green: 0.58, blue: 1.0))
                VStack(alignment: .leading, spacing: 3) {
                    Text("GaugeZ \(updates.pendingUpdateVersion ?? "") is ready")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Install it now, or later from the settings button.")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.65))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            ButtonPairRow(spacing: 10) {
                Button("Later") { actions.updateChosen(false) }
                    .glassControl(enabled: store.glassEnabled)
                Button("Update") { actions.updateChosen(true) }
                    .glassControl(enabled: store.glassEnabled)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .foregroundStyle(.white)
        .frame(width: RailMetrics.attachmentWidth - RailMetrics.pointerDepth)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Update available"))
    }
}
