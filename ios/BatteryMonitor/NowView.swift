import SwiftUI

struct Card<Content: View>: View {
    var title: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title { Text(title).font(.headline) }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }
}

struct KV: View {
    var k: String
    var v: String
    var unit: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(k).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(v).font(.title3.weight(.semibold).monospacedDigit())
                if !unit.isEmpty { Text(unit).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct NowView: View {
    @EnvironmentObject var m: Monitor

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if let r = m.reading {
                    ReadingView(r: r)
                    if let u = m.updated {
                        Text((m.demo ? "Example data · " : "Updated ") + u.formatted(date: .omitted, time: .standard))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } else {
                    Intro()
                }
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Battery")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { ConnectButton() }
        }
        .safeAreaInset(edge: .top) {
            StatusLine().frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20).padding(.vertical, 4)
                .background(.bar)
        }
    }
}

struct Intro: View {
    @EnvironmentObject var m: Monitor

    var body: some View {
        Card {
            Text("This app connects to the battery board (BMS) directly over Bluetooth. No data is sent anywhere.")
            VStack(alignment: .leading, spacing: 6) {
                Text("1. Turn on Bluetooth.")
                Text("2. Disconnect any other apps or pages from the battery: it accepts only one connection at a time.")
                Text("3. Tap “Connect” and choose the device BMS-…")
            }
            Text("Once connected, the app remembers the battery, reconnects to it on its own, and keeps recording while the phone is locked.")
                .font(.footnote).foregroundStyle(.secondary)
            HStack {
                Button("Connect") { m.startScan(showAll: false) }.buttonStyle(.borderedProminent)
                Button("Show example") { m.showExample() }.buttonStyle(.bordered)
            }
        }
    }
}

struct ReadingView: View {
    let r: Reading

    var mode: (String, Color) {
        if abs(r.current) < 0.05 { return ("Idle", .secondary) }
        return r.current > 0 ? ("Charging", Theme.accent) : ("Discharging", Theme.info)
    }

    var socColor: Color { r.soc < 20 ? Theme.bad : r.soc < 40 ? Theme.warn : Theme.accent }

    var body: some View {
        Card {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text("\(r.soc)").font(.system(size: 56, weight: .bold, design: .rounded).monospacedDigit())
                        Text("%").font(.title2).foregroundStyle(.secondary)
                    }
                    Text(mode.0).font(.caption.weight(.semibold))
                        .padding(.horizontal, 10).padding(.vertical, 3)
                        .background(mode.1.opacity(0.15), in: Capsule())
                        .foregroundStyle(mode.1)
                }
                Spacer()
                BatteryGlyph(fraction: Double(r.soc) / 100, color: socColor)
            }
            HStack {
                KV(k: "Voltage", v: Fmt.num(r.voltage, 2), unit: "V")
                KV(k: "Current", v: Fmt.num(r.current, 2), unit: "A")
                KV(k: "Power", v: Fmt.num(r.power.rounded(), 0), unit: "W")
            }
        }

        Card {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 14) {
                GridRow {
                    KV(k: "Remaining", v: Fmt.num(r.remain, 1), unit: "/ \(Fmt.num(r.full, 0)) Ah")
                    eta
                }
                GridRow {
                    KV(k: "Cycles", v: "\(r.cycles)")
                    KV(k: "Health (SOH)", v: "\(r.soh)", unit: "%")
                }
            }
        }

        CellsCard(cells: r.cells)

        Card(title: "Temperature") {
            let temps = r.temps.enumerated().map { ("Sensor \($0.offset + 1)", $0.element) }
                + (r.boardTemp.map { [("Board", $0)] } ?? [])
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), alignment: .leading)], alignment: .leading, spacing: 12) {
                ForEach(temps, id: \.0) { KV(k: $0.0, v: Fmt.num($0.1, 1), unit: "°C") }
            }
        }
    }

    @ViewBuilder var eta: some View {
        if r.current > 0.05 {
            KV(k: "To full", v: Fmt.hours((r.full - r.remain) / r.current))
        } else if r.current < -0.05 {
            KV(k: "To empty", v: Fmt.hours(r.remain / -r.current))
        } else {
            KV(k: "Time", v: "–")
        }
    }
}

struct BatteryGlyph: View {
    var fraction: Double
    var color: Color

    var body: some View {
        HStack(spacing: 2) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 8).stroke(.secondary.opacity(0.5), lineWidth: 2)
                GeometryReader { g in
                    RoundedRectangle(cornerRadius: 5).fill(color)
                        .frame(width: max(0, (g.size.width - 8) * min(1, max(0, fraction))))
                        .padding(4)
                }
            }
            .frame(width: 96, height: 44)
            RoundedRectangle(cornerRadius: 2).fill(.secondary.opacity(0.5)).frame(width: 4, height: 16)
        }
    }
}

struct CellsCard: View {
    let cells: [Double]

    var body: some View {
        let lo = 2.8, hi = 3.65
        let mn = cells.min() ?? 0, mx = cells.max() ?? 0
        let delta = Int(((mx - mn) * 1000).rounded())
        Card(title: "Cells") {
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(Array(cells.enumerated()), id: \.offset) { i, v in
                    let pct = max(0.04, min(1, (v - lo) / (hi - lo)))
                    let tag: Color = cells.count > 1 && v == mn ? Theme.info : cells.count > 1 && v == mx ? Theme.warn : Theme.accent
                    VStack(spacing: 4) {
                        GeometryReader { g in
                            VStack {
                                Spacer(minLength: 0)
                                RoundedRectangle(cornerRadius: 3).fill(tag).frame(height: g.size.height * pct)
                            }
                        }
                        .frame(height: 70)
                        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 3))
                        Text(String(format: "%.3f", v)).font(.system(size: 9).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.7)
                        Text("#\(i + 1)").font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            HStack(spacing: 16) {
                Text("min ").foregroundStyle(.secondary) + Text(String(format: "%.3f V", mn)).bold()
                Text("max ").foregroundStyle(.secondary) + Text(String(format: "%.3f V", mx)).bold()
                Text("difference ").foregroundStyle(.secondary)
                    + Text("\(delta) mV").bold().foregroundColor(delta > 100 ? Theme.bad : delta > 50 ? Theme.warn : .primary)
            }
            .font(.footnote)
        }
    }
}
