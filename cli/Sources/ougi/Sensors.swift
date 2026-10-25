import Foundation

// Names for SMC temperature keys whose meaning is known; everything else shows its raw key.
let knownNames: [String: String] = [
    // Apple Silicon
    "TB0T": "Battery", "TB1T": "Battery Cell 1", "TB2T": "Battery Cell 2",
    "TW0P": "Wi-Fi / Bluetooth",
    "TH0a": "SSD NAND A", "TH0b": "SSD NAND B", "TH0x": "SSD NAND",
    "TaLP": "Airflow Left", "TaRF": "Airflow Right", "TaLT": "Airflow Left 2", "TaRT": "Airflow Right 2",
    "TaLW": "Airflow Left 3", "TaRW": "Airflow Right 3", "TaTP": "Airflow Top",
    "Ts0P": "Palm Rest", "Ts1P": "Palm Rest 2",
    "TCHP": "Charger", "TCMz": "CPU Hottest",
    // Intel
    "TC0P": "CPU Proximity", "TC0D": "CPU Die", "TC0E": "CPU Die 2", "TC0F": "CPU Die 3", "TCXC": "CPU PECI",
    "TG0P": "GPU Proximity", "TG0D": "GPU Die", "TA0P": "Ambient", "TM0P": "Memory Proximity",
    "TPCD": "Platform Controller Hub",
]

// Groups in display order, matched by key prefix. More specific prefixes come first: the first match wins.
let groups: [(name: String, prefixes: [String])] = [
    ("Power", ["TCH", "TV", "TPMP", "TPSP", "TSCP", "TSG", "TMVR"]),
    ("CPU P-cores", ["TCMz", "Tp"]),
    ("CPU E-cores", ["Te"]),
    ("CPU", ["TC"]),
    ("GPU", ["Tg", "TG"]),
    ("Ambient", ["Ts0P", "Ts1P", "Ta", "TA"]),
    ("SoC", ["Ts"]),
    ("PMU Dies", ["TPD", "TRD", "TUD"]),
    ("Memory", ["TM"]),
    ("Storage", ["TH"]),
    ("Battery", ["TB"]),
    ("Wireless", ["TW"]),
]

let groupOrder = ["CPU P-cores", "CPU E-cores", "CPU", "GPU", "SoC", "PMU Dies", "Memory", "Ambient", "Storage",
                  "Battery", "Wireless", "Power", "Other"]

/// The groups whose temperature the overheat guard watches.
let hotGroups: Set = ["CPU P-cores", "CPU E-cores", "CPU", "GPU"]

func group(of key: String) -> String {
    groups.first { $0.prefixes.contains { key.hasPrefix($0) } }?.name ?? "Other"
}

/// Enumerating all SMC keys is the slow part (~0.4 s), so the key list is scanned once and reused.
struct Sensors {
    let smc: SMC
    let keys: [String]

    init(smc: SMC) {
        self.smc = smc
        var keys: [String] = []
        let count = (try? smc.keyCount()) ?? 0
        for i in 0..<count {
            guard let key = try? smc.key(at: i), key.hasPrefix("T"),
                  let (type, _) = try? smc.read(key), type == "flt " || type == "sp78"
            else { continue }
            keys.append(key)
        }
        self.keys = keys
    }

    private static func plausible(_ value: Double) -> Bool { value > 10 && value < 130 } // unpopulated sensors report ~5-8

    func read() -> [[String: Any]] {
        keys.compactMap { key in
            guard let value = try? smc.number(key), Self.plausible(value) else { return nil }
            return ["key": key, "name": knownNames[key] ?? key, "group": group(of: key), "value": value]
        }
    }

    /// Hottest CPU/GPU reading, for the overheat guard.
    func hottest() -> Double? {
        keys.lazy.filter { hotGroups.contains(group(of: $0)) }
            .compactMap { try? smc.number($0) }.filter(Self.plausible).max()
    }
}
