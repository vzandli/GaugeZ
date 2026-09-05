import SwiftUI

/// A regular, focusable window for keyboard and assistive-technology users.
struct UsageOverviewView: View {
    @ObservedObject var store: UsageStore
    @State private var selected = ProviderID.claude

    var body: some View {
        VStack(spacing: 12) {
            Picker("Provider", selection: $selected) {
                ForEach(store.visibleProviders) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal)
            if store.visibleProviders.isEmpty {
                ContentUnavailableView("No providers enabled", systemImage: "gauge.with.dots.needle.0percent",
                                       description: Text("Enable a provider in GaugeZ Settings."))
            } else {
                ScrollView {
                    UsageDetailCard(snapshot: store.snapshot(for: selected), openProvider: { store.open(selected) })
                        .padding(10)
                }
            }
        }
        .padding(.vertical)
        .frame(minWidth: 420, minHeight: 480)
        .environmentObject(store)
        .preferredColorScheme(.dark)
        .onAppear { selectAvailableProvider() }
        .onChange(of: store.visibleProviders) { selectAvailableProvider() }
    }

    private func selectAvailableProvider() {
        if !store.visibleProviders.contains(selected), let first = store.visibleProviders.first { selected = first }
    }
}
