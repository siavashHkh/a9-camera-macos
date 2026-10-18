import AppKit

extension AppDelegate {
    func makeGatewayControls() -> NSStackView {
        refreshGatewayInterfaces()
        gatewayCameraAddress.placeholderString = "Camera’s IP from your router"
        gatewayUID.placeholderString = "Camera UID from its label/hotspot"
        gatewayUID.stringValue = UserDefaults.standard.string(forKey:"gatewayUID") ?? ""
        gatewayCameraAddress.stringValue = UserDefaults.standard.string(forKey:"gatewayCameraAddress") ?? ""
        gatewayDNS.state = .off
        return stack([
            label("Home network video",size:15,bold:true),
            label("Station-mode V720 cameras connect to this Mac’s local gateway. Direct connections to the camera IP may be unavailable in this mode.",size:12,secondary:true),
            label("1  Choose this Mac’s network address",size:12,bold:true), gatewayInterface,
            button(NSButton(title:"Refresh network addresses",target:nil,action:nil),#selector(refreshGatewayInterfaces)),
            label("2  Identify your camera",size:12,bold:true), gatewayCameraAddress, gatewayUID,
            label("Use the router’s camera entry and the UID from the camera’s label or hotspot name. The gateway accepts only that IP and UID.",size:11,secondary:true),
            stack([button(gatewayStart,#selector(startGateway)),button(gatewayStop,#selector(stopVideo))],vertical:false,spacing:6),
            button(gatewayRelayCommand,#selector(copyGatewayRelayCommand)),
            label("macOS requires administrator approval for the camera’s legacy ports. Run the copied relay command in Terminal; it drops administrator privileges before receiving camera requests. Stop it with Control-C.",size:11,secondary:true),
            label("3  Route camera services locally",size:12,bold:true),
            label("In your router’s local DNS, map both names to this Mac’s selected IP:\nv720.naxclow.com\nv720.p2p.naxclow.com",size:12,secondary:true),
            label("The camera must receive these DNS answers. Changing only the Mac’s DNS does not configure the camera.",size:11,secondary:true),
            gatewayDNS,
            label("Optional DNS responder: use only when the router assigns this Mac as DNS directly to this camera. Other devices’ DNS requests are rejected.",size:11,secondary:true),
            label("Start the gateway, then restart the camera. Registration and video progress appear on the right. Keep the Mac awake and on this network.",size:11,secondary:true)
        ],spacing:10)
    }
    @objc func refreshGatewayInterfaces() {
        let old = gatewayInterface.selectedItem?.representedObject as? String
        gatewayInterface.removeAllItems()
        for item in CameraLocalNetwork.interfaces() {
            gatewayInterface.addItem(withTitle:"\(item.name) • \(item.address)")
            gatewayInterface.lastItem?.representedObject = item.address
        }
        if let old = old, let item = gatewayInterface.itemArray.first(where:{$0.representedObject as? String == old}) { gatewayInterface.select(item) }
    }
    @objc func copyGatewayRelayCommand() {
        guard let local = gatewayInterface.selectedItem?.representedObject as? String,
              CameraVideo.validLocalAddress(gatewayCameraAddress.stringValue) else {
            videoStatus.stringValue = "Choose this Mac’s address and enter the camera’s local IP first."; return
        }
        let path = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/A9CameraRelay").path
        let command = CameraRelayCommand.make(executable:path,local:local,camera:gatewayCameraAddress.stringValue,dns:gatewayDNS.state == .on)
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(command,forType:.string)
        videoStatus.stringValue = "Relay command copied. Review and run it in Terminal. macOS asks for your administrator password there; the relay then runs as your user."
    }
    @objc func startGateway() {
        guard !setupBusy, let local = gatewayInterface.selectedItem?.representedObject as? String,
              CameraLocalNetwork.interfaces().contains(where:{$0.address == local}) else {
            videoStatus.stringValue = "Choose a current local address for this Mac, then start the gateway."; return
        }
        var config = CameraGatewayConfiguration(localAddress:local,cameraAddress:gatewayCameraAddress.stringValue.trimmingCharacters(in:.whitespacesAndNewlines),deviceID:gatewayUID.stringValue.trimmingCharacters(in:.whitespacesAndNewlines),httpPort:8080,usesPortRelay:true)
        config.dnsPort = gatewayDNS.state == .on ? 1053 : nil
        do { try config.validate() } catch { videoStatus.stringValue = "Enter the camera’s local IP and UID before starting the gateway."; return }
        stopVideo(); clearViewer(); activeViewer = .gateway; isViewing = true
        UserDefaults.standard.set(config.deviceID,forKey:"gatewayUID")
        UserDefaults.standard.set(config.cameraAddress,forKey:"gatewayCameraAddress")
        dimensions.stringValue = "STARTING LOCAL GATEWAY"
        updateSetupControls(); gateway.start(config)
    }
}
