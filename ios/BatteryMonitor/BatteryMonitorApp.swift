import SwiftUI

@main
struct BatteryMonitorApp: App {
    @StateObject private var monitor = Monitor()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(monitor)
                .tint(Theme.accent)
        }
    }
}

enum Theme {
    static let accent = Color(light: 0x13A36B, dark: 0x2FCF8C)
    static let warn = Color(light: 0xD98A12, dark: 0xF0A531)
    static let bad = Color(light: 0xD6453D, dark: 0xF06A61)
    static let info = Color(light: 0x2F7FD1, dark: 0x5AA6F0)
    static let series = [Color(light: 0x2A78D6, dark: 0x3987E5),
                         Color(light: 0xEB6834, dark: 0xD95926),
                         Color(light: 0x1BAF7A, dark: 0x199E70)]
}

extension Color {
    init(light: UInt32, dark: UInt32) {
        self.init(UIColor { tc in
            let v = tc.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                           blue: CGFloat(v & 0xFF) / 255, alpha: 1)
        })
    }
}

enum Fmt {
    static func num(_ n: Double, _ d: Int) -> String {
        n.formatted(.number.precision(.fractionLength(d)).locale(Locale(identifier: "en_GB")))
    }

    static func hours(_ h: Double) -> String {
        guard h.isFinite, h > 0 else { return "–" }
        if h > 99 { return "> 99 h" }
        var hh = Int(h)
        var mm = Int(((h - Double(hh)) * 60).rounded())
        if mm == 60 { hh += 1; mm = 0 }
        return "\(hh) h \(String(format: "%02d", mm)) min"
    }
}
