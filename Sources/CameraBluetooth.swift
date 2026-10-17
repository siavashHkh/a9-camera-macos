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
    var onReady: ((Bool) -> Void)?
    var onProvisioned: (() -> Void)?
    private let queue = DispatchQueue(label: "local.a9.bluetooth")
    private var central: CBCentralManager!
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var devices: [UUID: CameraDevice] = [:]
    private var selected: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var notifyCharacteristic: CBCharacteristic?
    private var wantsScan = false
    private var session = UUID()
    private var awaitingSetup = false
    private var ready = false

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: queue)
    }
    private func status(_ text: String) { DispatchQueue.main.async { self.onStatus?(text) } }
    private func setReady(_ value: Bool) {
        ready = value
        DispatchQueue.main.async { self.onReady?(value) }
    }
    func scan() {
        queue.async {
            self.wantsScan = true
            if self.central.state == .poweredOn { self.beginScan() }
            else { self.status("Waiting for Bluetooth. Allow access if macOS asks.") }
        }
    }
    private func beginScan() {
        central.stopScan()
        devices.removeAll(); peripherals.removeAll()
        let remembered = UserDefaults.standard.string(forKey: "lastCameraIdentifier")
        if let remembered = remembered, let id = UUID(uuidString: remembered),
           let peripheral = central.retrievePeripherals(withIdentifiers: [id]).first {
            peripherals[id] = peripheral
            devices[id] = CameraDevice(id: id, name: peripheral.name ?? "A9", signal: 127)
        }
        let initial = Array(devices.values)
        DispatchQueue.main.async { self.onDevices?(initial) }
        status("Searching nearby for A9 cameras…")
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        let scanSession = UUID(); session = scanSession
        queue.asyncAfter(deadline: .now() + 15) {
            guard self.session == scanSession else { return }
            self.central.stopScan(); self.wantsScan = false
            self.status(self.devices.isEmpty ? "No A9 found. Keep it powered on nearby, then scan again." : "Select your camera and click Connect Bluetooth.")
        }
    }
    func connect(id: UUID) {
        queue.async {
            guard let peripheral = self.peripherals[id] else { self.status("Scan again to find this camera."); return }
            self.central.stopScan(); self.wantsScan = false
            if let old = self.selected { self.central.cancelPeripheralConnection(old) }
            self.session = UUID(); let connectionSession = self.session
            self.selected = peripheral
            self.writeCharacteristic = nil; self.notifyCharacteristic = nil
            self.awaitingSetup = false; self.setReady(false)
            peripheral.delegate = self
            self.status("Connecting to \(peripheral.name ?? "A9")…")
            self.central.connect(peripheral)
            self.queue.asyncAfter(deadline: .now() + 45) {
                guard self.session == connectionSession, !self.ready,
                      self.notifyCharacteristic?.isNotifying != true else { return }
                self.central.cancelPeripheralConnection(peripheral)
                self.status("Bluetooth connection timed out. Close other camera apps and try again.")
            }
        }
    }
    func configureWiFi(ssid: String, password: String) {
        queue.async {
            guard self.ready, let p = self.selected, let write = self.writeCharacteristic else {
                self.status("Connect Bluetooth first."); return
            }
            // V720 setup JSON. An empty user ID deliberately avoids a vendor account.
            // Whether account-free provisioning is accepted depends on firmware.
            guard let data = try? JSONSerialization.data(withJSONObject: ["s": ssid, "p": password, "u": ""], options: [.sortedKeys]) else { return }
            guard data.count <= p.maximumWriteValueLength(for: .withResponse) else {
                self.status("These Wi-Fi details exceed the camera’s Bluetooth message size."); return
            }
            self.awaitingSetup = true
            self.setReady(false)
            self.status("Sending Wi-Fi details directly to the camera…")
            p.writeValue(data, for: write, type: .withResponse)
            let current = self.session
            self.queue.asyncAfter(deadline: .now() + 30) {
                guard self.session == current, self.awaitingSetup else { return }
                self.awaitingSetup = false
                self.setReady(p.state == .connected)
                self.status("No setup confirmation. Check the camera’s Wi-Fi connection; account-free setup may be unsupported.")
            }
        }
    }
    func disconnect() {
        queue.async {
            self.session = UUID(); self.central.stopScan(); self.wantsScan = false
            if let p = self.selected { self.central.cancelPeripheralConnection(p) }
            self.selected = nil; self.setReady(false)
        }
    }
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn: if wantsScan { beginScan() } else { status("Bluetooth is ready. Click Scan for A9.") }
        case .poweredOff: setReady(false); status("Turn on Bluetooth in System Settings.")
        case .unauthorized: setReady(false); status("Allow A9 Camera under System Settings → Privacy & Security → Bluetooth.")
        case .unsupported: status("Bluetooth is unavailable in this session.")
        default: status("Waiting for Bluetooth…")
        }
    }
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? ""
        guard name.uppercased().contains("A9") || name.lowercased().hasPrefix("nax") || name.uppercased().contains("V720") else { return }
        peripherals[peripheral.identifier] = peripheral
        devices[peripheral.identifier] = CameraDevice(id: peripheral.identifier, name: name, signal: RSSI.intValue)
        let list = devices.values.sorted { $0.id.uuidString < $1.id.uuidString }
        DispatchQueue.main.async { self.onDevices?(list) }
    }
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peripheral === selected else { central.cancelPeripheralConnection(peripheral); return }
        UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: "lastCameraIdentifier")
        status("Connected. Checking camera setup service…")
        peripheral.discoverServices([CBUUID(string: "FFF9")])
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard peripheral === selected else { return }
        setReady(false); status("Could not connect: \(error?.localizedDescription ?? "camera unavailable")")
    }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard peripheral === selected else { return }
        setReady(false)
        status(awaitingSetup ? "Camera disconnected during setup. Checking for confirmation…" : "Bluetooth disconnected. Scan to reconnect.")
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard peripheral === selected else { return }
        guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == CBUUID(string: "FFF9") }) else {
            status("This device does not expose the supported V720 setup service."); return
        }
        peripheral.discoverCharacteristics([CBUUID(string: "FFF7"), CBUUID(string: "FFF8")], for: service)
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard peripheral === selected, error == nil else { return }
        writeCharacteristic = service.characteristics?.first { $0.uuid == CBUUID(string: "FFF8") && $0.properties.contains(.write) }
        notifyCharacteristic = service.characteristics?.first { $0.uuid == CBUUID(string: "FFF7") && $0.properties.contains(.notify) }
        guard writeCharacteristic != nil, let notify = notifyCharacteristic else { status("Camera setup characteristics are missing."); return }
        peripheral.setNotifyValue(true, for: notify)
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === selected else { return }
        if error == nil && characteristic.isNotifying {
            setReady(true); status("A9 connected • V720 Bluetooth setup supported")
        } else { status("Camera notifications could not be enabled. Reconnect and try again.") }
    }
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === selected else { return }
        if let error = error {
            awaitingSetup = false; setReady(true); status("Setup write failed: \(error.localizedDescription)")
        } else { status("Wi-Fi details delivered. Waiting for the camera’s confirmation…") }
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === selected, awaitingSetup, error == nil, let data = characteristic.value else { return }
        if data == Data([0]) {
            awaitingSetup = false; status("Camera acknowledged Wi-Fi setup. Locate its IP address to view video.")
            DispatchQueue.main.async { self.onProvisioned?() }
            central.cancelPeripheralConnection(peripheral)
        } else { status("Camera setup response: \(data.map { String(format: "%02X", $0) }.joined(separator: " "))") }
    }
}
