import Foundation
import Combine
import Darwin
import AppKit
import IOKit
import IOKit.ps
import IOKit.storage
import Metal
import SystemConfiguration

struct MetricSample: Identifiable {
    let id = UUID()
    let date: Date
    let cpu: Double
    let memory: Double
    var cpuPower: Double = 0
    var gpuPower: Double = 0
    var gpuUsage: Double = 0
    var chipPower: Double = 0
    var cpuTemperature: Double = 0
    var gpuTemperature: Double = 0
    var networkDownload: Double = 0
    var networkUpload: Double = 0
    var diskRead: Double = 0
    var diskWrite: Double = 0
}

struct MemoryPressureSample: Identifiable {
    let id = UUID()
    let date: Date
    let value: Double
}

struct GPUMemoryReading {
    let used: UInt64
    let total: UInt64

    var available: UInt64 { total > used ? total - used : 0 }
    var fraction: Double { total > 0 ? min(1, Double(used) / Double(total)) : 0 }
    let isUnifiedMemoryEstimate: Bool
}

struct MemoryCategoryReading: Identifiable {
    let name: String
    let bytes: UInt64
    var id: String { name }
}

struct DiskVolumeReading: Identifiable {
    let name: String
    let mountPath: String
    let totalBytes: UInt64
    let availableBytes: UInt64
    let isNetwork: Bool
    let isRemovable: Bool

    var id: String { mountPath }
    var usedBytes: UInt64 { totalBytes > availableBytes ? totalBytes - availableBytes : 0 }
    var usedFraction: Double { totalBytes > 0 ? min(1, Double(usedBytes) / Double(totalBytes)) : 0 }
}

struct NetworkInterfaceReading: Identifiable {
    let name: String
    let displayName: String
    let ipv4Addresses: [String]
    let ipv6Addresses: [String]

    var id: String { name }
}

private struct NetworkDetailsSnapshot {
    let interfaces: [NetworkInterfaceReading]
    let gateway: String?
    let gatewayInterface: String?
}

struct CPUCoreReading: Identifiable {
    let index: Int
    let name: String
    let usage: Double
    var id: Int { index }
}

struct ProcessReading: Identifiable {
    let pid: Int32
    let name: String
    let executablePath: String
    let bundlePath: String?
    let ownerUID: uid_t
    let cpu: Double
    let memory: UInt64
    let icon: NSImage?
    var id: Int32 { pid }

    var canTerminate: Bool {
        let protectedNames: Set<String> = ["launchd", "kernel_task", "windowserver", "loginwindow", "runningboardd", "securityd", "opendirectoryd", "dock", "finder", "controlcenter", "systemuiserver", "keitop", "mactop", "macmon"]
        return pid > 1 && pid != getpid() && ownerUID == getuid()
            && !protectedNames.contains(URL(fileURLWithPath: executablePath).lastPathComponent.lowercased())
    }
}

private struct RawProcess {
    let pid: Int32
    let ownerUID: uid_t
    let cpu: Double
    let memory: UInt64
    let command: String
}

private struct ByteCounters {
    var received: UInt64 = 0
    var sent: UInt64 = 0
}

private struct DiskCounters {
    var read: UInt64 = 0
    var written: UInt64 = 0
}

struct BatteryReading {
    let chargePercent: Double
    let healthPercent: Double?
    let isCharging: Bool
    let isOnAC: Bool
}

enum ProcessTerminationResult {
    case sent
    case notAllowed
    case processChanged
    case failed(String)
}

struct FanReading: Decodable, Identifiable {
    let name: String
    let rpm: Double?
    let max_rpm: Double?
    var id: String { name }

    private enum CodingKeys: String, CodingKey {
        case name, id, fan_id, rpm, current_rpm, max_rpm, maxRPM
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try values.decodeIfPresent(String.self, forKey: .name)
            ?? values.decodeIfPresent(String.self, forKey: .id)
            ?? values.decodeIfPresent(String.self, forKey: .fan_id)
            ?? "Fan"
        rpm = try values.decodeIfPresent(Double.self, forKey: .rpm)
            ?? values.decodeIfPresent(Double.self, forKey: .current_rpm)
        max_rpm = try values.decodeIfPresent(Double.self, forKey: .max_rpm)
            ?? values.decodeIfPresent(Double.self, forKey: .maxRPM)
    }
}

struct MacmonTemperature: Decodable {
    let cpu_temp_avg: Double?
    let gpu_temp_avg: Double?
}

struct MacmonMemory: Decodable {
    let ram_total: UInt64?
    let ram_usage: UInt64?
    let pressure_percent: Double?
}

struct MacmonSnapshot: Decodable {
    let temp: MacmonTemperature?
    let memory: MacmonMemory?
    let fans: [FanReading]?
    let cpu_scaled_ratio: Double?
    let cpu_active_ratio: Double?
    let gpu_scaled_ratio: Double?
    let gpu_freq_mhz: Double?
    let cpu_power: Double?
    let gpu_power: Double?
    let chip_power: Double?
}

private struct MactopSoC: Decodable {
    let cpu_power: Double?
    let gpu_power: Double?
    let total_power: Double?
    let gpu_freq_mhz: Double?
    let cpu_temp: Double?
    let gpu_temp: Double?
}

private struct MactopMemory: Decodable {
    let total: UInt64?
    let used: UInt64?
    let available: UInt64?
    let swap_total: UInt64?
    let swap_used: UInt64?
}

private struct MactopSystemInfo: Decodable {
    let name: String?
    let core_count: Int?
    let e_core_count: Int?
    let p_core_count: Int?
    let s_core_count: Int?
    let gpu_core_count: Int?
}

private struct MactopSnapshot: Decodable {
    let soc_metrics: MactopSoC?
    let memory: MactopMemory?
    let cpu_usage: Double?
    let core_usages: [Double]?
    let system_info: MactopSystemInfo?
    let gpu_usage: Double?
    let fans: [FanReading]?
    let cpu_temp: Double?
    let gpu_temp: Double?

    var normalized: SensorSnapshot {
        let coreUsages = core_usages ?? []
        let systemInfo = system_info
        let eCount = systemInfo?.e_core_count ?? 0
        let pCount = systemInfo?.p_core_count ?? 0
        let sCount = systemInfo?.s_core_count ?? 0
        let cpuCores = coreUsages.enumerated().map { index, usage -> CPUCoreReading in
            let name: String
            if index < eCount {
                name = "E-Core \(index + 1)"
            } else if index < eCount + pCount {
                name = "P-Core \(index - eCount + 1)"
            } else if index < eCount + pCount + sCount {
                name = "S-Core \(index - eCount - pCount + 1)"
            } else {
                name = "Core \(index + 1)"
            }
            return CPUCoreReading(index: index, name: name, usage: usage)
        }
        return SensorSnapshot(
            // mactop can report 0 when an individual power channel is not
            // available on the current model. Don't present that as a real
            // zero-watt reading while the rest of the SoC is active.
            cpuPower: soc_metrics?.cpu_power.flatMap { $0 > 0 ? $0 : nil },
            gpuPower: soc_metrics?.gpu_power,
            chipPower: soc_metrics?.total_power,
            cpuUsage: cpu_usage,
            gpuUsage: gpu_usage,
            gpuFrequency: soc_metrics?.gpu_freq_mhz,
            cpuTemperature: cpu_temp ?? soc_metrics?.cpu_temp,
            gpuTemperature: gpu_temp ?? soc_metrics?.gpu_temp,
            memoryUsed: memory?.used,
            memoryTotal: memory?.total,
            memoryAvailable: memory?.available,
            swapUsed: memory?.swap_used,
            swapTotal: memory?.swap_total,
            memoryPressure: nil,
            fans: fans ?? [],
            cpuCores: cpuCores,
            cpuModel: systemInfo?.name,
            cpuCoreCount: systemInfo?.core_count,
            gpuCoreCount: systemInfo?.gpu_core_count
        )
    }
}

struct SensorSnapshot {
    let cpuPower: Double?
    let gpuPower: Double?
    let chipPower: Double?
    let cpuUsage: Double?
    let gpuUsage: Double?
    let gpuFrequency: Double?
    let cpuTemperature: Double?
    let gpuTemperature: Double?
    let memoryUsed: UInt64?
    let memoryTotal: UInt64?
    let memoryAvailable: UInt64?
    let swapUsed: UInt64?
    let swapTotal: UInt64?
    let memoryPressure: Double?
    let fans: [FanReading]
    let cpuCores: [CPUCoreReading]?
    let cpuModel: String?
    let cpuCoreCount: Int?
    let gpuCoreCount: Int?

    init(
        cpuPower: Double?, gpuPower: Double?, chipPower: Double?, cpuUsage: Double?, gpuUsage: Double?,
        gpuFrequency: Double?, cpuTemperature: Double?, gpuTemperature: Double?, memoryUsed: UInt64?,
        memoryTotal: UInt64?, memoryAvailable: UInt64? = nil, swapUsed: UInt64? = nil,
        swapTotal: UInt64? = nil, memoryPressure: Double?, fans: [FanReading],
        cpuCores: [CPUCoreReading]? = nil, cpuModel: String? = nil,
        cpuCoreCount: Int? = nil, gpuCoreCount: Int? = nil
    ) {
        self.cpuPower = cpuPower
        self.gpuPower = gpuPower
        self.chipPower = chipPower
        self.cpuUsage = cpuUsage
        self.gpuUsage = gpuUsage
        self.gpuFrequency = gpuFrequency
        self.cpuTemperature = cpuTemperature
        self.gpuTemperature = gpuTemperature
        self.memoryUsed = memoryUsed
        self.memoryTotal = memoryTotal
        self.memoryAvailable = memoryAvailable
        self.swapUsed = swapUsed
        self.swapTotal = swapTotal
        self.memoryPressure = memoryPressure
        self.fans = fans
        self.cpuCores = cpuCores
        self.cpuModel = cpuModel
        self.cpuCoreCount = cpuCoreCount
        self.gpuCoreCount = gpuCoreCount
    }

    init(macmon: MacmonSnapshot) {
        cpuPower = macmon.cpu_power
        gpuPower = macmon.gpu_power
        chipPower = macmon.chip_power
        cpuUsage = macmon.cpu_active_ratio.map { $0 * 100 }
        gpuUsage = macmon.gpu_scaled_ratio.map { $0 * 100 }
        gpuFrequency = macmon.gpu_freq_mhz
        cpuTemperature = macmon.temp?.cpu_temp_avg
        gpuTemperature = macmon.temp?.gpu_temp_avg
        memoryUsed = macmon.memory?.ram_usage
        memoryTotal = macmon.memory?.ram_total
        memoryAvailable = nil
        swapUsed = nil
        swapTotal = nil
        memoryPressure = macmon.memory?.pressure_percent
        fans = macmon.fans ?? []
        cpuCores = nil
        cpuModel = nil
        cpuCoreCount = nil
        gpuCoreCount = nil
    }
}

private final class SensorRunner {
    private let process = Process()
    private let stdout = Pipe()
    private let stderr = Pipe()
    private var pending = Data()
    private var lastDiagnostic = ""
    private let lock = NSLock()

    func start(
        interval: Double,
        onSnapshot: @escaping (SensorSnapshot) -> Void,
        onStatus: @escaping (String) -> Void
    ) {
        let candidates = [
            ("/opt/homebrew/bin/mactop", "mactop"), ("/usr/local/bin/mactop", "mactop"),
            ("/opt/homebrew/bin/macmon", "macmon"), ("/usr/local/bin/macmon", "macmon")
        ]
        guard let candidate = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.0) }) else {
            onStatus("未找到 mactop 或 macmon。安装任一工具即可读取芯片传感器")
            return
        }

        let (executable, backend) = candidate
        process.executableURL = URL(fileURLWithPath: executable)
        if backend == "mactop" {
            process.arguments = ["--headless", "--format", "json", "--count", "0", "--interval", "\(Int(interval * 1000))"]
        } else {
            process.arguments = ["pipe", "--samples", "0", "--interval", "\(Int(interval * 1000))"]
        }
        process.standardOutput = stdout
        process.standardError = stderr

        // mactop writes its log under ~/.mactop by default. Give it a private,
        // writable state/config location so the monitor doesn't need home-folder access.
        let xdgRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("MacStatus", isDirectory: true)
        let stateURL = xdgRoot.appendingPathComponent("state", isDirectory: true)
        let configURL = xdgRoot.appendingPathComponent("config", isDirectory: true)
        try? FileManager.default.createDirectory(at: stateURL.appendingPathComponent("mactop", isDirectory: true), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: configURL.appendingPathComponent("mactop", isDirectory: true), withIntermediateDirectories: true)
        var environment = ProcessInfo.processInfo.environment
        environment["XDG_STATE_HOME"] = stateURL.path
        environment["XDG_CONFIG_HOME"] = configURL.path
        process.environment = environment

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            self?.consume(chunk, backend: backend, onSnapshot: onSnapshot)
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty else { return }
            self.storeDiagnostic(message)
            onStatus("\(backend): \(message)")
        }
        process.terminationHandler = { process in
            if process.terminationStatus != 0 {
                let remaining = self.stderr.fileHandleForReading.readDataToEndOfFile()
                if let tail = String(data: remaining, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !tail.isEmpty {
                    self.storeDiagnostic(tail)
                }
                let diagnostic = self.readDiagnostic()
                onStatus(diagnostic.isEmpty ? "\(backend) 退出，状态码 \(process.terminationStatus)" : "\(backend)：\(diagnostic)")
            }
        }
        do {
            try process.run()
            onStatus("正在连接 \(backend) · 只读传感器")
        } catch {
            onStatus("启动 \(backend) 失败：\(error.localizedDescription)")
        }
    }

    private func storeDiagnostic(_ message: String) {
        lock.lock()
        lastDiagnostic = message
        lock.unlock()
    }

    private func readDiagnostic() -> String {
        lock.lock()
        defer { lock.unlock() }
        return lastDiagnostic
    }

    private func consume(_ data: Data, backend: String, onSnapshot: @escaping (SensorSnapshot) -> Void) {
        lock.lock()
        pending.append(data)
        var lines = [Data]()
        while let newline = pending.firstIndex(of: 10) {
            lines.append(Data(pending[..<newline]))
            pending.removeSubrange(...newline)
        }
        lock.unlock()

        let decoder = JSONDecoder()
        for line in lines where !line.isEmpty {
            if backend == "mactop" {
                if let array = try? decoder.decode([MactopSnapshot].self, from: line), let latest = array.last {
                    onSnapshot(latest.normalized)
                } else if let one = try? decoder.decode(MactopSnapshot.self, from: line) {
                    onSnapshot(one.normalized)
                }
            } else if let snapshot = try? decoder.decode(MacmonSnapshot.self, from: line) {
                onSnapshot(SensorSnapshot(macmon: snapshot))
            }
        }
    }
}

@MainActor
final class SystemMonitor: ObservableObject {
    @Published var cpuUsage: Double = 0
    @Published var memoryUsed: UInt64 = 0
    @Published var memoryTotal: UInt64 = ProcessInfo.processInfo.physicalMemory
    @Published var memoryAvailable: UInt64 = ProcessInfo.processInfo.physicalMemory
    @Published var memoryWired: UInt64 = 0
    @Published var memoryActive: UInt64 = 0
    @Published var memoryCached: UInt64 = 0
    @Published var memoryCompressed: UInt64 = 0
    @Published var memoryFree: UInt64 = 0
    @Published var swapUsed: UInt64 = 0
    @Published var swapTotal: UInt64 = 0
    @Published var memoryPressureLevel: Int?
    @Published var memoryPressureSamples: [MemoryPressureSample] = []
    @Published var gpuMemory: GPUMemoryReading?
    @Published var thermalState: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState
    @Published var samples: [MetricSample] = []
    @Published var records: [MetricSample] = []
    @Published var refreshSeconds = 2.0
    @Published var sensorStatus = "正在寻找传感器后端…"
    @Published var sensorConnected = false
    @Published var cpuPower: Double?
    @Published var gpuPower: Double?
    @Published var chipPower: Double?
    @Published var cpuTemperature: Double?
    @Published var gpuTemperature: Double?
    @Published var gpuFrequency: Double?
    @Published var gpuUsage: Double?
    @Published var memoryPressure: Double?
    @Published var fans: [FanReading] = []
    @Published var cpuCores: [CPUCoreReading] = []
    @Published var cpuModel: String?
    @Published var cpuCoreCount: Int?
    @Published var gpuCoreCount: Int?
    @Published var processes: [ProcessReading] = []
    @Published var networkDownloadMBps: Double = 0
    @Published var networkUploadMBps: Double = 0
    @Published var diskReadMBps: Double = 0
    @Published var diskWriteMBps: Double = 0
    @Published var battery: BatteryReading?
    @Published var diskVolumes: [DiskVolumeReading] = []
    @Published var networkInterfaces: [NetworkInterfaceReading] = []
    @Published var defaultGateway: String?
    @Published var gatewayInterface: String?

    private var timer: Timer?
    private var previousTicks: (UInt32, UInt32, UInt32, UInt32)?
    private var previousNetwork: ByteCounters?
    private var previousDisk: DiskCounters?
    private var previousCounterDate: Date?
    private var processIconCache: [String: NSImage] = [:]
    private let sensorRunner = SensorRunner()
    private var lastVolumeScan = Date.distantPast
    private var volumeScanInProgress = false
    private var lastNetworkScan = Date.distantPast
    private var networkScanInProgress = false

    init() {
        refresh()
        start()
        sensorRunner.start(interval: refreshSeconds, onSnapshot: { [weak self] snapshot in
            Task { @MainActor in self?.apply(snapshot) }
        }, onStatus: { [weak self] status in
            Task { @MainActor in self?.sensorStatus = status }
        })
    }

    var memoryFraction: Double {
        guard memoryTotal > 0 else { return 0 }
        return min(1, Double(memoryUsed) / Double(memoryTotal))
    }

    var memoryComposition: [MemoryCategoryReading] {
        let raw = [
            MemoryCategoryReading(name: "Wired", bytes: memoryWired),
            MemoryCategoryReading(name: "Used", bytes: memoryActive),
            MemoryCategoryReading(name: "Cache", bytes: memoryCached),
            MemoryCategoryReading(name: "Free", bytes: memoryFree)
        ]
        let rawTotal = raw.reduce(UInt64(0)) { $0 &+ $1.bytes }
        guard memoryTotal > 0, rawTotal > memoryTotal else {
            return raw + [MemoryCategoryReading(name: "Other", bytes: memoryTotal > rawTotal ? memoryTotal - rawTotal : 0)]
        }

        // Some VM counters are not mutually exclusive on every macOS release.
        // Scale their proportions to physical memory so the bar always totals 100%.
        var normalized = raw.map {
            MemoryCategoryReading(name: $0.name, bytes: UInt64((Double($0.bytes) / Double(rawTotal)) * Double(memoryTotal)))
        }
        let normalizedTotal = normalized.reduce(UInt64(0)) { $0 &+ $1.bytes }
        normalized.append(MemoryCategoryReading(name: "Other", bytes: memoryTotal - normalizedTotal))
        return normalized
    }

    var systemVolume: DiskVolumeReading? { diskVolumes.first { $0.mountPath == "/" } }
    var networkVolumes: [DiskVolumeReading] { diskVolumes.filter(\.isNetwork) }
    var removableVolumes: [DiskVolumeReading] { diskVolumes.filter { $0.isRemovable && !$0.isNetwork && $0.mountPath != "/" } }

    var cpuSpecification: String? {
        guard let cpuModel else { return nil }
        let cpuCores = cpuCoreCount.map { "\($0)C CPU" }
        let gpuCores = gpuCoreCount.map { "\($0)C GPU" }
        let counts = [cpuCores, gpuCores].compactMap { $0 }.joined(separator: " + ")
        return counts.isEmpty ? cpuModel : "\(cpuModel) (\(counts))"
    }

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: refreshSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func setInterval(_ value: Double) {
        refreshSeconds = value
        start()
    }

    func refresh() {
        cpuUsage = readCPUUsage()
        readProcesses()
        updateSystemIO()
        battery = readBattery()
        refreshNativeMemoryDetails()
        gpuMemory = readGPUMemory()
        refreshDiskVolumesIfNeeded()
        refreshNetworkDetailsIfNeeded()
        // Once mactop/macmon is connected, keep using its memory definition so
        // the displayed percentage and history chart don't jump between APIs.
        if !sensorConnected {
            memoryUsed = readMemoryUsed()
            memoryAvailable = memoryTotal > memoryUsed ? memoryTotal - memoryUsed : 0
        }
        thermalState = ProcessInfo.processInfo.thermalState
        let sample = MetricSample(date: .now, cpu: cpuUsage, memory: memoryFraction * 100, cpuPower: cpuPower ?? 0, gpuPower: gpuPower ?? 0, gpuUsage: gpuUsage ?? 0, chipPower: chipPower ?? 0, cpuTemperature: cpuTemperature ?? 0, gpuTemperature: gpuTemperature ?? 0, networkDownload: networkDownloadMBps, networkUpload: networkUploadMBps, diskRead: diskReadMBps, diskWrite: diskWriteMBps)
        samples.append(sample)
        if samples.count > 60 { samples.removeFirst(samples.count - 60) }
    }

    private func readProcesses() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let task = Foundation.Process()
            let output = Pipe()
            task.executableURL = URL(fileURLWithPath: "/bin/ps")
            task.arguments = ["-axo", "pid=,uid=,%cpu=,rss=,command="]
            task.standardOutput = output
            task.standardError = FileHandle.nullDevice
            do {
                try task.run()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                task.waitUntilExit()
                guard task.terminationStatus == 0, let text = String(data: data, encoding: .utf8) else { return }
                let rows = text.split(whereSeparator: \.isNewline).compactMap { line -> RawProcess? in
                    let columns = line.split(maxSplits: 4, whereSeparator: \.isWhitespace)
                    guard columns.count == 5,
                          let pid = Int32(columns[0]), let ownerUID = uid_t(columns[1]),
                          let cpu = Double(columns[2]), let rssKB = UInt64(columns[3]) else { return nil }
                    return RawProcess(pid: pid, ownerUID: ownerUID, cpu: cpu, memory: rssKB * 1024, command: String(columns[4]))
                }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.processes = self.makeProcessRows(rows)
                }
            } catch {
                return
            }
        }
    }

    private func makeProcessRows(_ rows: [RawProcess]) -> [ProcessReading] {
        rows.map { row in
            let runningApp = NSRunningApplication(processIdentifier: row.pid)
            let executablePath = processExecutablePath(row.pid) ?? row.command.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? row.command
            let bundlePath = runningApp?.bundleURL?.path ?? appBundlePath(containing: executablePath)
            let bundle = bundlePath.flatMap { Bundle(url: URL(fileURLWithPath: $0)) }
            let fullName = runningApp?.localizedName
                ?? bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
                ?? URL(fileURLWithPath: executablePath).lastPathComponent
            let iconKey = bundlePath ?? executablePath
            let icon = processIconCache[iconKey] ?? runningApp?.icon ?? NSWorkspace.shared.icon(forFile: bundlePath ?? executablePath)
            processIconCache[iconKey] = icon
            return ProcessReading(pid: row.pid, name: fullName, executablePath: executablePath, bundlePath: bundlePath, ownerUID: row.ownerUID, cpu: row.cpu, memory: row.memory, icon: icon)
        }.sorted { $0.memory > $1.memory }
    }

    private func appBundlePath(containing executablePath: String) -> String? {
        let components = URL(fileURLWithPath: executablePath).pathComponents
        var current = ""
        for component in components {
            current = (current as NSString).appendingPathComponent(component)
            if component.hasSuffix(".app") { return current }
        }
        return nil
    }

    private func processExecutablePath(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let result = buffer.withUnsafeMutableBufferPointer { pointer in
            proc_pidpath(pid, pointer.baseAddress, UInt32(pointer.count))
        }
        guard result > 0 else { return nil }
        return String(cString: buffer)
    }

    func terminateProcess(_ process: ProcessReading, force: Bool = false) -> ProcessTerminationResult {
        guard process.canTerminate else { return .notAllowed }
        guard processExecutablePath(process.pid) == process.executablePath else { return .processChanged }
        let signal = force ? SIGKILL : SIGTERM
        guard kill(process.pid, signal) == 0 else { return .failed(String(cString: strerror(errno))) }
        refresh()
        return .sent
    }

    func isStillRunning(_ process: ProcessReading) -> Bool {
        guard processExecutablePath(process.pid) == process.executablePath else { return false }
        return kill(process.pid, 0) == 0 || errno == EPERM
    }

    private func updateSystemIO() {
        let now = Date()
        let network = readNetworkCounters()
        let disk = readDiskCounters()
        if let previousCounterDate, let previousNetwork, let previousDisk {
            let elapsed = max(0.5, now.timeIntervalSince(previousCounterDate))
            networkDownloadMBps = Double(delta(network.received, previousNetwork.received)) / elapsed / 1_048_576
            networkUploadMBps = Double(delta(network.sent, previousNetwork.sent)) / elapsed / 1_048_576
            diskReadMBps = Double(delta(disk.read, previousDisk.read)) / elapsed / 1_048_576
            diskWriteMBps = Double(delta(disk.written, previousDisk.written)) / elapsed / 1_048_576
        }
        previousNetwork = network
        previousDisk = disk
        previousCounterDate = now
    }

    private func delta(_ current: UInt64, _ previous: UInt64) -> UInt64 {
        current >= previous ? current - previous : 0
    }

    private func readNetworkCounters() -> ByteCounters {
        var counters = ByteCounters()
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return counters }
        defer { freeifaddrs(head) }
        var current: UnsafeMutablePointer<ifaddrs>? = first
        var countedInterfaces = Set<String>()
        let virtualPrefixes = ["lo", "utun", "awdl", "llw", "bridge", "gif", "stf", "p2p"]
        while let item = current {
            let entry = item.pointee
            if let namePointer = entry.ifa_name, let dataPointer = entry.ifa_data,
               entry.ifa_flags & UInt32(IFF_LOOPBACK) == 0 {
                let name = String(cString: namePointer)
                if !virtualPrefixes.contains(where: name.hasPrefix), countedInterfaces.insert(name).inserted {
                    let data = dataPointer.assumingMemoryBound(to: if_data.self).pointee
                    counters.received &+= UInt64(data.ifi_ibytes)
                    counters.sent &+= UInt64(data.ifi_obytes)
                }
            }
            current = entry.ifa_next
        }
        return counters
    }

    private func readDiskCounters() -> DiskCounters {
        var counters = DiskCounters()
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(kIOBlockStorageDriverClass), &iterator) == KERN_SUCCESS else { return counters }
        defer { IOObjectRelease(iterator) }
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            defer { IOObjectRelease(service) }
            var unmanagedProperties: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &unmanagedProperties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let properties = unmanagedProperties?.takeRetainedValue() as? [String: Any],
                  let statistics = properties[kIOBlockStorageDriverStatisticsKey] as? [String: Any] else { continue }
            counters.read &+= (statistics[kIOBlockStorageDriverStatisticsBytesReadKey] as? NSNumber)?.uint64Value ?? 0
            counters.written &+= (statistics[kIOBlockStorageDriverStatisticsBytesWrittenKey] as? NSNumber)?.uint64Value ?? 0
        }
        return counters
    }

    private func readBattery() -> BatteryReading? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef],
              let source = sources.first,
              let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
              let current = (description[kIOPSCurrentCapacityKey] as? NSNumber)?.doubleValue,
              let maximum = (description[kIOPSMaxCapacityKey] as? NSNumber)?.doubleValue,
              maximum > 0 else { return nil }
        let charge = min(100, current / maximum * 100)
        let charging = description[kIOPSIsChargingKey] as? Bool ?? false
        let sourceState = description[kIOPSPowerSourceStateKey] as? String
        let health = readBatteryHealth()
        return BatteryReading(chargePercent: charge, healthPercent: health, isCharging: charging, isOnAC: sourceState == kIOPSACPowerValue)
    }

    private func readBatteryHealth() -> Double? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var unmanagedProperties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &unmanagedProperties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let properties = unmanagedProperties?.takeRetainedValue() as? [String: Any],
              let design = (properties["DesignCapacity"] as? NSNumber)?.doubleValue,
              let maximum = (properties["MaxCapacity"] as? NSNumber)?.doubleValue,
              design > 0 else { return nil }
        return min(100, maximum / design * 100)
    }

    private func apply(_ snapshot: SensorSnapshot) {
        // Avoid mixing native and backend memory readings in the same chart.
        if !sensorConnected { samples.removeAll() }
        if let value = snapshot.cpuUsage { cpuUsage = value }
        if let value = snapshot.memoryUsed { memoryUsed = value }
        if let value = snapshot.memoryTotal { memoryTotal = value }
        if let value = snapshot.memoryAvailable { memoryAvailable = value }
        else { memoryAvailable = memoryTotal > memoryUsed ? memoryTotal - memoryUsed : 0 }
        if let value = snapshot.swapUsed { swapUsed = value }
        if let value = snapshot.swapTotal { swapTotal = value }
        cpuPower = snapshot.cpuPower
        gpuPower = snapshot.gpuPower
        chipPower = snapshot.chipPower
        cpuTemperature = snapshot.cpuTemperature
        gpuTemperature = snapshot.gpuTemperature
        gpuFrequency = snapshot.gpuFrequency
        gpuUsage = snapshot.gpuUsage
        if let cores = snapshot.cpuCores { cpuCores = cores }
        if let model = snapshot.cpuModel { cpuModel = model }
        if let count = snapshot.cpuCoreCount { cpuCoreCount = count }
        if let count = snapshot.gpuCoreCount { gpuCoreCount = count }
        memoryPressure = snapshot.memoryPressure
        if let pressure = snapshot.memoryPressure {
            memoryPressureSamples.append(MemoryPressureSample(date: .now, value: min(100, max(0, pressure))))
            if memoryPressureSamples.count > 90 { memoryPressureSamples.removeFirst(memoryPressureSamples.count - 90) }
        }
        fans = snapshot.fans
        sensorConnected = true
        sensorStatus = "传感器已连接 · 实时采样"
        if let last = samples.indices.last {
            samples[last] = MetricSample(date: samples[last].date, cpu: cpuUsage, memory: memoryFraction * 100, cpuPower: cpuPower ?? 0, gpuPower: gpuPower ?? 0, gpuUsage: gpuUsage ?? 0, chipPower: chipPower ?? 0, cpuTemperature: cpuTemperature ?? 0, gpuTemperature: gpuTemperature ?? 0, networkDownload: networkDownloadMBps, networkUpload: networkUploadMBps, diskRead: diskReadMBps, diskWrite: diskWriteMBps)
        }
    }

    func saveRecord() {
        records.insert(MetricSample(date: .now, cpu: cpuUsage, memory: memoryFraction * 100, gpuUsage: gpuUsage ?? 0, chipPower: chipPower ?? 0), at: 0)
    }

    private func readCPUUsage() -> Double {
        var count = mach_msg_type_number_t(0)
        var info: processor_info_array_t?
        var cpuCount: natural_t = 0
        let result = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &count)
        guard result == KERN_SUCCESS, let info else { return cpuUsage }
        defer { vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)), vm_size_t(count) * vm_size_t(MemoryLayout<integer_t>.size)) }

        var user: UInt32 = 0, system: UInt32 = 0, idle: UInt32 = 0, nice: UInt32 = 0
        for cpu in 0..<Int(cpuCount) {
            let offset = cpu * Int(CPU_STATE_MAX)
            user &+= UInt32(bitPattern: info[offset + Int(CPU_STATE_USER)])
            system &+= UInt32(bitPattern: info[offset + Int(CPU_STATE_SYSTEM)])
            idle &+= UInt32(bitPattern: info[offset + Int(CPU_STATE_IDLE)])
            nice &+= UInt32(bitPattern: info[offset + Int(CPU_STATE_NICE)])
        }
        let current = (user, system, idle, nice)
        defer { previousTicks = current }
        guard let previousTicks else { return 0 }
        let total = (current.0 &- previousTicks.0) &+ (current.1 &- previousTicks.1) &+ (current.2 &- previousTicks.2) &+ (current.3 &- previousTicks.3)
        guard total > 0 else { return 0 }
        let busy = (current.0 &- previousTicks.0) &+ (current.1 &- previousTicks.1) &+ (current.3 &- previousTicks.3)
        return min(100, Double(busy) / Double(total) * 100)
    }

    private func readMemoryUsed() -> UInt64 {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return memoryUsed }
        let pageSize = UInt64(vm_kernel_page_size)
        let active = UInt64(stats.active_count) + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)
        return active * pageSize
    }

    private func refreshNativeMemoryDetails() {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        if result == KERN_SUCCESS {
            let pageSize = UInt64(vm_kernel_page_size)
            memoryWired = UInt64(stats.wire_count) * pageSize
            memoryActive = UInt64(stats.active_count) * pageSize
            memoryCached = (UInt64(stats.inactive_count) + UInt64(stats.speculative_count)) * pageSize
            memoryCompressed = UInt64(stats.compressor_page_count) * pageSize
            memoryFree = UInt64(stats.free_count) * pageSize
        }

        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0 {
            swapUsed = swap.xsu_used
            swapTotal = swap.xsu_total
        }

        var pressure: Int32 = 0
        var pressureSize = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &pressure, &pressureSize, nil, 0) == 0 {
            switch pressure {
            case 1: memoryPressureLevel = 0
            case 2: memoryPressureLevel = 1
            case 4: memoryPressureLevel = 2
            default: memoryPressureLevel = nil
            }
            if let memoryPressureLevel {
                memoryPressureSamples.append(MemoryPressureSample(date: .now, value: Double(memoryPressureLevel) * 50))
                if memoryPressureSamples.count > 90 { memoryPressureSamples.removeFirst(memoryPressureSamples.count - 90) }
            }
        }
    }

    private func readGPUMemory() -> GPUMemoryReading? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            defer { IOObjectRelease(service) }

            var unmanagedProperties: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &unmanagedProperties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let properties = unmanagedProperties?.takeRetainedValue() as? [String: Any],
                  let statistics = properties["PerformanceStatistics"] as? [String: Any] else { continue }

            func bytes(_ keys: [String]) -> UInt64? {
                for key in keys {
                    if let number = statistics[key] as? NSNumber, number.uint64Value > 0 { return number.uint64Value }
                }
                return nil
            }

            let vramUsed = bytes(["vramUsedBytes"])
            let vramFree = bytes(["vramFreeBytes"])
            if let vramUsed, let vramFree, vramUsed + vramFree > 0 {
                let isUnified = MTLCreateSystemDefaultDevice()?.hasUnifiedMemory ?? true
                return GPUMemoryReading(used: vramUsed, total: vramUsed + vramFree, isUnifiedMemoryEstimate: isUnified)
            }

            // Apple Silicon shares physical memory with the GPU. This driver
            // counter is the GPU's in-use portion of unified system memory.
            if let used = bytes(["In use system memory", "inUseSysMemoryBytes", "sysmemUsedBytes", "Alloc system memory"]) {
                return GPUMemoryReading(used: min(used, memoryTotal), total: memoryTotal, isUnifiedMemoryEstimate: true)
            }
        }
        return nil
    }

    private func refreshDiskVolumesIfNeeded() {
        guard !volumeScanInProgress, Date.now.timeIntervalSince(lastVolumeScan) >= 30 else { return }
        lastVolumeScan = .now
        volumeScanInProgress = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let volumes = Self.readMountedVolumes()
            Task { @MainActor [weak self] in
                self?.diskVolumes = volumes
                self?.volumeScanInProgress = false
            }
        }
    }

    private func refreshNetworkDetailsIfNeeded() {
        guard !networkScanInProgress, Date.now.timeIntervalSince(lastNetworkScan) >= 5 else { return }
        lastNetworkScan = .now
        networkScanInProgress = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let snapshot = Self.readNetworkDetails()
            Task { @MainActor [weak self] in
                self?.networkInterfaces = snapshot.interfaces
                self?.defaultGateway = snapshot.gateway
                self?.gatewayInterface = snapshot.gatewayInterface
                self?.networkScanInProgress = false
            }
        }
    }

    nonisolated private static func readNetworkDetails() -> NetworkDetailsSnapshot {
        struct AddressSet {
            var ipv4 = Set<String>()
            var ipv6 = Set<String>()
        }

        var addresses: [String: AddressSet] = [:]
        var head: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&head) == 0, let first = head {
            defer { freeifaddrs(head) }
            var item: UnsafeMutablePointer<ifaddrs>? = first
            while let current = item {
                let entry = current.pointee
                if let namePointer = entry.ifa_name,
                   let socketAddress = entry.ifa_addr,
                   entry.ifa_flags & UInt32(IFF_UP) != 0 {
                    let name = String(cString: namePointer)
                    let family = Int32(socketAddress.pointee.sa_family)
                    if name != "lo0", family == AF_INET || family == AF_INET6 {
                        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                        let result = getnameinfo(
                            socketAddress,
                            socklen_t(socketAddress.pointee.sa_len),
                            &host,
                            socklen_t(host.count),
                            nil,
                            0,
                            NI_NUMERICHOST
                        )
                        if result == 0 {
                            let address = String(cString: host)
                            if family == AF_INET, !address.hasPrefix("127."), !address.hasPrefix("169.254.") {
                                addresses[name, default: AddressSet()].ipv4.insert(address)
                            } else if family == AF_INET6,
                                      address != "::1",
                                      !address.lowercased().hasPrefix("fe80:") {
                                addresses[name, default: AddressSet()].ipv6.insert(address)
                            }
                        }
                    }
                }
                item = entry.ifa_next
            }
        }

        let displayNames: [String: String] = (SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? [])
            .reduce(into: [:]) { names, interface in
                guard let bsdName = SCNetworkInterfaceGetBSDName(interface) as String?,
                      let displayName = SCNetworkInterfaceGetLocalizedDisplayName(interface) as String? else { return }
                names[bsdName] = displayName
            }
        let interfaces = addresses.keys.sorted().compactMap { name -> NetworkInterfaceReading? in
            guard let found = addresses[name], !found.ipv4.isEmpty || !found.ipv6.isEmpty else { return nil }
            return NetworkInterfaceReading(
                name: name,
                displayName: displayNames[name] ?? "网络接口",
                ipv4Addresses: found.ipv4.sorted(),
                ipv6Addresses: found.ipv6.sorted()
            )
        }
        let route = readDefaultRoute()
        return NetworkDetailsSnapshot(interfaces: interfaces, gateway: route.gateway, gatewayInterface: route.interface)
    }

    nonisolated private static func readDefaultRoute() -> (gateway: String?, interface: String?) {
        let process = Foundation.Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/sbin/route")
        process.arguments = ["-n", "get", "default"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return (nil, nil) }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8) else { return (nil, nil) }
        var gateway: String?
        var interface: String?
        for line in text.split(separator: "\n") {
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard parts.count >= 2 else { continue }
            if parts[0] == "gateway:" { gateway = String(parts[1]) }
            if parts[0] == "interface:" { interface = String(parts[1]) }
        }
        return (gateway, interface)
    }

    nonisolated private static func readMountedVolumes() -> [DiskVolumeReading] {
        let keys: Set<URLResourceKey> = [
            .volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
            .volumeIsLocalKey, .volumeIsRemovableKey
        ]
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: Array(keys),
            options: [.skipHiddenVolumes]
        ) ?? []
        var volumes = urls.compactMap { url -> DiskVolumeReading? in
            guard let values = try? url.resourceValues(forKeys: keys),
                  let total = values.volumeTotalCapacity, total > 0,
                  let available = values.volumeAvailableCapacity else { return nil }
            let local = values.volumeIsLocal ?? true
            return DiskVolumeReading(
                name: values.volumeName ?? url.lastPathComponent,
                mountPath: url.standardizedFileURL.path,
                totalBytes: UInt64(total),
                availableBytes: UInt64(max(0, available)),
                isNetwork: !local,
                isRemovable: values.volumeIsRemovable ?? false
            )
        }

        let root = URL(fileURLWithPath: "/")
        if !volumes.contains(where: { $0.mountPath == "/" }),
           let values = try? root.resourceValues(forKeys: keys),
           let total = values.volumeTotalCapacity, total > 0,
           let available = values.volumeAvailableCapacity {
            volumes.append(DiskVolumeReading(
                name: values.volumeName ?? "系统卷",
                mountPath: "/",
                totalBytes: UInt64(total),
                availableBytes: UInt64(max(0, available)),
                isNetwork: false,
                isRemovable: false
            ))
        }
        return volumes.sorted { lhs, rhs in
            let lhsIsRoot = lhs.mountPath == "/"
            let rhsIsRoot = rhs.mountPath == "/"
            if lhsIsRoot != rhsIsRoot { return lhsIsRoot }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
}

extension ProcessInfo.ThermalState {
    var displayName: String {
        switch self {
        case .nominal: "正常"
        case .fair: "温热"
        case .serious: "高温"
        case .critical: "严重"
        @unknown default: "未知"
        }
    }
}

func formatBytes(_ bytes: UInt64) -> String {
    if bytes == 0 { return "0 B" }
    return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
}
