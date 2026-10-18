import Foundation
import CoreBluetooth

struct CameraDevice { let id: UUID; let name: String; let signal: Int }
enum CameraBluetoothPhase: Equatable {
    case idle, scanning, connecting(UUID), discovering(UUID), ready(UUID), provisioning(UUID), finished(CameraSetupAttempt.Phase), unavailable, failed
}

// CoreBluetooth runs on one queue. Each connection permits one setup write;
// every terminal result drains that connection before another can be used.
final class CameraBluetooth: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var onDevices: (([CameraDevice]) -> Void)?
    var onStatus: ((String) -> Void)?
    var onReady: ((UUID?) -> Void)?
    var onBusy: ((Bool) -> Void)?
    var onState: ((CameraBluetoothPhase) -> Void)?
    var onSetupStarted: (() -> Void)?
    var onSetupFinished: ((CameraSetupAttempt.Phase) -> Void)?
    private let queue = DispatchQueue(label:"local.a9.bluetooth")
    private let gate = CameraCallbackGate()
    private var generation = UUID()
    private var phase = CameraBluetoothPhase.idle
    private var central: CBCentralManager?
    private var peripherals: [UUID:CBPeripheral] = [:]
    private var devices: [UUID:CameraDevice] = [:]
    private var lastSeen: [UUID:Date] = [:]
    private var selected: CBPeripheral?
    private var cancelling: CBPeripheral?
    private var pending: CBPeripheral?
    private var write: CBCharacteristic?
    private var notify: CBCharacteristic?
    private var wantsScan = false
    private var connectionDeadline = UUID()
    private var setup = CameraSetupAttempt()
    private var writeAttempt: UUID?
    private var isProvisioning: Bool { if case .provisioning = phase { return true }; return false }
    private func emit(_ work: @escaping () -> Void) {
        let current = generation
        DispatchQueue.main.async { guard self.gate.isCurrent(current) else { return }; work() }
    }
    private func move(_ next: CameraBluetoothPhase, _ message: String) {
        phase = next
        let ready: UUID? = { if case .ready(let id) = next { return id }; return nil }()
        let busy = isProvisioning
        emit { self.onState?(next); self.onReady?(ready); self.onBusy?(busy); self.onStatus?(message) }
    }
    private func invalidate() {
        generation = gate.advance(); connectionDeadline = UUID(); writeAttempt = nil
        setup.reset(); write = nil; notify = nil
    }
    private func cancelPeers() {
        let all = [selected,pending,cancelling].compactMap{$0}
        selected = nil; pending = nil; cancelling = nil
        for peripheral in all where peripheral.state != .disconnected { central?.cancelPeripheralConnection(peripheral) }
    }
    func scan() {
        queue.async {
            guard !self.isProvisioning else { return }
            self.invalidate(); self.cancelPeers(); self.wantsScan = true
            self.devices.removeAll(); self.peripherals.removeAll(); self.lastSeen.removeAll()
            self.emit { self.onDevices?([]) }
            self.move(.scanning,"Searching nearby for A9 cameras…")
            if self.central == nil { self.central = CBCentralManager(delegate:self,queue:self.queue) }
            else if self.central?.state == .poweredOn { self.beginScan() }
        }
    }
    private func beginScan() {
        central?.stopScan()
        central?.scanForPeripherals(withServices:nil,options:[CBCentralManagerScanOptionAllowDuplicatesKey:false])
        let current = generation
        queue.asyncAfter(deadline:.now()+15) {
            guard self.gate.isCurrent(current), self.wantsScan else { return }
            self.wantsScan = false; self.central?.stopScan()
            self.move(.idle,self.devices.isEmpty ? "No live A9 signal found. Keep it powered nearby and scan again." : "Fresh camera signal found. Select it and connect Bluetooth.")
        }
    }
    func connect(id: UUID) {
        queue.async {
            guard !self.isProvisioning else { return }
            if case .ready(let current) = self.phase, current == id { return }
            if case .connecting(let current) = self.phase, current == id { return }
            if case .discovering(let current) = self.phase, current == id { return }
            guard self.central?.state == .poweredOn, let peripheral = self.peripherals[id],
                  let seen = self.lastSeen[id], Date().timeIntervalSince(seen) <= 60 else {
                self.move(.failed,"Scan again to find a fresh camera advertisement."); return
            }
            let old = self.selected ?? self.cancelling
            self.invalidate(); self.central?.stopScan(); self.wantsScan = false
            self.selected = nil; self.pending = peripheral; self.cancelling = nil
            self.move(.connecting(id),"Connecting to the selected camera…")
            if let old = old, old.state != .disconnected {
                self.cancelling = old; self.central?.cancelPeripheralConnection(old)
            } else if peripheral.state == .disconnecting { self.cancelling = peripheral }
            else { self.beginConnection() }
            let current = self.generation; let deadline = UUID(); self.connectionDeadline = deadline
            self.queue.asyncAfter(deadline:.now()+30) {
                guard self.gate.isCurrent(current), self.connectionDeadline == deadline else { return }
                self.fail("Bluetooth connection timed out. Keep the camera nearby, close other camera apps, then scan again.")
            }
        }
    }
    private func beginConnection() {
        guard let peripheral = pending else { return }
        pending = nil; cancelling = nil; selected = peripheral
        peripheral.delegate = self; central?.connect(peripheral)
    }
    private func fail(_ message: String) {
        connectionDeadline = UUID(); writeAttempt = nil; write = nil; notify = nil
        cancelPeers(); move(.failed,message)
    }
    func configureWiFi(ssid: String, password: String, expectedDeviceID: UUID) {
        let current = gate.current()
        queue.async {
            guard self.gate.isCurrent(current), !self.isProvisioning else { return }
            guard case .ready(let id) = self.phase, id == expectedDeviceID,
                  let peripheral = self.selected, peripheral.identifier == id, peripheral.state == .connected,
                  let characteristic = self.write, self.notify?.isNotifying == true else {
                self.move(.failed,"Connect a fresh Bluetooth session before sending Wi-Fi settings."); return
            }
            guard let payload = try? CameraSetup.payload(ssid:ssid,password:password) else { self.move(.ready(id),"Invalid Wi-Fi details."); return }
            guard payload.count <= peripheral.maximumWriteValueLength(for:.withResponse) else {
                self.move(.ready(id),"Wi-Fi details exceed this Bluetooth connection’s message size. Use classic camera-hotspot setup instead."); return
            }
            let attempt = self.setup.begin(); self.writeAttempt = attempt
            self.move(.provisioning(id),"Sending Wi-Fi settings to the camera…")
            self.emit { self.onSetupStarted?() }
            peripheral.writeValue(payload,for:characteristic,type:.withResponse)
            self.queue.asyncAfter(deadline:.now()+20) {
                guard self.gate.isCurrent(current), self.isProvisioning, self.setup.timeOut(generation:attempt) else { return }
                self.finishSetup(.unconfirmed)
            }
        }
    }
    private func finishSetup(_ result: CameraSetupAttempt.Phase) {
        let message = setup.status
        connectionDeadline = UUID(); writeAttempt = nil; write = nil; notify = nil
        cancelPeers()
        move(.finished(result),message)
        emit { self.onSetupFinished?(result) }
    }
    func disconnect() {
        let current = gate.advance()
        queue.async {
            guard self.gate.isCurrent(current) else { return }
            self.generation = current; self.connectionDeadline = UUID(); self.writeAttempt = nil
            self.wantsScan = false; self.central?.stopScan(); self.setup.reset()
            self.write = nil; self.notify = nil; self.cancelPeers()
            self.move(.idle,"Bluetooth disconnected.")
        }
    }
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            if wantsScan { beginScan() }
            else if selected == nil { move(.idle,"Bluetooth is ready. Scan for the camera.") }
            return
        }
        if isProvisioning {
            _ = setup.didDisconnect(); _ = setup.timeOut(generation:setup.generation)
            finishSetup(.unconfirmed); return
        }
        connectionDeadline = UUID(); cancelPeers(); write = nil; notify = nil
        switch central.state {
        case .poweredOff: move(.unavailable,"Turn on Bluetooth in System Settings.")
        case .unauthorized: move(.unavailable,"Allow A9 Camera under Privacy & Security → Bluetooth.")
        case .unsupported: move(.unavailable,"Bluetooth is unavailable on this Mac.")
        default: move(.unavailable,"Waiting for Bluetooth…")
        }
    }
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String:Any], rssi RSSI: NSNumber) {
        guard wantsScan else { return }
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? ""
        let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        guard name.uppercased().contains("A9") || name.lowercased().hasPrefix("nax") || name.uppercased().contains("V720") || services.contains(CBUUID(string:"FFF9")),
              devices[peripheral.identifier] != nil || devices.count < 128 else { return }
        peripherals[peripheral.identifier] = peripheral; lastSeen[peripheral.identifier] = Date()
        devices[peripheral.identifier] = CameraDevice(id:peripheral.identifier,name:name.isEmpty ? "V720 setup device" : name,signal:RSSI.intValue)
        let list = devices.values.sorted{$0.id.uuidString < $1.id.uuidString}
        emit { self.onDevices?(list) }
    }
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peripheral === selected else { central.cancelPeripheralConnection(peripheral); return }
        move(.discovering(peripheral.identifier),"Connected. Checking camera setup service…")
        peripheral.discoverServices([CBUUID(string:"FFF9")])
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard peripheral === selected else { return }; fail("Could not connect. Keep the camera powered nearby and scan again.")
    }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        if peripheral === cancelling { cancelling = nil; beginConnection(); return }
        guard peripheral === selected else { return }
        if isProvisioning {
            _ = setup.didDisconnect(); _ = setup.timeOut(generation:setup.generation)
            finishSetup(.unconfirmed)
        } else { fail("Bluetooth disconnected. Scan for a fresh signal before reconnecting.") }
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard peripheral === selected else { return }
        guard error == nil, let service = peripheral.services?.first(where:{$0.uuid == CBUUID(string:"FFF9")}) else { fail("This device does not expose the supported camera setup service."); return }
        peripheral.discoverCharacteristics([CBUUID(string:"FFF7"),CBUUID(string:"FFF8")],for:service)
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard peripheral === selected else { return }
        guard error == nil else { fail("Could not discover camera setup characteristics."); return }
        write = service.characteristics?.first{$0.uuid == CBUUID(string:"FFF8") && $0.properties.contains(.write)}
        notify = service.characteristics?.first{$0.uuid == CBUUID(string:"FFF7") && $0.properties.contains(.notify)}
        guard write != nil, let notify = notify else { fail("Supported camera write/notification characteristics are missing."); return }
        peripheral.setNotifyValue(true,for:notify)
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === selected, characteristic === notify else { return }
        guard error == nil, characteristic.isNotifying else { fail("Camera notifications could not be enabled."); return }
        connectionDeadline = UUID()
        move(.ready(peripheral.identifier),"A9 connected • V720 Bluetooth setup ready")
    }
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === selected, characteristic === write, isProvisioning, let attempt = writeAttempt,
              setup.wrote(success:error == nil,generation:attempt) else { return }
        if error != nil { finishSetup(.failed) }
        else { move(.provisioning(peripheral.identifier),setup.status) }
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === selected, characteristic === notify, isProvisioning, error == nil, let data = characteristic.value else { return }
        if setup.acknowledge(data) { finishSetup(.acknowledged) }
        else { move(.provisioning(peripheral.identifier),CameraSetup.responseStatus(data)) }
    }
}
