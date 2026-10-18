import Foundation
import CoreBluetooth

struct CameraDevice {
    let id: UUID
    let name: String
    let signal: Int
}

final class CameraBluetooth: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var onDevices: (([CameraDevice]) -> Void)?
    var onStatus: ((String) -> Void)?
    var onReady: ((UUID?) -> Void)?
    var onBusy: ((Bool) -> Void)?
    var onSetupFinished: ((CameraSetupAttempt.Phase) -> Void)?
    private let queue = DispatchQueue(label: "local.a9.bluetooth")
    private let callbacks = CameraCallbackGate()
    private var central: CBCentralManager!
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var devices: [UUID: CameraDevice] = [:]
    private var selected: CBPeripheral?
    private var pendingConnection: CBPeripheral?
    private var cancellingID: UUID?
    private var writeCharacteristic: CBCharacteristic?
    private var notifyCharacteristic: CBCharacteristic?
    private var wantsScan = false
    private var session = UUID()
    private var ready = false
    private var connectionFailure: String?
    private var connectionTimer = UUID()
    private var setup = CameraSetupAttempt()

    private func emit(_ work: @escaping () -> Void) {
        let current = session
        DispatchQueue.main.async {
            guard self.callbacks.isCurrent(current) else { return }
            work()
        }
    }
    private func status(_ text: String) { emit { self.onStatus?(text) } }
    private func setReady(_ value: Bool) {
        ready = value
        let id = value && !setup.isPending ? selected?.identifier : nil
        emit { self.onReady?(id) }
    }
    private func busy(_ value: Bool) { emit { self.onBusy?(value) } }
    private func newSession() {
        session = callbacks.advance()
        pendingConnection = nil; cancellingID = nil; connectionFailure = nil; connectionTimer = UUID()
        setup.reset(); busy(false)
    }
    func scan() {
        queue.async {
            guard !self.setup.isPending else { return }
            self.newSession()
            self.wantsScan = true
            if self.central == nil {
                self.central = CBCentralManager(delegate: self, queue: self.queue)
                return
            }
            let old = self.selected
            self.selected = nil; self.writeCharacteristic = nil; self.notifyCharacteristic = nil
            self.setReady(false)
            if let old = old { self.central.cancelPeripheralConnection(old) }
            if self.central.state == .poweredOn { self.beginScan() }
            else { self.status("Waiting for Bluetooth. Allow access if macOS asks.") }
        }
    }
    private func beginScan() {
        central.stopScan()
        devices.removeAll(); peripherals.removeAll()
        // A cached identifier is a selection preference, not a live discovery.
        emit { self.onDevices?([]) }
        status("Searching nearby for A9 cameras…")
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        let current = session
        queue.asyncAfter(deadline: .now() + 15) {
            guard self.session == current, self.wantsScan else { return }
            self.central.stopScan(); self.wantsScan = false
            self.status(self.devices.isEmpty
                ? "No live A9 signal found. Keep it powered nearby, close other camera apps, then scan again."
                : "Camera found nearby. Select it and click Connect Bluetooth.")
        }
    }
    func connect(id: UUID) {
        queue.async {
            guard !self.setup.isPending else { return }
            guard let central = self.central, let peripheral = self.peripherals[id] else {
                self.status("Scan again to find a live camera signal."); return
            }
            if peripheral === self.selected, self.ready {
                self.status("A9 connected • V720 Bluetooth setup supported"); return
            }
            if peripheral === self.selected, peripheral.state == .connecting { return }
            let old = self.selected
            self.newSession()
            central.stopScan(); self.wantsScan = false
            self.selected = nil; self.writeCharacteristic = nil; self.notifyCharacteristic = nil
            self.setReady(false)
            self.pendingConnection = peripheral
            self.status("Connecting to \(peripheral.name ?? "A9")…")
            // Wait for cancellation before connecting again. Cancelling and
            // immediately reconnecting the same peripheral races didDisconnect.
            if let old = old, old.state != .disconnected {
                self.cancellingID = old.identifier
                central.cancelPeripheralConnection(old)
            } else if peripheral.state == .disconnecting {
                self.cancellingID = peripheral.identifier
            } else { self.beginConnection() }
            let current = self.session
            let timer = UUID(); self.connectionTimer = timer
            self.queue.asyncAfter(deadline: .now() + 45) {
                guard self.session == current, self.connectionTimer == timer else { return }
                self.failConnection("Bluetooth connection timed out. Keep the camera nearby and close other camera apps, then scan again.")
            }
        }
    }
    private func beginConnection() {
        guard let peripheral = pendingConnection else { return }
        pendingConnection = nil; cancellingID = nil; selected = peripheral
        peripheral.delegate = self
        central.connect(peripheral)
    }
    private func failConnection(_ message: String) {
        connectionTimer = UUID()
        connectionFailure = message
        let old = selected ?? pendingConnection
        selected = nil; pendingConnection = nil; cancellingID = nil
        setReady(false)
        if let old = old { central.cancelPeripheralConnection(old) }
        status(message)
    }
    func configureWiFi(ssid: String, password: String, expectedDeviceID: UUID) {
        queue.async {
            guard !self.setup.isPending else { return }
            guard self.ready, let p = self.selected,
                  p.identifier == expectedDeviceID, p.state == .connected,
                  let write = self.writeCharacteristic else {
                self.busy(false); self.status("Connect Bluetooth first."); return
            }
            guard let data = try? CameraSetup.payload(ssid: ssid, password: password) else {
                self.busy(false); self.status("Invalid Wi-Fi details."); return
            }
            guard data.count <= p.maximumWriteValueLength(for: .withResponse) else {
                self.busy(false); self.status("Wi-Fi details exceed the camera’s Bluetooth message size. Try camera Wi-Fi setup instead."); return
            }
            let attempt = self.setup.begin()
            self.busy(true); self.setReady(false)
            self.status("Sending Wi-Fi details directly to the camera…")
            p.writeValue(data, for: write, type: .withResponse)
            let current = self.session
            self.queue.asyncAfter(deadline: .now() + 30) {
                guard self.session == current, self.setup.timeOut(generation: attempt) else { return }
                self.busy(false)
                self.setReady(p.state == .connected && self.notifyCharacteristic?.isNotifying == true)
                self.status(self.setup.status)
                self.emit { self.onSetupFinished?(.unconfirmed) }
            }
        }
    }
    func disconnect() {
        queue.async {
            self.newSession(); self.wantsScan = false; self.central?.stopScan()
            let old = self.selected
            self.selected = nil; self.writeCharacteristic = nil; self.notifyCharacteristic = nil
            self.setReady(false)
            if let old = old { self.central?.cancelPeripheralConnection(old) }
        }
    }
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            if wantsScan { beginScan() } else { status("Bluetooth is ready. Click Scan for A9.") }
        case .poweredOff: setReady(false); status("Turn on Bluetooth in System Settings.")
        case .unauthorized: setReady(false); status("Allow A9 Camera under System Settings → Privacy & Security → Bluetooth.")
        case .unsupported: status("Bluetooth is unavailable in this session.")
        default: status("Waiting for Bluetooth…")
        }
    }
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard wantsScan else { return }
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? ""
        let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        guard name.uppercased().contains("A9") || name.lowercased().hasPrefix("nax") || name.uppercased().contains("V720") || services.contains(CBUUID(string: "FFF9")) else { return }
        guard devices[peripheral.identifier] != nil || devices.count < 128 else { return }
        peripherals[peripheral.identifier] = peripheral
        devices[peripheral.identifier] = CameraDevice(id: peripheral.identifier, name: name.isEmpty ? "V720 setup device" : name, signal: RSSI.intValue)
        let list = devices.values.sorted { $0.id.uuidString < $1.id.uuidString }
        emit { self.onDevices?(list) }
    }
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peripheral === selected else { central.cancelPeripheralConnection(peripheral); return }
        UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: "lastCameraIdentifier")
        status("Connected. Checking camera setup service…")
        peripheral.discoverServices([CBUUID(string: "FFF9")])
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard peripheral === selected else { return }
        failConnection("Could not connect to the camera. Keep it powered nearby and scan again.")
    }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        if peripheral.identifier == cancellingID {
            cancellingID = nil
            if pendingConnection != nil { beginConnection() }
            return
        }
        guard peripheral === selected else { return }
        connectionTimer = UUID()
        setReady(false)
        if let failure = connectionFailure { status(failure) }
        else if setup.didDisconnect() || setup.phase == .acknowledged || setup.phase == .unconfirmed || setup.phase == .failed {
            status(setup.status)
        } else { status("Bluetooth disconnected. Scan to reconnect.") }
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard peripheral === selected else { return }
        guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == CBUUID(string: "FFF9") }) else {
            failConnection("This device does not expose the supported V720 setup service."); return
        }
        peripheral.discoverCharacteristics([CBUUID(string: "FFF7"), CBUUID(string: "FFF8")], for: service)
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard peripheral === selected else { return }
        guard error == nil else { failConnection("Could not read camera setup characteristics. Scan and reconnect."); return }
        writeCharacteristic = service.characteristics?.first { $0.uuid == CBUUID(string: "FFF8") && $0.properties.contains(.write) }
        notifyCharacteristic = service.characteristics?.first { $0.uuid == CBUUID(string: "FFF7") && $0.properties.contains(.notify) }
        guard writeCharacteristic != nil, let notify = notifyCharacteristic else {
            failConnection("Camera setup characteristics are missing."); return
        }
        peripheral.setNotifyValue(true, for: notify)
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === selected, characteristic === notifyCharacteristic else { return }
        if error == nil && characteristic.isNotifying {
            connectionTimer = UUID()
            setReady(true); status("A9 connected • V720 Bluetooth setup supported")
        } else { failConnection("Camera notifications could not be enabled. Scan and reconnect.") }
    }
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === selected, characteristic === writeCharacteristic,
              setup.wrote(success: error == nil, generation: setup.generation) else { return }
        if !setup.isPending {
            busy(false); setReady(peripheral.state == .connected && notifyCharacteristic?.isNotifying == true)
            emit { self.onSetupFinished?(.failed) }
        }
        status(setup.status)
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === selected, characteristic === notifyCharacteristic,
              setup.isPending, error == nil, let data = characteristic.value else { return }
        if setup.acknowledge(data) {
            busy(false); setReady(false); status(setup.status)
            emit { self.onSetupFinished?(.acknowledged) }
            central.cancelPeripheralConnection(peripheral)
        } else { status(CameraSetup.responseStatus(data)) }
    }
}
