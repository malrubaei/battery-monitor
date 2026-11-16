import SwiftUI

struct ContentView: View {
    @EnvironmentObject var m: Monitor

    var body: some View {
        TabView {
            NavigationStack { NowView() }
                .tabItem { Label("Now", systemImage: "battery.100percent.bolt") }
            NavigationStack { ChartsView() }
                .tabItem { Label("Charts", systemImage: "chart.xyaxis.line") }
        }
        .sheet(isPresented: Binding(get: { m.scanning }, set: { if !$0 { m.stopScan() } })) {
            DevicePicker()
        }
    }
}

struct StatusLine: View {
    @EnvironmentObject var m: Monitor

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(m.statusText).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
        }
    }

    var color: Color {
        switch m.statusKind {
        case .on: return Theme.accent
        case .err: return Theme.bad
        case .none: return .secondary.opacity(0.5)
        }
    }
}

struct ConnectButton: View {
    @EnvironmentObject var m: Monitor

    var body: some View {
        if m.connected || m.hasSavedDevice && !m.demo {
            Button("Disconnect") { m.disconnect() }
        } else {
            Button("Connect") { m.startScan(showAll: false) }.bold()
        }
    }
}

struct DevicePicker: View {
    @EnvironmentObject var m: Monitor

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if m.found.isEmpty {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text(m.showAll ? "Looking for Bluetooth devices…" : "Looking for the battery…")
                                .foregroundStyle(.secondary)
                        }
                    }
                    ForEach(m.found) { d in
                        Button { m.choose(d) } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(d.name ?? "Unnamed device").foregroundStyle(.primary)
                                    if d.looksLikeBMS {
                                        Text("Battery board").font(.caption).foregroundStyle(Theme.accent)
                                    }
                                }
                                Spacer()
                                Text("\(d.rssi) dBm").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                    }
                } footer: {
                    if m.showAll {
                        Text("All nearby Bluetooth devices are shown. Choose the battery: usually it is named BMS-…, or it is an unnamed device or the one with the strongest signal.")
                    } else {
                        Text("The battery accepts only one connection at a time, so close the web page or any other app connected to it first.")
                    }
                }
                if !m.showAll {
                    Section {
                        Button("Battery not in the list") { m.startScan(showAll: true) }
                    }
                }
            }
            .navigationTitle("Choose battery")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { m.stopScan() } }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
