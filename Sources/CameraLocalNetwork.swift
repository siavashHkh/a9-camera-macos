import Foundation
import Darwin

struct CameraNetworkInterface {
    let name: String
    let address: String
}
enum CameraLocalNetwork {
    static func interfaces() -> [CameraNetworkInterface] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return [] }
        defer { freeifaddrs(head) }
        var result: [CameraNetworkInterface] = []
        var cursor = head
        while let item = cursor {
            defer { cursor = item.pointee.ifa_next }
            guard let addr = item.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  item.pointee.ifa_flags & UInt32(IFF_UP) != 0,
                  item.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            var copy = addr.withMemoryRebound(to:sockaddr_in.self,capacity:1){$0.pointee.sin_addr}
            var buffer = [CChar](repeating:0,count:Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET,&copy,&buffer,socklen_t(INET_ADDRSTRLEN)) != nil else { continue }
            let ip = String(cString:buffer)
            if CameraVideo.validLocalAddress(ip) { result.append(CameraNetworkInterface(name:String(cString:item.pointee.ifa_name),address:ip)) }
        }
        return result.sorted { ($0.name.hasPrefix("en") ? "0" : "1") + $0.name < ($1.name.hasPrefix("en") ? "0" : "1") + $1.name }
    }
}
