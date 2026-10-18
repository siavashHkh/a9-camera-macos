import AppKit
import UniformTypeIdentifiers

func label(_ text: String, size: CGFloat = 13, bold: Bool = false, secondary: Bool = false) -> NSTextField {
    let view = NSTextField(wrappingLabelWithString: text)
    view.font = .systemFont(ofSize: size, weight: bold ? .semibold : .regular)
    view.textColor = secondary ? .secondaryLabelColor : .labelColor
    view.setContentCompressionResistancePriority(.required, for: .vertical)
    return view
}
func stack(_ views: [NSView], vertical: Bool = true, spacing: CGFloat = 10) -> NSStackView {
    let view = NSStackView(views: views)
    view.orientation = vertical ? .vertical : .horizontal
    view.alignment = vertical ? .leading : .centerY
    view.spacing = spacing
    return view
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var bluetooth: CameraBluetooth!
    let video = CameraVideoController()
    let hotspotSetup = CameraAPSetup()
    let setupTransport = NSPopUpButton()
    var setupBusy = false
    var hotspotSetupRunning = false
    var devices: [CameraDevice] = []
    let deviceMenu = NSPopUpButton()
    let ssid = NSTextField()
    let password = NSSecureTextField()
    let address = NSTextField(string: UserDefaults.standard.string(forKey: "cameraAddress") ?? "192.168.169.1")
    let protocolMenu = NSPopUpButton()
    let bluetoothStatus = label("Ready to find your camera.", secondary: true)
    let videoStatus = label("Connect your camera to start viewing.", secondary: true)
    let scanButton = NSButton(title: "Scan for A9", target: nil, action: nil)
    let connectButton = NSButton(title: "Connect Bluetooth", target: nil, action: nil)
    let setupButton = NSButton(title: "Send Wi-Fi setup", target: nil, action: nil)
    let playButton = NSButton(title: "Start video", target: nil, action: nil)
    let stopButton = NSButton(title: "Stop", target: nil, action: nil)
    let snapshotButton = NSButton(title: "Save snapshot", target: nil, action: nil)
    let imageView = NSImageView()
    let placeholder = label("Your camera’s view will appear here", size: 16, secondary: true)
    let dimensions = label("WAITING FOR CAMERA", size: 11, secondary: true)
    var lastJPEG: Data?
    var frameCount = 0
    var isViewing = false
    var connectedDeviceID: UUID?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        makeMenu()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 750), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "A9 Camera 0.3.3"
        window.minSize = NSSize(width: 1040, height: 750)
        window.center()
        window.contentView = buildContent()
        setupButton.isEnabled = false; connectButton.isEnabled = false
        snapshotButton.isEnabled = false; stopButton.isEnabled = false
        bluetooth = CameraBluetooth()
        bluetooth.onStatus = { [weak self] text in
            guard let self = self, self.setupTransport.indexOfSelectedItem == 0 else { return }
            self.bluetoothStatus.stringValue = text
        }
        bluetooth.onBusy = { [weak self] busy in
            guard let self = self, !self.hotspotSetupRunning else { return }
            self.setupBusy = busy; self.updateSetupControls()
        }
        bluetooth.onReady = { [weak self] deviceID in
            self?.connectedDeviceID = deviceID
            self?.updateSetupControls()
        }
        bluetooth.onDevices = { [weak self] list in
            guard let self = self else { return }
            let previous = self.deviceMenu.indexOfSelectedItem
            let selectedID = self.devices.indices.contains(previous) ? self.devices[previous].id : nil
            self.devices = list
            self.deviceMenu.removeAllItems()
            self.deviceMenu.addItems(withTitles: list.map {
                $0.signal == 127 ? "\($0.name)  •  previously found" : "\($0.name)  •  \($0.signal) dBm"
            })
            if let id = selectedID, let index = list.firstIndex(where: { $0.id == id }) { self.deviceMenu.selectItem(at: index) }
            self.updateSetupControls()
        }
        bluetooth.onSetupFinished = { [weak self] phase in
            if phase == .acknowledged || phase == .unconfirmed { self?.afterSetup() }
        }
        hotspotSetup.onStatus = { [weak self] text in self?.bluetoothStatus.stringValue = text }
        hotspotSetup.onFinished = { [weak self] outcome in
            guard let self = self else { return }
            self.hotspotSetupRunning = false; self.setupBusy = false; self.updateSetupControls()
            if outcome != .failed { self.afterSetup() }
        }
        video.onStatus = { [weak self] text in self?.videoStatus.stringValue = text }
        video.onStopped = { [weak self] in
            guard let self = self else { return }
            self.isViewing = false; self.playButton.isEnabled = !self.setupBusy; self.stopButton.isEnabled = false
            self.dimensions.stringValue = self.lastJPEG == nil ? "NO VIDEO RECEIVED" : "LAST FRAME • CONNECTION STOPPED"
        }
        video.onFrame = { [weak self] frame in
            guard let self = self, self.isViewing else { return }
            let image = NSImage(cgImage: frame.image, size: NSSize(width: frame.image.width, height: frame.image.height))
            self.lastJPEG = frame.jpeg; self.imageView.image = image
            self.placeholder.isHidden = true; self.snapshotButton.isEnabled = true
            self.frameCount += 1
            self.dimensions.stringValue = "LIVE  •  \(Int(image.size.width)) × \(Int(image.size.height))  •  \(self.frameCount) frames"
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func makeMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu(); appItem.submenu = appMenu
        appMenu.addItem(withTitle: "Quit A9 Camera", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let editItem = NSMenuItem(); editItem.title = "Edit"; main.addItem(editItem)
        let edit = NSMenu(title: "Edit"); editItem.submenu = edit
        for (name, action, key) in [("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            edit.addItem(withTitle: name, action: Selector(action), keyEquivalent: key)
        }
        NSApp.mainMenu = main
    }
    func button(_ b: NSButton, _ action: Selector) -> NSButton {
        b.target = self; b.action = action; b.bezelStyle = .rounded
        return b
    }
    func fullWidth(_ view: NSView, in parent: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalTo: parent.widthAnchor).isActive = true
    }
    func buildContent() -> NSView {
        let root = NSView()
        let title = label("A9 Camera", size: 27, bold: true)
        let subtitle = label("Manual Wi-Fi · Bluetooth setup · Local video", size: 13, secondary: true)
        let heading = stack([title, subtitle], spacing: 3)
        let beta = label("NO LOCATION ACCESS", size: 11, bold: true, secondary: true)
        let spacer = NSView()
        let header = stack([heading, spacer, beta], vertical: false)
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        ssid.placeholderString = "2.4 GHz Wi-Fi name"
        password.placeholderString = "Wi-Fi password"
        address.placeholderString = "Camera’s local IP address"
        deviceMenu.setContentHuggingPriority(.defaultLow, for: .horizontal)
        protocolMenu.addItems(withTitles: ["Automatic (classic, then newer)", "V720 classic", "V720 newer firmware"])
        let savedMode = UserDefaults.standard.string(forKey: "videoProtocolMode") ?? "automatic"
        protocolMenu.selectItem(at: savedMode == "classic" ? 1 : savedMode == "newer" ? 2 : 0)
        setupTransport.addItems(withTitles: ["Bluetooth", "Camera Wi-Fi (classic V720)"])
        setupTransport.target = self; setupTransport.action = #selector(setupTransportChanged)
        let left = makeConnectionTabs()
        let viewer = NSView(); viewer.wantsLayer = true
        viewer.layer?.backgroundColor = NSColor(calibratedWhite: 0.075, alpha: 1).cgColor
        viewer.layer?.cornerRadius = 12
        viewer.heightAnchor.constraint(greaterThanOrEqualToConstant: 310).isActive = true
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        viewer.addSubview(imageView)
        placeholder.textColor = NSColor(calibratedWhite: 0.6, alpha: 1)
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        viewer.addSubview(placeholder)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: viewer.leadingAnchor), imageView.trailingAnchor.constraint(equalTo: viewer.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: viewer.topAnchor), imageView.bottomAnchor.constraint(equalTo: viewer.bottomAnchor),
            placeholder.centerXAnchor.constraint(equalTo: viewer.centerXAnchor), placeholder.centerYAnchor.constraint(equalTo: viewer.centerYAnchor)
        ])
        let controls = stack([button(playButton, #selector(startVideo)), button(stopButton, #selector(stopVideo)), NSView(), button(snapshotButton, #selector(snapshot))], vertical: false)
        let right = stack([
            label("Live view", size: 16, bold: true),
            stack([label("Camera IP", size: 12, bold: true), address], vertical: false),
            protocolMenu, viewer, dimensions, controls, videoStatus
        ], spacing: 12)
        right.setContentHuggingPriority(.defaultLow, for: .horizontal)
        viewer.setContentHuggingPriority(.defaultLow, for: .vertical)
        for view in right.arrangedSubviews { fullWidth(view, in: right) }
        address.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let divider = NSBox(); divider.boxType = .separator
        divider.widthAnchor.constraint(equalToConstant: 1).isActive = true
        let body = stack([left, divider, right], vertical: false, spacing: 24)
        body.alignment = .top
        right.trailingAnchor.constraint(equalTo: body.trailingAnchor).isActive = true
        let footer = label("Experimental V720 support • Compatibility varies by camera firmware. Wi-Fi passwords are not saved.", size: 11, secondary: true)
        let column = stack([header, NSBox.separator(), body, footer], spacing: 20)
        root.addSubview(column); column.translatesAutoresizingMaskIntoConstraints = false
        for view in column.arrangedSubviews { fullWidth(view, in: column) }
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 26), column.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -26),
            column.topAnchor.constraint(equalTo: root.topAnchor, constant: 24), column.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -20),
            divider.heightAnchor.constraint(equalTo: body.heightAnchor)
        ])
        return root
    }
    @objc func scan() { bluetooth.scan() }
    @objc func connectBluetooth() {
        let index = deviceMenu.indexOfSelectedItem
        guard devices.indices.contains(index) else { return }
        bluetooth.connect(id: devices[index].id)
    }
    func updateSetupControls() {
        let useBluetooth = setupTransport.indexOfSelectedItem == 0
        scanButton.isEnabled = !setupBusy && useBluetooth
        connectButton.isEnabled = !setupBusy && useBluetooth && !devices.isEmpty
        deviceMenu.isEnabled = !setupBusy && useBluetooth
        setupTransport.isEnabled = !setupBusy
        ssid.isEnabled = !setupBusy; password.isEnabled = !setupBusy
        address.isEnabled = !setupBusy; protocolMenu.isEnabled = !setupBusy
        setupButton.isEnabled = !setupBusy && (!useBluetooth || connectedDeviceID != nil)
        playButton.isEnabled = !setupBusy && !isViewing
    }
    @objc func setupTransportChanged() {
        guard !setupBusy else { return }
        bluetoothStatus.stringValue = setupTransport.indexOfSelectedItem == 0
            ? "Scan for a live camera signal, then connect Bluetooth."
            : "Join the camera’s Wi-Fi in macOS first. Enter its hotspot IP on the right (usually 192.168.169.1). This method requires classic V720 firmware."
        updateSetupControls()
    }
    func afterSetup() {
        if address.stringValue == "192.168.169.1" {
            address.stringValue = ""
            UserDefaults.standard.removeObject(forKey: "cameraAddress")
        }
        videoStatus.stringValue = "Rejoin home Wi-Fi and check your router for the camera. Its network join is unverified. Some firmware needs a separate local gateway for video; an IP alone may not work."
    }
    @objc func sendSetup() {
        guard !setupBusy else { return }
        let network = ssid.stringValue
        let secret = password.stringValue
        do { _ = try CameraSetup.payload(ssid: network, password: secret) }
        catch CameraSetup.ValidationError.ssid { bluetoothStatus.stringValue = "Enter a Wi-Fi name of 1–32 bytes."; return }
        catch { bluetoothStatus.stringValue = "Use an 8–63 byte Wi-Fi password, a 64-digit hex key, or leave blank for an open network."; return }
        let useBluetooth = setupTransport.indexOfSelectedItem == 0
        let deviceID = connectedDeviceID
        let host = address.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if useBluetooth && deviceID == nil { bluetoothStatus.stringValue = "Connect Bluetooth first."; return }
        if !useBluetooth && !CameraVideo.validLocalAddress(host) {
            bluetoothStatus.stringValue = "Join the camera hotspot and enter its local IPv4 address on the right."; return
        }
        let recipient = useBluetooth ? (devices.first { $0.id == deviceID }?.name ?? "connected Bluetooth camera") : host
        let alert = NSAlert()
        alert.messageText = "Send Wi-Fi details to this camera?"
        alert.informativeText = "Network: \(network)\nRecipient: \(recipient) via \(useBluetooth ? "Bluetooth" : "camera Wi-Fi")\n\nContinue only if you recognize this camera. Its identity cannot be verified by this protocol. The camera may restart."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Send Wi-Fi details")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        guard !setupBusy, setupTransport.indexOfSelectedItem == (useBluetooth ? 0 : 1),
              !useBluetooth || connectedDeviceID == deviceID else {
            bluetoothStatus.stringValue = "The setup target changed. Reconnect and try again."; return
        }
        stopVideo(); setupBusy = true; updateSetupControls()
        if useBluetooth, let id = deviceID {
            bluetooth.configureWiFi(ssid: network, password: secret, expectedDeviceID: id)
        } else {
            hotspotSetupRunning = true; bluetooth.disconnect()
            hotspotSetup.start(host: host, ssid: network, password: secret)
        }
        password.stringValue = ""
    }
    @objc func startVideo() {
        guard !setupBusy else { return }
        let host = address.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard CameraVideo.validLocalAddress(host) else { videoStatus.stringValue = "Enter a local IPv4 camera address."; return }
        UserDefaults.standard.set(host, forKey: "cameraAddress")
        let mode: CameraVideoController.Mode = protocolMenu.indexOfSelectedItem == 1 ? .classic : protocolMenu.indexOfSelectedItem == 2 ? .newer : .automatic
        UserDefaults.standard.set(mode.rawValue, forKey: "videoProtocolMode")
        frameCount = 0; isViewing = true; lastJPEG = nil; imageView.image = nil
        placeholder.isHidden = false; snapshotButton.isEnabled = false
        playButton.isEnabled = false; stopButton.isEnabled = true
        dimensions.stringValue = "CONNECTING"
        video.start(host: host, mode: mode)
    }
    @objc func stopVideo() {
        video.stop(); isViewing = false
        playButton.isEnabled = !setupBusy; stopButton.isEnabled = false
        dimensions.stringValue = lastJPEG == nil ? "VIDEO STOPPED" : "LAST FRAME • VIDEO STOPPED"
    }
    @objc func snapshot() {
        guard let data = lastJPEG else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.jpeg]
        panel.nameFieldStringValue = "A9-\(Int(Date().timeIntervalSince1970)).jpg"
        panel.beginSheetModal(for: window) { result in
            guard result == .OK, let url = panel.url else { return }
            do { try data.write(to: url, options: .atomic) }
            catch { self.videoStatus.stringValue = "Could not save snapshot: \(error.localizedDescription)" }
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { bluetooth.disconnect(); hotspotSetup.cancel(); video.stop() }
}
extension NSBox {
    static func separator() -> NSBox { let box = NSBox(); box.boxType = .separator; return box }
}
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
