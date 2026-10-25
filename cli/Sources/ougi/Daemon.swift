import Foundation

let daemonLabel = "dev.ougi.daemon"
let daemonBinary = "/Library/PrivilegedHelperTools/ougi"
let daemonPlist = "/Library/LaunchDaemons/\(daemonLabel).plist"
let daemonLog = "/var/log/ougi.log"
let socketPath = "/var/run/ougi.sock"

/// Fans under manual control go back to automatic when the hottest CPU/GPU sensor reaches this.
/// OUGI_GUARD_THRESHOLD overrides it, for testing the guard without heating the Mac.
let guardThreshold = ProcessInfo.processInfo.environment["OUGI_GUARD_THRESHOLD"].flatMap(Double.init) ?? 95.0
let guardInterval = 2.0

func log(_ message: String) {
    let stamp = ISO8601DateFormatter().string(from: Date())
    FileHandle.standardError.write(Data("\(stamp) \(message)\n".utf8))
}

// MARK: - Daemon

/// Root daemon: owns all SMC writes, serves requests on a Unix socket and runs the overheat guard.
final class Daemon {
    private let queue = DispatchQueue(label: "ougi.smc") // SMC access is serialised on this queue
    private let smc: SMC
    private let fans: Fans
    private let sensors: Sensors
    private var lastTrip: [String: Any]?
    private var requested: [Int: Double] = [:] // RPM this daemon set per manual fan
    private var timer: DispatchSourceTimer?
    private var signalSources: [DispatchSourceSignal] = []

    init() throws {
        smc = try SMC()
        fans = Fans(smc: smc)
        sensors = Sensors(smc: smc)
    }

    func run() -> Never {
        guard geteuid() == 0 else { fail("the daemon must run as root") }
        queue.sync {
            // Manual state left over from a crash or an older daemon is not trusted.
            if fans.anyManual { try? fans.set(Array(0..<fans.count), "auto") }
        }
        log("ougi \(version) daemon started, \(fans.count) fans, \(sensors.keys.count) sensors")
        startGuard()
        handleSignals()
        let listener = listen()
        Thread.detachNewThread { [self] in acceptLoop(listener) }
        dispatchMain()
    }

    private func startGuard() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + guardInterval, repeating: guardInterval)
        timer.setEventHandler { [self] in checkTemperature() }
        timer.resume()
        self.timer = timer
    }

    private func checkTemperature() {
        guard fans.anyManual else {
            requested.removeAll()
            fans.leaveTestModeIfIdle()
            return
        }
        // Fans running at max already do everything the system could; only slower manual speeds are a risk.
        let slowed = requested.filter { id, rpm in rpm < (fans.info(id)["max"] as? Double ?? 0) - 1 }
        guard !slowed.isEmpty, let hottest = sensors.hottest(), hottest >= guardThreshold else { return }
        try? fans.set(Array(0..<fans.count), "auto")
        requested.removeAll()
        lastTrip = ["time": ISO8601DateFormatter().string(from: Date()), "temperature": hottest]
        log(String(format: "overheat guard: %.1f°C ≥ %.0f°C, fans returned to auto", hottest, guardThreshold))
    }

    private func handleSignals() {
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: queue)
            source.setEventHandler { [self] in
                if fans.anyManual { try? fans.set(Array(0..<fans.count), "auto") }
                unlink(socketPath)
                log("daemon stopped, fans returned to auto")
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    private func listen() -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { fail("socket: \(String(cString: strerror(errno)))") }
        unlink(socketPath)
        var addr = unixAddress(socketPath)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else { fail("bind \(socketPath): \(String(cString: strerror(errno)))") }
        chmod(socketPath, 0o666) // any local user may ask for fan changes; the daemon validates every request
        guard Darwin.listen(fd, 8) == 0 else { fail("listen: \(String(cString: strerror(errno)))") }
        return fd
    }

    private func acceptLoop(_ listener: Int32) {
        while true {
            let client = accept(listener, nil, nil)
            guard client >= 0 else { continue }
            setTimeout(client, seconds: 5)
            if let request = readLine(client) {
                let response = queue.sync { handle(request) }
                writeLine(client, response)
            }
            close(client)
        }
    }

    private func handle(_ request: [String: Any]) -> [String: Any] {
        switch request["cmd"] as? String {
        case "status":
            return ["ok": true, "daemon": status()]
        case "read":
            return ["ok": true, "daemon": status(), "sensors": sensors.read(), "fans": fans.all]
        case "fan":
            guard let selector = request["fan"] as? String, let value = request["value"] as? String else {
                return ["ok": false, "error": "fan request needs 'fan' and 'value'"]
            }
            do {
                let ids = try fans.ids(selector)
                let applied = try fans.set(ids, value)
                for id in ids { requested[id] = applied[id] }
                return ["ok": true, "fans": fans.all]
            } catch {
                return ["ok": false, "error": "\(error)"]
            }
        default:
            return ["ok": false, "error": "unknown command"]
        }
    }

    private func status() -> [String: Any] {
        var guardInfo: [String: Any] = ["threshold": guardThreshold]
        guardInfo["lastTrip"] = lastTrip
        return ["version": version, "guard": guardInfo]
    }
}

// MARK: - Install

func requireRoot(_ command: String) {
    guard geteuid() == 0 else { fail("run with sudo: sudo ougi daemon \(command)") }
}

@discardableResult
func launchctl(_ args: String...) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    p.arguments = args
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try? p.run()
    p.waitUntilExit()
    return p.terminationStatus
}

/// Copies this binary to a root-owned location (Homebrew's prefix is user-writable, so the daemon must
/// not run from there) and registers it with launchd.
func installDaemon() {
    requireRoot("install")
    guard let selfPath = Bundle.main.executablePath else { fail("cannot locate own executable") }
    let source = URL(fileURLWithPath: selfPath).resolvingSymlinksInPath().path
    let fm = FileManager.default

    launchctl("bootout", "system/\(daemonLabel)")
    do {
        try fm.createDirectory(atPath: "/Library/PrivilegedHelperTools", withIntermediateDirectories: true)
        if source != daemonBinary {
            try? fm.removeItem(atPath: daemonBinary)
            try fm.copyItem(atPath: source, toPath: daemonBinary)
        }
        try fm.setAttributes([.ownerAccountID: 0, .groupOwnerAccountID: 0, .posixPermissions: 0o755],
                             ofItemAtPath: daemonBinary)
        let plist: [String: Any] = [
            "Label": daemonLabel,
            "ProgramArguments": [daemonBinary, "daemon", "run"],
            "RunAtLoad": true,
            "KeepAlive": true,
            "StandardErrorPath": daemonLog,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: URL(fileURLWithPath: daemonPlist))
        try fm.setAttributes([.ownerAccountID: 0, .groupOwnerAccountID: 0, .posixPermissions: 0o644],
                             ofItemAtPath: daemonPlist)
    } catch {
        fail("install failed: \(error.localizedDescription)")
    }
    guard launchctl("bootstrap", "system", daemonPlist) == 0 else { fail("launchctl bootstrap failed, see \(daemonLog)") }
    guard waitUntil(10, { (try? request(["cmd": "status"])) != nil }) else { fail("daemon did not start, see \(daemonLog)") }
    print("ougi daemon \(version) installed and running — fan control is enabled")
}

func uninstallDaemon() {
    requireRoot("uninstall")
    launchctl("bootout", "system/\(daemonLabel)") // the daemon returns fans to auto on SIGTERM
    if let smc = try? SMC() {
        let fans = Fans(smc: smc)
        if fans.anyManual { try? fans.set(Array(0..<fans.count), "auto") }
    }
    for path in [daemonPlist, daemonBinary, socketPath] { try? FileManager.default.removeItem(atPath: path) }
    print("ougi daemon removed — fans are under system control")
}
