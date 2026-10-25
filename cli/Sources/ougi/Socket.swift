import Foundation

// Newline-delimited JSON over the daemon's Unix socket: one request, one response per connection.

func unixAddress(_ path: String) -> sockaddr_un {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &addr.sun_path) { buf in
        for (i, b) in path.utf8.prefix(buf.count - 1).enumerated() { buf[i] = b }
    }
    return addr
}

func setTimeout(_ fd: Int32, seconds: Int) {
    var tv = timeval(tv_sec: seconds, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
}

func readLine(_ fd: Int32) -> [String: Any]? {
    var data = Data()
    var buf = [UInt8](repeating: 0, count: 4096)
    while data.count < 1 << 20 {
        let n = read(fd, &buf, buf.count)
        if n <= 0 { break }
        data.append(contentsOf: buf[0..<n])
        if buf[n - 1] == UInt8(ascii: "\n") { break }
    }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

func writeLine(_ fd: Int32, _ object: [String: Any]) {
    guard var data = try? JSONSerialization.data(withJSONObject: object) else { return }
    data.append(UInt8(ascii: "\n"))
    data.withUnsafeBytes { buf in
        var offset = 0
        while offset < buf.count {
            let n = write(fd, buf.baseAddress! + offset, buf.count - offset)
            if n <= 0 { return }
            offset += n
        }
    }
}

/// Sends a request to the daemon. Throws if the daemon is not running.
func request(_ object: [String: Any]) throws -> [String: Any] {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw OugiError("socket failed") }
    defer { close(fd) }
    setTimeout(fd, seconds: 30) // switching fans to manual takes up to ~15 s
    var addr = unixAddress(socketPath)
    let connected = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard connected == 0 else { throw OugiError("daemon not running") }
    writeLine(fd, object)
    guard let response = readLine(fd) else { throw OugiError("no response from daemon") }
    if response["ok"] as? Bool != true { throw OugiError(response["error"] as? String ?? "daemon error") }
    return response
}
