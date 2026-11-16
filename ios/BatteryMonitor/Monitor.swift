import Foundation
import CoreBluetooth
import UIKit

struct FoundDevice: Identifiable {
    let peripheral: CBPeripheral
    var name: String?
    var rssi: Int
    var looksLikeBMS: Bool
    var id: UUID { peripheral.identifier }
}

/// Talks to the BMS over CoreBluetooth, polls it, and records readings.
///
/// Background recording: the app declares the `bluetooth-central` background mode,
/// so iOS keeps the connection open and wakes the app for every notification.
/// Each poll's response wakes the app and starts a short background task that
/// covers the wait until the next poll, so the poll chain keeps going while the
/// phone is locked. If iOS ends the task early, a request is sent anyway: its
/// response wakes the app again and the chain continues.
@MainActor
final class Monitor: NSObject, ObservableObject {
    enum StatusKind { case none, on, err }

    @Published var statusText = "Not connected"
    @Published var statusKind: StatusKind = .none
    @Published var reading: Reading?
    @Published var updated: Date?
    @Published var demo = false
    @Published var connected = false
    @Published var bluetoothOn = true
    @Published var scanning = false
    @Published var found: [FoundDevice] = []
    @Published var showAll = false
    /// bumped on every stored sample so the charts can refresh
    @Published var historyVersion = 0

    let store = HistoryStore()

    static let pollForeground: TimeInterval = 2
    static let pollBackground: TimeInterval = 10
    static let recordEvery: TimeInterval = 10
    private static let savedKey = "bmsPeripheral"

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var tx: CBCharacteristic?
    private var rx: CBCharacteristic?
    private var rxBuf: [UInt8] = []
    private var pending: CheckedContinuation<[UInt16], Error>?
    private var pendingID = 0
    private var pollTask: Task<Void, Never>?
    private var userDisconnected = false
    private var lastRecord = Date.distantPast
    private var bgTask: UIBackgroundTaskIdentifier = .invalid
    private var inBackground = false

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main, options: [
            CBCentralManagerOptionRestoreIdentifierKey: "bms-central",
            CBCentralManagerOptionShowPowerAlertKey: true,
        ])
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.inBackground = true
                if self.connected { self.renewBackgroundTask() }
            }
        }
        NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.inBackground = false
                self.endBackgroundTask()
                if self.connected && self.pollTask == nil { self.startPolling() }
            }
        }
    }

    var savedDeviceName: String? { peripheral?.name }
    var hasSavedDevice: Bool { UserDefaults.standard.string(forKey: Self.savedKey) != nil }

    // MARK: - user actions

    func startScan(showAll: Bool) {
        guard central.state == .poweredOn else {
            setStatus("Turn on Bluetooth to connect", .err)
            return
        }
        self.showAll = showAll
        found = []
        scanning = true
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    func stopScan() {
        central.stopScan()
        scanning = false
    }

    func choose(_ d: FoundDevice) {
        stopScan()
        if let p = peripheral, p.identifier != d.peripheral.identifier {
            central.cancelPeripheralConnection(p)
        }
        demo = false
        userDisconnected = false
        peripheral = d.peripheral
        d.peripheral.delegate = self
        UserDefaults.standard.set(d.peripheral.identifier.uuidString, forKey: Self.savedKey)
        setStatus("Connecting…", .none)
        central.connect(d.peripheral)
    }

    func disconnect() {
        userDisconnected = true
        stopPolling()
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        peripheral = nil
        connected = false
        UserDefaults.standard.removeObject(forKey: Self.savedKey)
        setStatus("Disconnected", .none)
    }

    func showExample() {
        demo = true
        reading = .example
        updated = Date()
    }

    func clearHistory() {
        store.clear()
        historyVersion += 1
    }

    // MARK: - polling

    private func setStatus(_ text: String, _ kind: StatusKind) {
        statusText = text
        statusKind = kind
    }

    private func readRegs(_ reg: UInt16, _ count: UInt16) async throws -> [UInt16] {
        guard let p = peripheral, let tx, p.state == .connected else { throw BMSError.notConnected }
        rxBuf = []
        pendingID += 1
        let id = pendingID
        return try await withCheckedThrowingContinuation { cont in
            pending = cont
            let type: CBCharacteristicWriteType = tx.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
            p.writeValue(BMS.readRequest(register: reg, count: count), for: tx, type: type)
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard let self, self.pendingID == id, let c = self.pending else { return }
                self.pending = nil
                c.resume(throwing: BMSError.timeout)
            }
        }
    }

    private func readAll() async throws -> Reading {
        let a = try await readRegs(0, 16)
        let c = try await readRegs(15, 17)
        let t = try await readRegs(46, 11)
        var extra: UInt16?
        if let e = try? await readRegs(57, 1) { extra = e.first }
        return try Reading(a: a, c: c, t: t, extra: extra)
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { @MainActor [weak self] in
            var fails = 0
            while !Task.isCancelled, let self, self.connected {
                do {
                    let r = try await self.readAll()
                    self.demo = false
                    self.reading = r
                    self.updated = Date()
                    self.record(r)
                    self.setStatus("Connected: \(self.peripheral?.name ?? "BMS")", .on)
                    fails = 0
                } catch {
                    fails += 1
                    self.setStatus(error.localizedDescription, .err)
                    if fails >= 5, let p = self.peripheral {
                        // drop the link; didDisconnect reconnects
                        self.central.cancelPeripheralConnection(p)
                        break
                    }
                }
                if self.inBackground { self.renewBackgroundTask() }
                let wait = self.inBackground ? Self.pollBackground : Self.pollForeground
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            }
            self?.pollTask = nil
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
        if let c = pending { pending = nil; c.resume(throwing: BMSError.notConnected) }
        endBackgroundTask()
    }

    private func record(_ r: Reading) {
        let now = Date()
        guard now.timeIntervalSince(lastRecord) >= Self.recordEvery - 0.5 else { return }
        lastRecord = now
        store.add(Sample(t: now, soc: r.soc, v: r.voltage, i: r.current, p: Int(r.power.rounded()),
                         cells: r.cells, temps: r.temps, board: r.boardTemp))
        historyVersion += 1
    }

    // MARK: - background

    private func renewBackgroundTask() {
        let old = bgTask
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "bms-poll") { [weak self] in
            MainActor.assumeIsolated { self?.backgroundTaskExpired() }
        }
        if old != .invalid { UIApplication.shared.endBackgroundTask(old) }
    }

    private func endBackgroundTask() {
        if bgTask != .invalid {
            UIApplication.shared.endBackgroundTask(bgTask)
            bgTask = .invalid
        }
    }

    private func backgroundTaskExpired() {
        // poke the BMS so its answer wakes the app again
        if let p = peripheral, let tx, p.state == .connected {
            rxBuf = []
            let type: CBCharacteristicWriteType = tx.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
            p.writeValue(BMS.readRequest(register: 0, count: 16), for: tx, type: type)
        }
        endBackgroundTask()
    }

    private func reconnectSaved() {
        guard !userDisconnected, central.state == .poweredOn else { return }
        if peripheral == nil, let s = UserDefaults.standard.string(forKey: Self.savedKey), let id = UUID(uuidString: s) {
            peripheral = central.retrievePeripherals(withIdentifiers: [id]).first
        }
        guard let p = peripheral else { return }
        p.delegate = self
        if p.state == .connected {
            setUp(p)
        } else if p.state != .connecting {
            setStatus("Connecting to “\(p.name ?? "BMS")”…", .none)
            central.connect(p)
        }
    }

    private func setUp(_ p: CBPeripheral) {
        p.delegate = self
        p.discoverServices([BMS.service])
    }
}

// MARK: - CBCentralManagerDelegate

extension Monitor: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            bluetoothOn = central.state == .poweredOn
            switch central.state {
            case .poweredOn:
                reconnectSaved()
            case .unauthorized:
                setStatus("Bluetooth access is off for this app (Settings → Battery)", .err)
            case .poweredOff:
                setStatus("Bluetooth is off", .err)
            case .unsupported:
                setStatus("This device has no Bluetooth LE", .err)
            default: break
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        MainActor.assumeIsolated {
            if let ps = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral], let p = ps.first {
                peripheral = p
                p.delegate = self
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        MainActor.assumeIsolated {
            let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name
            let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
            let isBMS = (name?.uppercased().hasPrefix("BMS") ?? false) || services.contains(BMS.service)
            guard showAll || isBMS else { return }
            let r = RSSI.intValue == 127 ? -100 : RSSI.intValue
            if let i = found.firstIndex(where: { $0.id == peripheral.identifier }) {
                found[i].rssi = r
                if let name { found[i].name = name }
            } else {
                found.append(FoundDevice(peripheral: peripheral, name: name, rssi: r, looksLikeBMS: isBMS))
            }
            found.sort { ($0.looksLikeBMS ? 1 : 0, $0.rssi) > ($1.looksLikeBMS ? 1 : 0, $1.rssi) }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated { setUp(peripheral) }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            guard peripheral == self.peripheral, !userDisconnected else { return }
            setStatus("Waiting for battery “\(peripheral.name ?? "BMS")”…", .err)
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                MainActor.assumeIsolated { self?.reconnectSaved() }
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            guard peripheral == self.peripheral else { return }
            connected = false
            tx = nil; rx = nil
            stopPolling()
            if userDisconnected { return }
            // a pending connect never times out: iOS connects as soon as the
            // battery is back, even with the app in the background
            setStatus("Connection lost, reconnecting…", .err)
            central.connect(peripheral)
        }
    }
}

// MARK: - CBPeripheralDelegate

extension Monitor: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            guard let svc = peripheral.services?.first(where: { $0.uuid == BMS.service }) else {
                setStatus("“\(peripheral.name ?? "unnamed")” is not a battery board, choose another", .err)
                userDisconnected = true
                UserDefaults.standard.removeObject(forKey: Self.savedKey)
                central.cancelPeripheralConnection(peripheral)
                self.peripheral = nil
                return
            }
            peripheral.discoverCharacteristics([BMS.txChar, BMS.rxChar], for: svc)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        MainActor.assumeIsolated {
            tx = service.characteristics?.first { $0.uuid == BMS.txChar }
            rx = service.characteristics?.first { $0.uuid == BMS.rxChar }
            guard let rx, tx != nil else {
                setStatus("Battery board has no data channel", .err)
                return
            }
            peripheral.setNotifyValue(true, for: rx)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            guard characteristic.uuid == BMS.rxChar else { return }
            if let error {
                setStatus(error.localizedDescription, .err)
                return
            }
            connected = true
            setStatus("Connected: \(peripheral.name ?? "BMS")", .on)
            if inBackground { renewBackgroundTask() }
            startPolling()
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            guard characteristic.uuid == BMS.rxChar, let v = characteristic.value else { return }
            if inBackground {
                renewBackgroundTask()
                if connected && pollTask == nil { startPolling() }
            }
            rxBuf.append(contentsOf: v)
            while let frame = BMS.takeFrame(from: &rxBuf) {
                guard let c = pending else { continue }
                pending = nil
                switch frame {
                case .registers(let regs): c.resume(returning: regs)
                case .exception(let code): c.resume(throwing: BMSError.rejected(code))
                case .badChecksum: c.resume(throwing: BMSError.badChecksum)
                }
            }
        }
    }
}
