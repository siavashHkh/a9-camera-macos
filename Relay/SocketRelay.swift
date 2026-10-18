import Foundation
import Darwin

// Legacy ports are bound before privilege drop. No camera bytes are received
// until both real/effective user and group IDs have become the invoking user.
// No files, shell commands, vendor hosts, or persistent services are used.
struct RelayError: Error { let message: String }
func fail(_ text: String) -> Never { FileHandle.standardError.write(Data((text+"\n").utf8)); exit(1) }
func canonical(_ text: String) -> Bool {
    guard (7...15).contains(text.utf8.count) else { return false }
    let p = text.split(separator:".",omittingEmptySubsequences:false)
    guard p.count == 4, p.allSatisfy({ UInt8($0).map{String($0)} == String($0) }) else { return false }
    let n = p.map{Int($0)!}
    return n[0] == 127 || n[0] == 10 || (n[0] == 192 && n[1] == 168) || (n[0] == 172 && (16...31).contains(n[1])) || (n[0] == 169 && n[1] == 254)
}
func endpoint(_ ip: String, _ port: UInt16) -> sockaddr_in {
    var a = sockaddr_in(); a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); a.sin_family = sa_family_t(AF_INET); a.sin_port = port.bigEndian
    ip.withCString { _ = inet_pton(AF_INET,$0,&a.sin_addr) }; return a
}
func name(_ a: sockaddr_in) -> String {
    var addr = a.sin_addr; var bytes = [CChar](repeating:0,count:Int(INET_ADDRSTRLEN))
    guard inet_ntop(AF_INET,&addr,&bytes,socklen_t(bytes.count)) != nil else { return "" }
    return String(cString:bytes)
}
func socketBound(_ ip: String, _ port: UInt16, udp: Bool) throws -> Int32 {
    let fd = socket(AF_INET,udp ? SOCK_DGRAM : SOCK_STREAM,0)
    guard fd >= 0 else { throw RelayError(message:"Cannot create relay socket.") }
    var one: Int32 = 1
    if !udp { _ = setsockopt(fd,SOL_SOCKET,SO_REUSEADDR,&one,socklen_t(MemoryLayout<Int32>.size)) }
    var a = endpoint(ip,port)
    let result = withUnsafePointer(to:&a){$0.withMemoryRebound(to:sockaddr.self,capacity:1){Darwin.bind(fd,$0,socklen_t(MemoryLayout<sockaddr_in>.size))}}
    guard result == 0 else { Darwin.close(fd); throw RelayError(message:"Cannot bind \(udp ? "UDP" : "TCP") port \(port). Ports 80/53 require administrator approval; also check the IP and port availability.") }
    if !udp && Darwin.listen(fd,8) != 0 { Darwin.close(fd); throw RelayError(message:"Cannot listen for camera HTTP.") }
    _ = fcntl(fd,F_SETFL,fcntl(fd,F_GETFL) | O_NONBLOCK)
    return fd
}
func timeout(_ fd: Int32) {
    var t = timeval(tv_sec:2,tv_usec:0)
    _ = setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&t,socklen_t(MemoryLayout<timeval>.size))
    _ = setsockopt(fd,SOL_SOCKET,SO_SNDTIMEO,&t,socklen_t(MemoryLayout<timeval>.size))
    var one: Int32 = 1; _ = setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&one,socklen_t(MemoryLayout<Int32>.size))
}
func writeAll(_ fd: Int32, _ data: Data, deadline: Date) -> Bool {
    data.withUnsafeBytes { raw in
        guard let base = raw.baseAddress else { return true }; var sent = 0
        while sent < raw.count && Date() < deadline {
            let n = Darwin.send(fd,base.advanced(by:sent),raw.count-sent,0)
            if n > 0 { sent += n }
            else if n < 0 && errno == EINTR { continue }
            else { return false }
        }
        return sent == raw.count
    }
}
func requestLength(_ data: Data) throws -> Int? {
    guard data.count <= 12288 else { throw RelayError(message:"request limit") }
    guard let end = data.range(of:Data("\r\n\r\n".utf8)) else {
        guard data.count <= 8192 else { throw RelayError(message:"header limit") }; return nil
    }
    guard end.upperBound <= 8192, let header = String(data:data.prefix(end.lowerBound),encoding:.utf8), header.hasPrefix("POST /app/api/") else { throw RelayError(message:"request rejected") }
    var length: Int?
    for line in header.components(separatedBy:"\r\n").dropFirst() {
        guard let colon = line.firstIndex(of:":") else { throw RelayError(message:"header rejected") }
        let key = line[..<colon].lowercased(); let value = line[line.index(after:colon)...].trimmingCharacters(in:.whitespaces)
        if key == "transfer-encoding" { throw RelayError(message:"encoding rejected") }
        if key == "content-length" {
            guard length == nil, !value.isEmpty, value.utf8.allSatisfy({(48...57).contains($0)}), let n = Int(value), n <= 4096 else { throw RelayError(message:"body rejected") }; length = n
        }
    }
    return end.upperBound + (length ?? 0)
}
func connectBackend(_ port: UInt16) -> Int32? {
    let fd = socket(AF_INET,SOCK_STREAM,0); guard fd >= 0 else { return nil }
    var a = endpoint("127.0.0.1",port)
    _ = fcntl(fd,F_SETFL,O_NONBLOCK)
    let rc = withUnsafePointer(to:&a){$0.withMemoryRebound(to:sockaddr.self,capacity:1){Darwin.connect(fd,$0,socklen_t(MemoryLayout<sockaddr_in>.size))}}
    if rc != 0 {
        guard errno == EINPROGRESS else { Darwin.close(fd); return nil }
        var p = pollfd(fd:fd,events:Int16(POLLOUT),revents:0)
        var error: Int32 = 0; var size = socklen_t(MemoryLayout<Int32>.size)
        guard poll(&p,1,2000) > 0, getsockopt(fd,SOL_SOCKET,SO_ERROR,&error,&size) == 0, error == 0 else { Darwin.close(fd); return nil }
    }
    _ = fcntl(fd,F_SETFL,fcntl(fd,F_GETFL) & ~O_NONBLOCK); timeout(fd); return fd
}
func relayHTTP(_ client: Int32, target: UInt16) {
    defer { Darwin.close(client) }
    _ = fcntl(client,F_SETFL,fcntl(client,F_GETFL) & ~O_NONBLOCK); timeout(client)
    let deadline = Date().addingTimeInterval(10)
    var request = Data(); var buffer = [UInt8](repeating:0,count:4096)
    while Date() < deadline {
        let n = Darwin.recv(client,&buffer,buffer.count,0)
        guard n > 0 else { return }; request.append(contentsOf:buffer.prefix(n))
        do {
            if let total = try requestLength(request), request.count >= total {
                guard request.count == total, let backend = connectBackend(target) else { return }
                defer { Darwin.close(backend) }
                guard writeAll(backend,request,deadline:deadline) else { return }
                var responseBytes = 0
                while Date() < deadline {
                    let n = Darwin.recv(backend,&buffer,buffer.count,0)
                    if n == 0 { return }
                    guard n > 0 else { return }; responseBytes += n
                    guard responseBytes <= 16384, writeAll(client,Data(buffer.prefix(n)),deadline:deadline) else { return }
                }
                return
            }
        } catch { return }
    }
}
func relayDNS(_ packet: Data, client: sockaddr_in, socket listener: Int32, target: UInt16) {
    guard packet.count >= 12, packet.count <= 512 else { return }
    let fd = socket(AF_INET,SOCK_DGRAM,0); guard fd >= 0 else { return }; defer { Darwin.close(fd) }; timeout(fd)
    var backend = endpoint("127.0.0.1",target)
    let connected = withUnsafePointer(to:&backend){$0.withMemoryRebound(to:sockaddr.self,capacity:1){Darwin.connect(fd,$0,socklen_t(MemoryLayout<sockaddr_in>.size))}}
    guard connected == 0 else { return }
    let sent = packet.withUnsafeBytes{Darwin.send(fd,$0.baseAddress,$0.count,0)}
    guard sent == packet.count else { return }
    var bytes = [UInt8](repeating:0,count:513)
    let n = Darwin.recv(fd,&bytes,bytes.count,0)
    guard n >= 12, n <= 512, bytes[0] == packet[packet.startIndex], bytes[1] == packet[packet.startIndex+1] else { return }
    var destination = client
    _ = withUnsafePointer(to:&destination){ a in a.withMemoryRebound(to:sockaddr.self,capacity:1){ dest in
        bytes.withUnsafeBytes{Darwin.sendto(listener,$0.baseAddress,n,0,dest,socklen_t(MemoryLayout<sockaddr_in>.size))}
    }}
}
let args = Array(CommandLine.arguments.dropFirst())
var options: [String:String] = [:]; var index = 0
while index < args.count {
    guard index+1 < args.count, ["--listen","--camera","--http-target","--dns-target","--http-listen","--dns-listen"].contains(args[index]), options[args[index]] == nil else { fail("Usage: A9CameraRelay --listen MAC_IP --camera CAMERA_IP --http-target 8080 [--dns-target 1053]") }
    options[args[index]] = args[index+1]; index += 2
}
guard let local = options["--listen"], canonical(local), let camera = options["--camera"], canonical(camera),
      let http = UInt16(options["--http-target"] ?? ""), http >= 1024,
      let httpListen = UInt16(options["--http-listen"] ?? "80"), httpListen > 0,
      let dnsListen = UInt16(options["--dns-listen"] ?? "53"), dnsListen > 0 else { fail("Use canonical local IPv4 addresses and a valid nonprivileged HTTP target port.") }
let dnsTarget = options["--dns-target"].flatMap{UInt16($0)}
if options["--dns-target"] != nil && (dnsTarget == nil || dnsTarget! < 1024) { fail("Invalid DNS target port.") }
var descriptors: [Int32] = []
do {
    descriptors.append(try socketBound(local,httpListen,udp:false))
    if dnsTarget != nil { descriptors.append(try socketBound(local,dnsListen,udp:true)) }
} catch { for fd in descriptors { Darwin.close(fd) }; fail((error as? RelayError)?.message ?? "Cannot bind camera relay ports.") }
if getuid() == 0 || geteuid() == 0 {
    guard let userText = ProcessInfo.processInfo.environment["SUDO_UID"], let groupText = ProcessInfo.processInfo.environment["SUDO_GID"],
          let user = UInt32(userText), user > 0, let group = UInt32(groupText), group > 0,
          let account = getpwuid(user), account.pointee.pw_gid == group,
          setgroups(0,nil) == 0, setgid(group) == 0, setuid(user) == 0,
          getuid() == user, geteuid() == user, getgid() == group, getegid() == group else { fail("Refusing to process camera traffic: could not drop administrator privileges.") }
}
guard getuid() != 0 && geteuid() != 0 else { fail("Refusing to run the camera relay as root.") }
signal(SIGPIPE,SIG_IGN)
let queue = DispatchQueue(label:"local.a9.relay.accept")
let workers = DispatchSemaphore(value:4)
let dnsWorkers = DispatchSemaphore(value:4)
let httpFD = descriptors[0]
let httpSource = DispatchSource.makeReadSource(fileDescriptor:httpFD,queue:queue)
httpSource.setEventHandler {
    for _ in 0..<16 {
        var peer = sockaddr_in(); var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let client = withUnsafeMutablePointer(to:&peer){$0.withMemoryRebound(to:sockaddr.self,capacity:1){Darwin.accept(httpFD,$0,&size)}}
        if client < 0 { break }
        guard name(peer) == camera, workers.wait(timeout:.now()) == .success else { Darwin.close(client); continue }
        DispatchQueue.global(qos:.utility).async { relayHTTP(client,target:http); workers.signal() }
    }
}
httpSource.resume()
var dnsSource: DispatchSourceRead?
if let target = dnsTarget {
    let fd = descriptors[1]
    let source = DispatchSource.makeReadSource(fileDescriptor:fd,queue:queue); dnsSource = source
    source.setEventHandler {
        for _ in 0..<16 {
            var bytes = [UInt8](repeating:0,count:513); var peer = sockaddr_in(); var size = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to:&peer){$0.withMemoryRebound(to:sockaddr.self,capacity:1){Darwin.recvfrom(fd,&bytes,bytes.count,0,$0,&size)}}
            if n < 0 { break }
            guard (12...512).contains(n), name(peer) == camera, dnsWorkers.wait(timeout:.now()) == .success else { continue }
            let packet = Data(bytes.prefix(n)); let destination = peer
            DispatchQueue.global(qos:.utility).async { relayDNS(packet,client:destination,socket:fd,target:target); dnsWorkers.signal() }
        }
    }
    source.resume()
}
// Tests and the Terminal user can observe readiness without logging any payload.
FileHandle.standardOutput.write(Data("READY\n".utf8))
dispatchMain()
