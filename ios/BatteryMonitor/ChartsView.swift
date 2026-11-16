import SwiftUI
import Charts

struct ChartDef: Identifiable {
    struct Series { var name: String; var key: (Sample) -> Double? }
    var title: String
    var unit: String
    var digits: Int
    var fixed: ClosedRange<Double>? = nil
    var zero = false
    var sub: String? = nil
    var series: [Series]
    var id: String { title }

    static func all(for recs: [Sample]) -> [ChartDef] {
        let nT = recs.map(\.temps.count).max() ?? 0
        var temps: [Series] = (0..<nT).map { i in
            Series(name: "Sensor \(i + 1)") { i < $0.temps.count ? $0.temps[i] : nil }
        }
        if recs.contains(where: { $0.board != nil }) { temps.append(Series(name: "Board") { $0.board }) }
        return [
            ChartDef(title: "Charge", unit: "%", digits: 0, fixed: 0...100, series: [Series(name: "Charge") { Double($0.soc) }]),
            ChartDef(title: "Power", unit: "W", digits: 0, zero: true, sub: "above zero = charging, below = discharging",
                     series: [Series(name: "Power") { Double($0.p) }]),
            ChartDef(title: "Voltage", unit: "V", digits: 2, series: [Series(name: "Voltage") { $0.v }]),
            ChartDef(title: "Cells", unit: "V", digits: 3, sub: "highest and lowest cell",
                     series: [Series(name: "max") { $0.cellMax }, Series(name: "min") { $0.cellMin }]),
            ChartDef(title: "Temperature", unit: "°C", digits: 1, series: Array(temps.prefix(3))),
        ]
    }
}

/// One averaged point per bucket, so long periods stay light.
struct Point: Identifiable {
    var t: Date
    var v: [Double?]
    var id: Date { t }
}

func bucketize(_ recs: [Sample], _ def: ChartDef, from: Date, to: Date, n: Int) -> [Point] {
    let span = max(1, to.timeIntervalSince(from))
    let bw = span / Double(n)
    var buckets: [Int: (t: Double, n: Int, s: [(Double, Int)])] = [:]
    for r in recs {
        let k = min(n - 1, max(0, Int(r.t.timeIntervalSince(from) / bw)))
        var b = buckets[k] ?? (0, 0, Array(repeating: (0, 0), count: def.series.count))
        b.t += r.t.timeIntervalSince1970
        b.n += 1
        for (i, s) in def.series.enumerated() {
            if let v = s.key(r), v.isFinite { b.s[i].0 += v; b.s[i].1 += 1 }
        }
        buckets[k] = b
    }
    return buckets.keys.sorted().map { k in
        let b = buckets[k]!
        return Point(t: Date(timeIntervalSince1970: b.t / Double(b.n)), v: b.s.map { $0.1 > 0 ? $0.0 / Double($0.1) : nil })
    }
}

struct ChartsView: View {
    @EnvironmentObject var m: Monitor
    @State private var period: TimeInterval = 24 * 3600
    @State private var recs: [Sample] = []
    @State private var confirmClear = false

    static let periods: [(String, TimeInterval)] = [("1 h", 3600), ("6 h", 6 * 3600), ("24 h", 24 * 3600), ("7 d", 7 * 24 * 3600), ("All", 0)]

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Picker("Period", selection: $period) {
                    ForEach(Self.periods, id: \.1) { Text($0.0).tag($0.1) }
                }
                .pickerStyle(.segmented)

                HStack(spacing: 6) {
                    Circle().fill(m.connected && !m.demo ? Theme.accent : Color.secondary.opacity(0.5)).frame(width: 8, height: 8)
                    Text(m.demo ? "Example: made-up data for 2 days"
                         : m.connected ? "Recording every 10 seconds, also when the phone is locked"
                         : "Recording happens while the app is connected to the battery")
                        .font(.footnote).foregroundStyle(.secondary)
                    Spacer()
                }

                if recs.count < 2 {
                    Card {
                        Text("No records for this period yet.")
                        Text("Connect to the battery: while connected, readings are recorded every 10 seconds, even in the background, and kept on this phone for 30 days. To see what the charts look like, tap “Show example” on the Now tab.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } else {
                    let to = Date()
                    let from = period > 0 ? to.addingTimeInterval(-period) : recs[0].t
                    ForEach(ChartDef.all(for: recs).filter { !$0.series.isEmpty }) { def in
                        ChartCard(def: def, recs: recs, from: from, to: to)
                    }
                    Card {
                        HStack {
                            ShareLink(item: CSVFile(recs: recs), preview: SharePreview(CSVFile.name)) {
                                Label("Export CSV", systemImage: "square.and.arrow.up")
                            }
                            .buttonStyle(.bordered)
                            Spacer()
                            Button("Clear history", role: .destructive) { confirmClear = true }
                                .buttonStyle(.bordered)
                                .disabled(m.demo)
                        }
                        Text("\(recs.count) records in this period").font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Charts")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { ConnectButton() } }
        .confirmationDialog("Delete all recorded history on this phone?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Delete history", role: .destructive) { m.clearHistory() }
        }
        .onAppear(perform: load)
        .onChange(of: period) { load() }
        .onChange(of: m.historyVersion) { load() }
        .onChange(of: m.demo) { load() }
    }

    private func load() {
        let from = period > 0 ? Date().addingTimeInterval(-period) : nil
        if m.demo {
            recs = Demo.history().filter { from == nil || $0.t >= from! }
        } else {
            recs = m.store.load(from: from)
        }
    }
}

struct CSVFile: Transferable {
    var recs: [Sample]
    static var name: String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        return "battery-\(f.string(from: Date())).csv"
    }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .commaSeparatedText) { file in
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
            try CSV.make(file.recs).write(to: url, atomically: true, encoding: .utf8)
            return SentTransferredFile(url)
        }
    }
}

struct ChartCard: View {
    let def: ChartDef
    let recs: [Sample]
    let from: Date
    let to: Date
    @State private var selected: Date?

    var body: some View {
        let pts = bucketize(recs, def, from: from, to: to, n: 160)
        let span = to.timeIntervalSince(from)
        let gap = max(span / 160 * 2.5, Monitor.recordEvery * 6)
        let segs = segments(pts, gap: gap)
        let multi = def.series.count > 1
        let last = recs.last.flatMap { def.series[0].key($0) }

        Card {
            HStack(alignment: .firstTextBaseline) {
                Text("\(def.title), \(def.unit)").font(.headline)
                Spacer()
                if !multi, let last { Text("\(Fmt.num(last, def.digits)) \(def.unit)").font(.headline.monospacedDigit()) }
            }
            if let sub = def.sub { Text(sub).font(.caption).foregroundStyle(.secondary) }
            if multi {
                HStack(spacing: 12) {
                    ForEach(Array(def.series.enumerated()), id: \.offset) { i, s in
                        HStack(spacing: 4) {
                            RoundedRectangle(cornerRadius: 2).fill(Theme.series[i % 3]).frame(width: 10, height: 10)
                            Text(s.name).font(.caption)
                        }
                    }
                }
            }
            Chart {
                if def.zero {
                    RuleMark(y: .value("zero", 0)).foregroundStyle(.secondary.opacity(0.7)).lineStyle(StrokeStyle(lineWidth: 1))
                }
                ForEach(segs, id: \.id) { seg in
                    ForEach(seg.points, id: \.t) { p in
                        LineMark(x: .value("Time", p.t), y: .value(def.unit, p.v), series: .value("segment", seg.id))
                            .foregroundStyle(Theme.series[seg.series % 3])
                            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    }
                }
                if let sel = selected, let p = nearest(pts, sel) {
                    RuleMark(x: .value("Selected", p.t))
                        .foregroundStyle(.secondary)
                        .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                            Tooltip(def: def, p: p)
                        }
                    ForEach(Array(p.v.enumerated()), id: \.offset) { i, v in
                        if let v {
                            PointMark(x: .value("Time", p.t), y: .value(def.unit, v))
                                .foregroundStyle(Theme.series[i % 3])
                        }
                    }
                }
            }
            .chartXScale(domain: from...to)
            .chartYScale(domain: yDomain(pts), range: .plotDimension(padding: 4))
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { v in
                    AxisGridLine()
                    AxisValueLabel(format: span > 36 * 3600 ? .dateTime.day().month(.twoDigits) : .dateTime.hour(.twoDigits(amPM: .omitted)).minute())
                }
            }
            .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) }
            .chartXSelection(value: $selected)
            .frame(height: 170)
        }
    }

    struct XY { var t: Date; var v: Double }
    struct Segment { var id: String; var series: Int; var points: [XY] }

    /// lines break where there is a gap in the recording
    private func segments(_ pts: [Point], gap: TimeInterval) -> [Segment] {
        var out: [Segment] = []
        for i in def.series.indices {
            var cur: [XY] = []
            var n = 0
            for p in pts {
                guard let v = p.v[i] else { continue }
                if let prev = cur.last, p.t.timeIntervalSince(prev.t) > gap {
                    out.append(Segment(id: "\(i)-\(n)", series: i, points: cur)); n += 1; cur = []
                }
                cur.append(XY(t: p.t, v: v))
            }
            if !cur.isEmpty { out.append(Segment(id: "\(i)-\(n)", series: i, points: cur)) }
        }
        return out
    }

    private func yDomain(_ pts: [Point]) -> ClosedRange<Double> {
        let vals = pts.flatMap { $0.v.compactMap { $0 } }
        var lo = vals.min() ?? 0, hi = vals.max() ?? 1
        if let f = def.fixed { lo = min(lo, f.lowerBound); hi = max(hi, f.upperBound) }
        if def.zero { lo = min(lo, 0); hi = max(hi, 0) }
        let minSpan = 5 * pow(10, -Double(def.digits))
        if hi - lo < minSpan { let m = (hi + lo) / 2; lo = m - minSpan / 2; hi = m + minSpan / 2 }
        let pad = (hi - lo) * 0.05
        return def.fixed != nil && lo >= def.fixed!.lowerBound && hi <= def.fixed!.upperBound ? lo...hi : (lo - pad)...(hi + pad)
    }

    private func nearest(_ pts: [Point], _ t: Date) -> Point? {
        pts.min { abs($0.t.timeIntervalSince(t)) < abs($1.t.timeIntervalSince(t)) }
    }
}

struct Tooltip: View {
    let def: ChartDef
    let p: Point

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(p.t.formatted(.dateTime.day().month(.twoDigits).hour().minute())).font(.caption2).foregroundStyle(.secondary)
            ForEach(Array(def.series.enumerated()), id: \.offset) { i, s in
                if let v = p.v[i] {
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 2).fill(Theme.series[i % 3]).frame(width: 8, height: 8)
                        Text("\(Fmt.num(v, def.digits)) \(def.unit)").font(.caption.bold().monospacedDigit())
                        if def.series.count > 1 { Text(s.name).font(.caption) }
                    }
                }
            }
        }
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}
