import Foundation
import SQLite3

struct Sample: Identifiable, Equatable {
    var t: Date
    var soc: Int
    var v: Double
    var i: Double
    var p: Int
    var cells: [Double]
    var temps: [Double]
    var board: Double?
    var id: Date { t }

    var cellMin: Double? { cells.min() }
    var cellMax: Double? { cells.max() }
}

/// Readings kept on this phone only, in a small SQLite file, for 30 days.
final class HistoryStore {
    static let keep: TimeInterval = 30 * 24 * 3600
    private var db: OpaquePointer?
    private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("history.sqlite")
        // readable while the phone is locked, so background recording keeps working
        if sqlite3_open_v2(url.path, &db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FILEPROTECTION_NONE, nil) != SQLITE_OK {
            db = nil
            return
        }
        try? (url as NSURL).setResourceValue(URLFileProtection.none, forKey: .fileProtectionKey)
        exec("PRAGMA journal_mode=WAL")
        exec("""
            CREATE TABLE IF NOT EXISTS samples (
              t REAL PRIMARY KEY, soc INTEGER, v REAL, i REAL, p INTEGER,
              cells TEXT, temps TEXT, board REAL)
            """)
        prune()
    }

    deinit { sqlite3_close(db) }

    private func exec(_ sql: String) {
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    private static func encode(_ a: [Double]) -> String {
        a.map { String($0) }.joined(separator: ",")
    }

    private static func decode(_ s: String) -> [Double] {
        s.isEmpty ? [] : s.split(separator: ",").compactMap { Double($0) }
    }

    func add(_ s: Sample) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO samples VALUES (?,?,?,?,?,?,?,?)", -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, s.t.timeIntervalSince1970)
        sqlite3_bind_int(stmt, 2, Int32(s.soc))
        sqlite3_bind_double(stmt, 3, s.v)
        sqlite3_bind_double(stmt, 4, s.i)
        sqlite3_bind_int(stmt, 5, Int32(s.p))
        sqlite3_bind_text(stmt, 6, Self.encode(s.cells), -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 7, Self.encode(s.temps), -1, SQLITE_TRANSIENT)
        if let b = s.board { sqlite3_bind_double(stmt, 8, b) } else { sqlite3_bind_null(stmt, 8) }
        sqlite3_step(stmt)
    }

    func load(from: Date?) -> [Sample] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT t,soc,v,i,p,cells,temps,board FROM samples WHERE t >= ? ORDER BY t", -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, from?.timeIntervalSince1970 ?? 0)
        var out: [Sample] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let text = { (col: Int32) -> String in
                guard let p = sqlite3_column_text(stmt, col) else { return "" }
                return String(cString: p)
            }
            out.append(Sample(
                t: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 0)),
                soc: Int(sqlite3_column_int(stmt, 1)),
                v: sqlite3_column_double(stmt, 2),
                i: sqlite3_column_double(stmt, 3),
                p: Int(sqlite3_column_int(stmt, 4)),
                cells: Self.decode(text(5)),
                temps: Self.decode(text(6)),
                board: sqlite3_column_type(stmt, 7) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 7)))
        }
        return out
    }

    func count() -> Int {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM samples", -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : 0
    }

    func clear() { exec("DELETE FROM samples") }

    func prune() {
        exec("DELETE FROM samples WHERE t < \(Date().addingTimeInterval(-Self.keep).timeIntervalSince1970)")
    }
}

enum CSV {
    static func make(_ recs: [Sample]) -> String {
        let nC = recs.map(\.cells.count).max() ?? 0
        let nT = recs.map(\.temps.count).max() ?? 0
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_GB")
        df.dateFormat = "dd/MM/yyyy, HH:mm:ss"
        var head = ["time", "charge_%", "voltage_V", "current_A", "power_W"]
        head += (0..<nC).map { "cell\($0 + 1)_V" }
        head += (0..<nT).map { "sensor\($0 + 1)_C" }
        head.append("board_C")
        var lines = [head.joined(separator: ",")]
        for r in recs {
            var row = ["\"\(df.string(from: r.t))\"", "\(r.soc)", "\(r.v)", "\(r.i)", "\(r.p)"]
            row += (0..<nC).map { $0 < r.cells.count ? "\(r.cells[$0])" : "" }
            row += (0..<nT).map { $0 < r.temps.count ? "\(r.temps[$0])" : "" }
            row.append(r.board.map { "\($0)" } ?? "")
            lines.append(row.joined(separator: ","))
        }
        return "\u{FEFF}" + lines.joined(separator: "\r\n")
    }
}

enum Demo {
    /// Made-up two days with solar charging by day and household load at night
    static func history() -> [Sample] {
        var out: [Sample] = []
        let step: TimeInterval = 30
        let now = Date().timeIntervalSince1970
        var soc = 80.0
        let cal = Calendar.current
        var t = now - 48 * 3600
        while t <= now {
            let d = Date(timeIntervalSince1970: t)
            let h = Double(cal.component(.hour, from: d)) + Double(cal.component(.minute, from: d)) / 60
            let sun = max(0, sin((h - 7) / 12 * .pi))
            let load = 90 + (h > 18 && h < 23 ? 260 : 0) + 30 * sin(t * 1000 / 7e5)
            var p = sun * 1500 - load
            if (soc >= 100 && p > 0) || (soc <= 5 && p < 0) { p = 0 }
            soc = min(100, max(5, soc + (p * step) / 3600 / 2650 * 100))
            let i = p / 26.5, v = 25.4 + soc * 0.016 + i * 0.01
            let cells = [0.004, 0.001, -0.002, -0.009, 0.001, -0.002, -0.001, 0.001]
                .map { ((v / 8 + $0 * (1 + abs(i) / 40)) * 1000).rounded() / 1000 }
            let temp = 19 + 2 * sin((h - 9) / 24 * 2 * .pi) + abs(i) / 30
            let r1 = { (x: Double) in (x * 10).rounded() / 10 }
            out.append(Sample(t: d, soc: Int(soc.rounded()), v: (v * 100).rounded() / 100, i: (i * 100).rounded() / 100,
                              p: Int(p.rounded()), cells: cells, temps: [r1(temp), r1(temp + 0.3)],
                              board: r1(temp + 1.5 + abs(i) / 20)))
            t += step
        }
        return out
    }
}
