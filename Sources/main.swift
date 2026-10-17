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
    let video = CameraVideo()
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        makeMenu()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 750), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "A9 Camera"
        window.minSize = NSSize(width: 1040, height: 750)
        window.center()
        window.contentView = buildContent()
        setupButton.isEnabled = false; connectButton.isEnabled = false
        snapshotButton.isEnabled = false; stopButton.isEnabled = false
        bluetooth = CameraBluetooth()
        bluetooth.onStatus = { [weak self] text in self?.bluetoothStatus.stringValue = text }
        bluetooth.onReady = { [weak self] ready in self?.setupButton.isEnabled = ready }
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
            self.connectButton.isEnabled = !list.isEmpty
        }
        bluetooth.onProvisioned = { [weak self] in
            self?.videoStatus.stringValue = "Wi-Fi setup acknowledged. Enter the camera’s IP address from your router, then Start video."
        }
        video.onStatus = { [weak self] text in self?.videoStatus.stringValue = text }
        video.onStopped = { [weak self] in
            guard let self = self else { return }
            self.isViewing = false; self.playButton.isEnabled = true; self.stopButton.isEnabled = false
            self.dimensions.stringValue = self.lastJPEG == nil ? "NO VIDEO RECEIVED" : "LAST FRAME • CONNECTION STOPPED"
        }
        video.onFrame = { [weak self] data in
            guard let self = self, let image = NSImage(data: data) else { return }
            self.lastJPEG = data; self.imageView.image = image
            self.placeholder.isHidden = true; self.snapshotButton.isEnabled = true
            self.frameCount += 1
            self.dimensions.stringValue = "LIVE  •  \(Int(image.size.width)) × \(Int(image.size.height))  •  \(self.frameCount) frames"
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        bluetooth.scan()
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
        protocolMenu.addItems(withTitles: ["V720 classic", "V720 newer firmware"])
        protocolMenu.selectItem(at: UserDefaults.standard.integer(forKey: "protocolIndex"))
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
    @objc func sendSetup() {
        let network = ssid.stringValue
        guard !network.isEmpty, network.utf8.count <= 32 else { bluetoothStatus.stringValue = "Enter a Wi-Fi name of 1–32 bytes."; return }
        let secret = password.stringValue
        guard secret.isEmpty || (8...63).contains(secret.utf8.count) || (secret.count == 64 && secret.allSatisfy(\.isHexDigit)) else {
            bluetoothStatus.stringValue = "Use an 8–63 byte Wi-Fi password, a 64-digit hex key, or leave blank for an open network."; return
        }
        bluetooth.configureWiFi(ssid: network, password: secret)
        password.stringValue = ""
    }
    @objc func startVideo() {
        let host = address.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard CameraVideo.validLocalAddress(host) else { videoStatus.stringValue = "Enter a local IPv4 camera address."; return }
        UserDefaults.standard.set(host, forKey: "cameraAddress")
        UserDefaults.standard.set(protocolMenu.indexOfSelectedItem, forKey: "protocolIndex")
        frameCount = 0; isViewing = true; lastJPEG = nil; imageView.image = nil
        placeholder.isHidden = false; snapshotButton.isEnabled = false
        playButton.isEnabled = false; stopButton.isEnabled = true
        dimensions.stringValue = "CONNECTING"
        video.start(host: host, modern: protocolMenu.indexOfSelectedItem == 1)
    }
    @objc func stopVideo() {
        video.stop(); isViewing = false
        playButton.isEnabled = true; stopButton.isEnabled = false
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
    func applicationWillTerminate(_ notification: Notification) { bluetooth.disconnect(); video.stop() }
}
extension NSBox {
    static func separator() -> NSBox { let box = NSBox(); box.boxType = .separator; return box }
}
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
