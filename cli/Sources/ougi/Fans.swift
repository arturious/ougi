import Foundation

struct OugiError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Fan control over SMC keys F<n>Ac/Mn/Mx/Tg plus either F<n>Md (Apple Silicon) or the FS! bitmask (Intel).
struct Fans {
    let smc: SMC

    var count: Int { Int((try? smc.number("FNum")) ?? 0) }
    private var hasModeKey: Bool { (try? smc.info("F0Md")) != nil }
    private var hasTestMode: Bool { (try? smc.info("Ftst")) != nil }

    private func key(_ id: Int, _ suffix: String) -> String { "F\(id)\(suffix)" }
    private func number(_ id: Int, _ suffix: String) -> Double? { try? smc.number(key(id, suffix)) }

    func ids(_ selector: String) throws -> [Int] {
        if selector == "all" { return Array(0..<count) }
        if let id = Int(selector), id >= 0, id < count { return [id] }
        throw OugiError("no fan '\(selector)' (this Mac has \(count))")
    }

    func isManual(_ id: Int) -> Bool {
        if hasModeKey { return number(id, "Md") == 1 }
        return forcedMask() & (1 << id) != 0
    }

    var anyManual: Bool { (0..<count).contains { isManual($0) } }

    func info(_ id: Int) -> [String: Any] {
        var info: [String: Any] = ["id": id, "manual": isManual(id)]
        info["actual"] = number(id, "Ac")
        info["min"] = number(id, "Mn")
        info["max"] = number(id, "Mx")
        info["target"] = number(id, "Tg")
        return info
    }

    var all: [[String: Any]] { (0..<count).map(info) }

    /// mode: "auto", "max", an RPM value, or a percentage of the min–max range like "50%".
    /// Returns the RPM applied to each fan put under manual control (SMC reads lag behind writes).
    @discardableResult
    func set(_ ids: [Int], _ mode: String) throws -> [Int: Double] {
        defer { leaveTestModeIfIdle() }
        var applied: [Int: Double] = [:]
        for id in ids {
            let min = number(id, "Mn") ?? 0, max = number(id, "Mx") ?? 0
            switch mode {
            case "auto":
                try setAuto(id)
            case "max":
                try setManual(id, rpm: max)
                applied[id] = max
            default:
                var rpm: Double
                if mode.hasSuffix("%"), let pct = Double(mode.dropLast()) {
                    rpm = min + (max - min) * pct / 100
                } else if let value = Double(mode) {
                    rpm = value
                } else {
                    throw OugiError("bad fan value '\(mode)' (use auto, max, <rpm> or <percent>%)")
                }
                rpm = Swift.min(Swift.max(rpm, min), max)
                try setManual(id, rpm: rpm)
                applied[id] = rpm
            }
        }
        return applied
    }

    // On Apple Silicon the mode key is locked by thermalmonitord until Ftst (fan test mode) is set. From the
    // system's own mode 3 it takes ~6 s after that: Md first drops to 0, and only then accepts 1.
    private func setManual(_ id: Int, rpm: Double) throws {
        if hasModeKey {
            if number(id, "Md") != 1 {
                if hasTestMode { try smc.writeNumber("Ftst", 1) }
                let ok = waitUntil(15) {
                    (try? smc.writeNumber(key(id, "Md"), 1)) != nil && number(id, "Md") == 1
                }
                if !ok { throw OugiError("fan \(id): could not switch to manual mode") }
            }
        } else {
            try writeForcedMask(forcedMask() | (1 << id))
        }
        try smc.writeNumber(key(id, "Tg"), rpm)
    }

    private func setAuto(_ id: Int) throws {
        if hasModeKey {
            try smc.writeNumber(key(id, "Md"), 0)
            // The SMC applies the mode change with a delay; wait so leaveTestModeIfIdle sees it.
            _ = waitUntil(2) { number(id, "Md") != 1 }
        } else {
            try writeForcedMask(forcedMask() & ~(1 << id))
        }
    }

    /// Fan test mode stays on only while some fan is manual; with it on, the system may not manage the fans.
    /// Written unconditionally: reading Ftst back lags behind writes by about a second.
    func leaveTestModeIfIdle() {
        guard hasTestMode, !anyManual else { return }
        try? smc.writeNumber("Ftst", 0)
    }

    private func forcedMask() -> Int {
        guard let (_, bytes) = try? smc.read("FS! "), bytes.count >= 2 else { return 0 }
        return Int(bytes[0]) << 8 | Int(bytes[1])
    }

    private func writeForcedMask(_ mask: Int) throws {
        try smc.write("FS! ", [UInt8((mask >> 8) & 0xff), UInt8(mask & 0xff)])
    }
}

func waitUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        usleep(100_000)
    }
    return condition()
}
