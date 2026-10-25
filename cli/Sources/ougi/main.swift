import Foundation

let version = "1.0.0"

let usage = """
    ougi \(version) — Mac temperatures and fan control

    usage:
      ougi read                                  temperatures, fans and daemon state as JSON
      ougi fan <id|all> <auto|max|rpm|percent%>  set fan speed (needs the daemon)
      sudo ougi daemon install                   install the root daemon that enables fan control
      sudo ougi daemon uninstall                 remove it and return fans to system control
      ougi daemon status                         show whether the daemon is running
      ougi dump                                  print every SMC key (debugging)
      ougi version
    """

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("ougi: \(message)\n".utf8))
    exit(1)
}

func printJSON(_ value: Any) {
    let data = try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

func openSMC() -> SMC {
    do { return try SMC() } catch { fail("\(error)") }
}

let args = Array(CommandLine.arguments.dropFirst())

switch args.first {
case "read":
    var out: [String: Any] = ["version": version, "groups": groupOrder]
    if let reply = try? request(["cmd": "read"]) {
        // The daemon keeps the sensor key list cached, so this is much faster than scanning locally.
        out["sensors"] = reply["sensors"]
        out["fans"] = reply["fans"]
        out["daemon"] = reply["daemon"]
    } else {
        let smc = openSMC()
        out["sensors"] = Sensors(smc: smc).read()
        out["fans"] = Fans(smc: smc).all
    }
    printJSON(out)

case "fan":
    guard args.count == 3 else { fail("usage: ougi fan <id|all> <auto|max|rpm|percent%>") }
    do {
        let reply = try request(["cmd": "fan", "fan": args[1], "value": args[2]])
        printJSON(["fans": reply["fans"] ?? []])
    } catch let error as OugiError where error.description == "daemon not running" {
        guard geteuid() == 0 else { fail("fan control needs the daemon: sudo ougi daemon install") }
        let fans = Fans(smc: openSMC())
        do { try fans.set(try fans.ids(args[1]), args[2]) } catch { fail("\(error)") }
        printJSON(["fans": fans.all])
    } catch {
        fail("\(error)")
    }

case "daemon":
    switch args.dropFirst().first {
    case "install": installDaemon()
    case "uninstall": uninstallDaemon()
    case "run":
        do { try Daemon().run() } catch { fail("\(error)") }
    case "status":
        guard let reply = try? request(["cmd": "status"]), let daemon = reply["daemon"] as? [String: Any] else {
            print("not running — enable fan control with: sudo ougi daemon install")
            exit(1)
        }
        let daemonVersion = daemon["version"] as? String ?? "?"
        print("running, version \(daemonVersion)\(daemonVersion == version ? "" : " (this CLI is \(version): run sudo ougi daemon install to update)")")
        if let guardInfo = daemon["guard"] as? [String: Any] {
            print("overheat guard at \(guardInfo["threshold"] ?? guardThreshold)°C", terminator: "")
            if let trip = guardInfo["lastTrip"] as? [String: Any] { print(", last tripped \(trip["time"] ?? "")", terminator: "") }
            print()
        }
    default:
        fail("usage: sudo ougi daemon <install|uninstall> | ougi daemon status")
    }

case "dump":
    let smc = openSMC()
    for i in 0..<((try? smc.keyCount()) ?? 0) {
        guard let key = try? smc.key(at: i), let (type, bytes) = try? smc.read(key) else { continue }
        let value = (try? smc.number(key)).map { String($0) } ?? bytes.map { String(format: "%02x", $0) }.joined()
        print(key, type, value)
    }

case "version", "--version", "-v":
    print(version)

case "help", "--help", "-h", nil:
    print(usage)

default:
    fail("unknown command '\(args[0])'\n\n\(usage)")
}
