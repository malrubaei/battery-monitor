import Foundation
import CoreBluetooth

/// The BMS sits behind a Nations BLE UART module and speaks Modbus RTU
/// (slave 1, function 03 "read holding registers") over it.
enum BMS {
    static let service = CBUUID(string: "00002760-08C2-11E1-9073-0E8AC72E1001")
    static let txChar = CBUUID(string: "00002760-08C2-11E1-9073-0E8AC72E0001")
    static let rxChar = CBUUID(string: "00002760-08C2-11E1-9073-0E8AC72E0002")
    static let slave: UInt8 = 1

    static func crc16(_ bytes: some Sequence<UInt8>) -> UInt16 {
        var crc: UInt16 = 0xFFFF
        for b in bytes {
            crc ^= UInt16(b)
            for _ in 0..<8 {
                crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xA001 : crc >> 1
            }
        }
        return crc
    }

    static func readRequest(register reg: UInt16, count: UInt16) -> Data {
        var f: [UInt8] = [slave, 0x03, UInt8(reg >> 8), UInt8(reg & 0xFF), UInt8(count >> 8), UInt8(count & 0xFF)]
        let c = crc16(f)
        f += [UInt8(c & 0xFF), UInt8(c >> 8)]
        return Data(f)
    }

    enum Frame {
        case registers([UInt16])
        case exception(UInt8)
        case badChecksum
    }

    /// Responses can arrive split across several notifications, so bytes are
    /// accumulated and complete frames are taken off the front of the buffer.
    static func takeFrame(from buf: inout [UInt8]) -> Frame? {
        while buf.count >= 5 {
            if buf[0] != slave || (buf[1] != 0x03 && buf[1] != 0x83) {
                buf.removeFirst()
                continue
            }
            let len = buf[1] == 0x83 ? 5 : 5 + Int(buf[2])
            if buf.count < len { return nil }
            let frame = Array(buf[0..<len])
            buf.removeFirst(len)
            let crc = UInt16(frame[len - 2]) | (UInt16(frame[len - 1]) << 8)
            guard crc16(frame[0..<(len - 2)]) == crc else { return .badChecksum }
            if frame[1] == 0x83 { return .exception(frame[2]) }
            var regs: [UInt16] = []
            var i = 3
            while i < len - 2 {
                regs.append((UInt16(frame[i]) << 8) | UInt16(frame[i + 1]))
                i += 2
            }
            return .registers(regs)
        }
        return nil
    }

    static func s16(_ v: UInt16) -> Double { Double(Int16(bitPattern: v)) }
}

struct Reading: Equatable {
    var current: Double      // A, positive = charging
    var voltage: Double      // V
    var soc: Int             // %
    var soh: Int             // %
    var remain: Double       // Ah
    var full: Double         // Ah
    var cycles: Int
    var cells: [Double]      // V
    var temps: [Double]      // °C
    var boardTemp: Double?   // °C

    var power: Double { voltage * current }

    /// a = registers 0..15, c = 15..31, t = 46..56, extra = 57
    init(a: [UInt16], c: [UInt16], t: [UInt16], extra: UInt16?) throws {
        guard a.count >= 8, !c.isEmpty, !t.isEmpty else { throw BMSError.shortResponse }
        current = BMS.s16(a[0]) / 100
        voltage = Double(a[1]) / 100
        soc = Int(a[2])
        soh = Int(a[3])
        remain = Double(a[4]) / 100
        full = Double(a[5]) / 100
        cycles = Int(a[7])
        let nCells = min(Int(c[0]), 16, c.count - 1)
        cells = c[1..<(1 + max(0, nCells))].map { Double($0) / 1000 }
        let nTemps = min(Int(t[0]), 10, t.count - 1)
        temps = t[1..<(1 + max(0, nTemps))].map { BMS.s16($0) / 10 }
        if let e = extra, e != 0xFFFF { boardTemp = BMS.s16(e) / 10 } else { boardTemp = nil }
    }

    init(current: Double, voltage: Double, soc: Int, soh: Int, remain: Double, full: Double,
         cycles: Int, cells: [Double], temps: [Double], boardTemp: Double?) {
        self.current = current; self.voltage = voltage; self.soc = soc; self.soh = soh
        self.remain = remain; self.full = full; self.cycles = cycles
        self.cells = cells; self.temps = temps; self.boardTemp = boardTemp
    }

    /// Values read from the real battery on 2026-10-28
    static let example = Reading(
        current: 0, voltage: 27.4, soc: 100, soh: 100, remain: 99.91, full: 100, cycles: 2,
        cells: [3.438, 3.431, 3.422, 3.407, 3.431, 3.422, 3.424, 3.431],
        temps: [20.0, 20.2], boardTemp: 21.7)
}

enum BMSError: LocalizedError {
    case timeout, badChecksum, rejected(UInt8), shortResponse, notConnected
    var errorDescription: String? {
        switch self {
        case .timeout: return "No response from BMS"
        case .badChecksum: return "Checksum error"
        case .rejected(let code): return "BMS rejected the request, code \(code)"
        case .shortResponse: return "Unexpected response from BMS"
        case .notConnected: return "Not connected"
        }
    }
}
