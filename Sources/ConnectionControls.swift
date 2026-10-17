import AppKit

extension AppDelegate {
    func makeConnectionTabs() -> NSView {
        let cameraName = label("Look for Nax_… / A9 / V720", size: 15, bold: true)
        cameraName.isSelectable = true
        let hotspot = stack([
            label("Connect without Location access", size: 15, bold: true),
            label("1  Choose the camera’s Wi-Fi", size: 13, bold: true),
            label("Open the Mac’s Wi-Fi picker and join your camera’s hotspot. Names vary by model:", size: 12, secondary: true),
            cameraName,
            button(NSButton(title: "Choose Wi-Fi in macOS…", target: nil, action: nil), #selector(openWiFiSettings)),
            label("If the hotspot is missing, keep the camera powered on nearby and check again.", size: 11, secondary: true),
            NSBox.separator(),
            label("2  Open the camera video", size: 13, bold: true),
            label("After joining its Wi-Fi, connect to the camera’s usual address: 192.168.169.1.", size: 12, secondary: true),
            button(NSButton(title: "I joined camera Wi-Fi — connect", target: nil, action: nil), #selector(connectHotspotVideo)),
            NSBox.separator(),
            label("Already on your home network?", size: 13, bold: true),
            label("Enter the camera’s local IP on the right and click Start video.", size: 12, secondary: true),
            button(NSButton(title: "Return to home Wi-Fi…", target: nil, action: nil), #selector(openWiFiSettings)),
            label("The camera hotspot may interrupt internet. Use the Mac’s Wi-Fi picker to rejoin your home network afterward.", size: 11, secondary: true)
        ], spacing: 10)
        let bluetoothActions = stack([button(scanButton, #selector(scan)), button(connectButton, #selector(connectBluetooth))], vertical: false, spacing: 6)
        let home = stack([
            label("Give the camera your Wi-Fi details", size: 15, bold: true),
            label("Connect A9 over Bluetooth, then type your 2.4 GHz network name and password. Location access is not required.", size: 12, secondary: true),
            deviceMenu, bluetoothActions, bluetoothStatus,
            NSBox.separator(), label("Home Wi-Fi name (SSID)", size: 12, bold: true),
            ssid, password, button(setupButton, #selector(sendSetup)),
            label("Details are sent directly to the camera over Bluetooth. The app does not save passwords.", size: 11, secondary: true),
            NSBox.separator(),
            label("After setup", size: 13, bold: true),
            label("Keep the Mac on your home network. Enter the camera’s IP from your router on the right, then Start video.", size: 12, secondary: true),
            label("Account-free setup is experimental. Firmware may require vendor registration and may contact the vendor once online.", size: 11, secondary: true)
        ], spacing: 10)
        let tabs = NSTabView()
        tabs.tabViewType = .topTabsBezelBorder
        tabs.font = .systemFont(ofSize: 12)
        for (name, content) in [("Camera Wi-Fi", hotspot), ("Home Wi-Fi setup", home)] {
            let item = NSTabViewItem(identifier: name); item.label = name
            let container = NSView()
            container.addSubview(content); content.translatesAutoresizingMaskIntoConstraints = false
            for view in content.arrangedSubviews { fullWidth(view, in: content) }
            NSLayoutConstraint.activate([
                content.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
                content.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
                content.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
                content.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -14)
            ])
            item.view = container; tabs.addTabViewItem(item)
        }
        tabs.widthAnchor.constraint(equalToConstant: 340).isActive = true
        tabs.heightAnchor.constraint(equalToConstant: 545).isActive = true
        return tabs
    }
    @objc func connectHotspotVideo() {
        address.stringValue = "192.168.169.1"
        startVideo()
    }
    @objc func openWiFiSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.wifi-settings-extension") else { return }
        if !NSWorkspace.shared.open(url) {
            videoStatus.stringValue = "Open System Settings → Wi-Fi and select the camera’s network. Then return here to connect."
        }
    }
}
