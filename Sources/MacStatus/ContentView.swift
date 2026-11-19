import SwiftUI
import Charts
import AppKit

enum Page: String, CaseIterable, Identifiable {
    case overview = "概览", cpu = "CPU", memory = "内存", disk = "硬盘", network = "网络", processes = "进程", fans = "风扇", records = "记录", osd = "OSD", settings = "设置"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .overview: "square.grid.2x2.fill"
        case .cpu: "cpu"
        case .memory: "memorychip"
        case .disk: "internaldrive"
        case .network: "network"
        case .processes: "list.bullet.rectangle"
        case .fans: "fanblades.fill"
        case .records: "clock.arrow.circlepath"
        case .osd: "text.alignleft"
        case .settings: "gearshape"
        }
    }
}

@MainActor
final class NavigationState: ObservableObject {
    @Published var page: Page = .overview
}

struct ContentView: View {
    @EnvironmentObject private var monitor: SystemMonitor
    @Environment(\.openWindow) private var openWindow
    @StateObject private var navigation = NavigationState()
    @AppStorage("keitop.darkMode") private var darkMode = true

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            VStack(spacing: 0) {
                HStack {
                    Text("KeiTop").font(.system(size: 17, weight: .semibold))
                    Spacer()
                    Text("实时更新 · 每 \(Int(monitor.refreshSeconds)) 秒")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    Circle().fill(monitor.sensorConnected ? Color.green : Color.orange).frame(width: 7, height: 7)
                }
                .padding(.horizontal, 28).padding(.vertical, 20)
                Divider()
                ScrollView {
                    Group {
                        switch navigation.page {
                        case .overview: OverviewPage(
                            onCPUSelected: { navigation.page = .cpu },
                            onMemorySelected: { navigation.page = .memory },
                            onDiskSelected: { navigation.page = .disk },
                            onNetworkSelected: { navigation.page = .network }
                        )
                        case .cpu: CPUPage()
                        case .memory: MemoryPage(onProcessesSelected: { navigation.page = .processes })
                        case .disk: DiskPage()
                        case .network: NetworkPage()
                        case .processes: ProcessesPage()
                        case .fans: FansPage()
                        case .records: RecordsPage()
                        case .osd: OSDSettingsPage(openOSD: { openWindow(id: "osd") })
                        case .settings: SettingsPage(darkMode: $darkMode)
                        }
                    }
                    .environmentObject(monitor)
                    .padding(24)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(darkMode ? .dark : .light)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Page.allCases) { item in
                Button { navigation.page = item } label: {
                    HStack(spacing: 12) {
                        Image(systemName: item.symbol).frame(width: 20)
                        Text(item.rawValue)
                        Spacer()
                    }
                    .font(.system(size: 14, weight: navigation.page == item ? .semibold : .regular))
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .foregroundStyle(navigation.page == item ? Color.white : Color.primary.opacity(0.72))
                    .background(navigation.page == item ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 9))
                }.buttonStyle(.plain)
            }
            Spacer()
            Button { navigation.page = .settings } label: {
                Label("设置", systemImage: "gearshape").font(.system(size: 13))
                    .foregroundStyle(navigation.page == .settings ? Color.accentColor : Color.secondary)
                    .padding(.horizontal, 12).padding(.vertical, 8)
            }.buttonStyle(.plain)
        }
        .padding(14).frame(width: 175).background(.quaternary.opacity(0.35))
    }
}

struct OverviewPage: View {
    @EnvironmentObject private var monitor: SystemMonitor
    let onCPUSelected: () -> Void
    let onMemorySelected: () -> Void
    let onDiskSelected: () -> Void
    let onNetworkSelected: () -> Void
    private let columns = [GridItem(.adaptive(minimum: 300), spacing: 14)]
    var body: some View {
        LazyVGrid(columns: columns, spacing: 16) {
            MetricCard(title: "CPU 使用率", value: "\(Int(monitor.cpuUsage.rounded()))%", subtitle: "点击查看每个核心", color: .orange, samples: monitor.samples, keyPath: \.cpu, chartDomain: 0...100, action: onCPUSelected)
            MetricCard(title: "GPU 负载", value: monitor.gpuUsage.map { "\(Int($0.rounded()))%" } ?? "—", subtitle: "频率加权负载", color: .green, samples: monitor.samples, keyPath: \.gpuUsage, chartDomain: 0...100)
            MetricCard(title: "内存占用", value: "\(formatBytes(monitor.memoryUsed)) / \(formatBytes(monitor.memoryTotal))", subtitle: "\(Int((monitor.memoryFraction * 100).rounded()))% 已使用 · 点击查看内存详情", color: .cyan, samples: monitor.samples, keyPath: \.memory, chartDomain: 0...100, action: onMemorySelected)
            MetricCard(title: "CPU 功耗", value: monitor.cpuPower.map { String(format: "%.1f W", $0) } ?? "—", subtitle: monitor.cpuPower == nil ? "mactop 暂未返回读数" : "Apple Silicon CPU 功耗传感器", color: .yellow, samples: monitor.samples, keyPath: monitor.cpuPower == nil ? nil : \.cpuPower)
            MetricCard(title: "GPU 功耗", value: monitor.gpuPower.map { String(format: "%.1f W", $0) } ?? "—", subtitle: "SoC GPU", color: .purple, samples: monitor.samples, keyPath: monitor.gpuPower == nil ? nil : \.gpuPower)
            MetricCard(title: "整机芯片功耗", value: monitor.chipPower.map { String(format: "%.1f W", $0) } ?? "—", subtitle: monitor.sensorStatus, color: .blue, samples: monitor.samples, keyPath: \.chipPower)
            MetricCard(title: "CPU 温度", value: monitor.cpuTemperature.map { String(format: "%.0f°C", $0) } ?? "—", subtitle: "平均传感器温度", color: .pink, samples: monitor.samples, keyPath: monitor.cpuTemperature == nil ? nil : \.cpuTemperature)
            MetricCard(title: "GPU 温度", value: monitor.gpuTemperature.map { String(format: "%.0f°C", $0) } ?? "—", subtitle: "平均传感器温度", color: .yellow, samples: monitor.samples, keyPath: monitor.gpuTemperature == nil ? nil : \.gpuTemperature)
            DiskOverviewCard(volume: monitor.systemVolume, action: onDiskSelected)
            BatteryOverviewCard(battery: monitor.battery, subtitle: batterySubtitle)
            MetricCard(title: "网络状态", value: String(format: "↓ %.2f MB/s", monitor.networkDownloadMBps), subtitle: String(format: "上传 ↑ %.2f MB/s · 点击查看网络详情", monitor.networkUploadMBps), color: .cyan, samples: monitor.samples, keyPath: \.networkDownload, action: onNetworkSelected)
            MetricCard(title: "磁盘读取", value: String(format: "↓ %.2f MB/s", monitor.diskReadMBps), subtitle: String(format: "写入 ↑ %.2f MB/s", monitor.diskWriteMBps), color: .indigo, samples: monitor.samples, keyPath: \.diskRead)
        }
    }

    private var batterySubtitle: String {
        guard let battery = monitor.battery else { return "此设备未检测到电池" }
        let power = battery.isCharging ? "正在充电" : (battery.isOnAC ? "已接入电源" : "电池供电")
        let health = battery.healthPercent.map { " · 健康度 \(Int($0.rounded()))%" } ?? ""
        return power + health
    }
}

private struct DiskOverviewCard: View {
    let volume: DiskVolumeReading?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Text("硬盘占用").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: "arrow.up.right.square").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                Spacer(minLength: 4)
                if let volume {
                    HStack(alignment: .firstTextBaseline) {
                        Text("\(formatBytes(volume.usedBytes)) / \(formatBytes(volume.totalBytes))")
                            .font(.system(size: 19, weight: .medium, design: .rounded)).lineLimit(1).minimumScaleFactor(0.7)
                        Spacer(minLength: 4)
                        Text("\(Int((volume.usedFraction * 100).rounded()))%")
                            .font(.system(size: 14, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
                    }
                    CapacityBar(fraction: volume.usedFraction, color: .indigo)
                    HStack {
                        Text("已用 \(formatBytes(volume.usedBytes))")
                        Spacer(minLength: 4)
                        Text("可用 \(formatBytes(volume.availableBytes))")
                    }
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.75)
                } else {
                    Text("正在读取系统卷容量…").font(.system(size: 15, weight: .medium))
                    CapacityBar(fraction: 0, color: .indigo)
                    Text("点击查看磁盘详情").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 210, alignment: .topLeading)
            .padding(15).background(.quaternary.opacity(0.33), in: RoundedRectangle(cornerRadius: 15))
            .contentShape(RoundedRectangle(cornerRadius: 15))
        }
        .buttonStyle(.plain)
        .accessibilityHint("打开硬盘详情")
    }
}

private struct BatteryOverviewCard: View {
    let battery: BatteryReading?
    let subtitle: String

    private var tint: Color {
        guard let battery else { return .green }
        if battery.chargePercent <= 20 { return .red }
        if battery.chargePercent <= 40 { return .orange }
        return .green
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("电池").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                Image(systemName: battery?.isCharging == true ? "battery.100percent.bolt" : "battery.100percent")
                    .font(.system(size: 12)).foregroundStyle(tint)
            }
            Spacer(minLength: 4)
            if let battery {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(Int(battery.chargePercent.rounded()))%")
                        .font(.system(size: 20, weight: .medium, design: .rounded))
                    Spacer()
                    if let health = battery.healthPercent {
                        Text("健康度 \(Int(health.rounded()))%")
                            .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    }
                }
                CapacityBar(fraction: battery.chargePercent / 100, color: tint)
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.75)
            } else {
                Text("无电池").font(.system(size: 17, weight: .medium))
                CapacityBar(fraction: 0, color: tint)
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 210, alignment: .topLeading)
        .padding(15).background(.quaternary.opacity(0.33), in: RoundedRectangle(cornerRadius: 15))
    }
}

struct MetricCard: View {
    let title: String
    let value: String
    let subtitle: String
    let color: Color
    var samples: [MetricSample] = []
    var keyPath: KeyPath<MetricSample, Double>?
    var chartDomain: ClosedRange<Double>?
    var action: (() -> Void)?

    @ViewBuilder
    private var historyChart: some View {
        Chart(samples) { sample in
            AreaMark(x: .value("Time", sample.date), y: .value("Value", sample[keyPath: keyPath!])).foregroundStyle(color.opacity(0.13))
            LineMark(x: .value("Time", sample.date), y: .value("Value", sample[keyPath: keyPath!])).foregroundStyle(color).lineStyle(StrokeStyle(lineWidth: 1.8))
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .frame(height: 66)
        .modifier(OptionalChartDomain(domain: chartDomain))
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary); Spacer(); Image(systemName: "arrow.up.right.square").font(.system(size: 11)).foregroundStyle(.tertiary) }
            Text(value).font(.system(size: 20, weight: .medium, design: .rounded)).lineLimit(1).minimumScaleFactor(0.72)
            Spacer(minLength: 4)
            if keyPath != nil, !samples.isEmpty {
                historyChart
            } else {
                RoundedRectangle(cornerRadius: 8).fill(color.opacity(0.08)).frame(height: 66)
                    .overlay(Image(systemName: "waveform.path").font(.system(size: 18)).foregroundStyle(color.opacity(0.42)))
            }
            Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: 210, alignment: .topLeading)
        .padding(15).background(.quaternary.opacity(0.33), in: RoundedRectangle(cornerRadius: 15))
    }

    @ViewBuilder
    var body: some View {
        if let action {
            Button(action: action) { cardContent }
                .buttonStyle(.plain)
                .accessibilityHint("打开每个 CPU 核心的占用率")
        } else {
            cardContent
        }
    }
}

struct CPUPage: View {
    @EnvironmentObject private var monitor: SystemMonitor
    private let columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(monitor.cpuSpecification ?? monitor.cpuModel ?? "CPU")
                        .font(.system(size: 24, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.72)
                    Text("每核心实时使用率 · 每 \(Int(monitor.refreshSeconds)) 秒更新")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Spacer()
                Text("总占用 \(Int(monitor.cpuUsage.rounded()))%")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
            }

            if monitor.cpuCores.isEmpty {
                ContentUnavailableView("暂无每核心数据", systemImage: "cpu", description: Text("请确认 mactop 正在运行并已连接传感器。"))
                    .frame(maxWidth: .infinity, minHeight: 260)
            } else {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(monitor.cpuCores) { core in
                        VStack(alignment: .leading, spacing: 11) {
                            HStack {
                                Text(core.name).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                                Spacer()
                                Text("\(Int(core.usage.rounded()))%")
                                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                            }
                            ProgressView(value: min(100, max(0, core.usage)), total: 100)
                                .tint(core.usage > 80 ? .orange : .green)
                            Text("核心 \(core.index + 1)").font(.system(size: 11)).foregroundStyle(.tertiary)
                        }
                        .padding(14)
                        .background(.quaternary.opacity(0.33), in: RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct MemoryPage: View {
    @EnvironmentObject private var monitor: SystemMonitor
    let onProcessesSelected: () -> Void

    private let twoColumns = [GridItem(.flexible()), GridItem(.flexible())]
    private let fiveColumns = Array(repeating: GridItem(.flexible()), count: 5)
    private let memoryDetailCardMinHeight: CGFloat = 184

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("内存").font(.system(size: 24, weight: .semibold))
                    Text("物理内存与图形内存实时状态 · 每 \(Int(monitor.refreshSeconds)) 秒更新")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: onProcessesSelected) {
                    Label("按内存查看进程", systemImage: "list.bullet.rectangle")
                }.buttonStyle(.bordered)
            }

            physicalMemoryCard

            LazyVGrid(columns: twoColumns, spacing: 14) {
                graphicsMemoryCard
                swapCard
            }

            pressureCard
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var physicalMemoryCard: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(alignment: .firstTextBaseline) {
                Text("Memory").font(.system(size: 19, weight: .semibold))
                Spacer()
                Text("总容量 \(formatBytes(monitor.memoryTotal))")
                    .font(.system(size: 17, weight: .semibold, design: .rounded)).monospacedDigit()
            }
            MemoryCompositionBar(segments: monitor.memoryComposition)
            LazyVGrid(columns: fiveColumns, alignment: .leading, spacing: 12) {
                ForEach(monitor.memoryComposition) { segment in
                    MemoryLegend(color: memoryColor(segment.name), title: segment.name, value: formatBytes(segment.bytes))
                }
            }
            Text("按 macOS 虚拟内存页队列分段；Other 是未归入前四项的剩余容量，分段总和与物理内存一致。")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
        }
        .padding(18).background(.quaternary.opacity(0.33), in: RoundedRectangle(cornerRadius: 15))
    }

    private var graphicsMemoryCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Text("Graphics").font(.system(size: 18, weight: .semibold))
                Spacer()
                Image(systemName: "gpu-card").foregroundStyle(.secondary)
            }
            Text(monitor.cpuModel ?? "Apple GPU")
                .font(.system(size: 15, weight: .semibold))
            if let gpu = monitor.gpuMemory {
                HStack {
                    Text("GPU 使用的\(gpu.isUnifiedMemoryEstimate ? "统一内存" : "图形内存")")
                    Spacer()
                    Text("空闲：\(formatBytes(gpu.available)) / \(formatBytes(gpu.total))")
                        .monospacedDigit()
                }.font(.system(size: 12, weight: .medium))
                CapacityBar(fraction: gpu.fraction, color: .cyan)
                HStack {
                    Text("已用 \(formatBytes(gpu.used))")
                    Spacer()
                    Text("\(Int((gpu.fraction * 100).rounded()))%")
                }.font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
                Text(gpu.isUnifiedMemoryEstimate
                     ? "Apple Silicon 与 CPU 共用统一内存；GPU 数值是驱动报告的活动内存，不是独立显存。"
                     : "由图形驱动报告的显存使用量。")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
            } else {
                Text("当前系统未返回 GPU 内存计数。")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                Text("GPU 显存读取依赖 IOAccelerator 驱动统计；其他 GPU 指标仍可正常显示。")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: memoryDetailCardMinHeight, alignment: .topLeading)
        .padding(18).background(.quaternary.opacity(0.33), in: RoundedRectangle(cornerRadius: 15))
        .help("Apple Silicon 使用统一内存，GPU 活动内存是系统内存的一部分。")
    }

    private var swapCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Text("Swap").font(.system(size: 18, weight: .semibold))
                Spacer()
                Text(monitor.swapTotal > 0
                     ? "已用 \(formatBytes(monitor.swapUsed)) / \(formatBytes(monitor.swapTotal))"
                     : "当前未使用 Swap")
                    .font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit()
            }
            if monitor.swapTotal > 0 {
                CapacityBar(fraction: Double(monitor.swapUsed) / Double(monitor.swapTotal), color: .purple)
            } else {
                RoundedRectangle(cornerRadius: 9).fill(Color.secondary.opacity(0.12)).frame(height: 18)
            }
            HStack {
                MemoryLegend(color: .purple, title: "已用", value: formatBytes(monitor.swapUsed))
                Spacer()
                Text(monitor.swapTotal > 0
                     ? "可用 \(formatBytes(monitor.swapTotal > monitor.swapUsed ? monitor.swapTotal - monitor.swapUsed : 0))"
                     : "尚未分配 Swap 空间")
                    .font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
            }
            Text("Swap 是 macOS 使用的磁盘交换空间，与物理内存分开统计。")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, minHeight: memoryDetailCardMinHeight, alignment: .topLeading)
        .padding(18).background(.quaternary.opacity(0.33), in: RoundedRectangle(cornerRadius: 15))
    }

    private var pressureCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("内存压力").font(.system(size: 18, weight: .semibold))
                Spacer()
                Text(pressureDescription)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(pressureColor)
            }
            if monitor.memoryPressureSamples.isEmpty {
                ContentUnavailableView("暂无内存压力数据", systemImage: "waveform.path", description: Text("当前系统未返回内存压力状态。"))
                    .frame(height: 100)
            } else {
                Chart(monitor.memoryPressureSamples) { sample in
                    AreaMark(x: .value("时间", sample.date), y: .value("压力", sample.value))
                        .foregroundStyle(pressureColor.opacity(0.14))
                    LineMark(x: .value("时间", sample.date), y: .value("压力", sample.value))
                        .foregroundStyle(pressureColor).lineStyle(StrokeStyle(lineWidth: 2))
                        .interpolationMethod(.stepCenter)
                }
                .chartXAxis(.hidden).chartYAxis(.hidden).chartYScale(domain: 0...100)
                .frame(height: 100)
            }
            Text("显示 macOS 当前压力等级的近 3 分钟变化；不是连续百分比测量。")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, minHeight: 165, alignment: .topLeading)
        .padding(18).background(.quaternary.opacity(0.33), in: RoundedRectangle(cornerRadius: 15))
    }

    private var pressureDescription: String {
        switch monitor.memoryPressureLevel {
        case 0: "正常"
        case 1: "警告"
        case 2: "严重"
        default: "未知"
        }
    }

    private var pressureColor: Color {
        switch monitor.memoryPressureLevel {
        case 0: .green
        case 1: .orange
        case 2: .red
        default: .secondary
        }
    }

    private func memoryColor(_ name: String) -> Color {
        switch name {
        case "Wired": .red
        case "Used": .orange
        case "Cache": .blue
        case "Free": .green
        default: .gray
        }
    }
}

struct DiskPage: View {
    @EnvironmentObject private var monitor: SystemMonitor

    private let columns = [GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("硬盘").font(.system(size: 24, weight: .semibold))
                Text("系统卷与已挂载磁盘容量 · 约每 30 秒刷新")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }

            if let systemVolume = monitor.systemVolume {
                StorageVolumeCard(volume: systemVolume, subtitle: "系统卷")
            } else {
                ContentUnavailableView("正在读取系统卷", systemImage: "internaldrive", description: Text("正在查询总容量和可用空间。"))
                    .frame(maxWidth: .infinity, minHeight: 150)
            }

            VStack(alignment: .leading, spacing: 12) {
                Text("网络磁盘").font(.system(size: 18, weight: .semibold))
                if monitor.networkVolumes.isEmpty {
                    ContentUnavailableView("没有已连接的网络磁盘", systemImage: "externaldrive.connected.to.line.below", description: Text("挂载 SMB、NFS 等网络卷后，会在这里显示容量。"))
                        .frame(maxWidth: .infinity, minHeight: 120)
                } else {
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(monitor.networkVolumes) { volume in
                            StorageVolumeCard(volume: volume, subtitle: volume.mountPath)
                        }
                    }
                }
            }

            if !monitor.removableVolumes.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("外接磁盘").font(.system(size: 18, weight: .semibold))
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(monitor.removableVolumes) { volume in
                            StorageVolumeCard(volume: volume, subtitle: volume.mountPath)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct NetworkPage: View {
    @EnvironmentObject private var monitor: SystemMonitor
    @StateObject private var publicIPLookup = PublicIPLookup()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("网络").font(.system(size: 24, weight: .semibold))
                    Text("已连接接口、局域网地址与实时流量")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Network-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Label("打开 macOS 网络设置", systemImage: "gearshape")
                }
                .buttonStyle(.bordered)
            }

            publicIPCard
            trafficCard

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("活动网络接口").font(.system(size: 18, weight: .semibold))
                    Spacer()
                    Text("每 5 秒刷新") .font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                if monitor.networkInterfaces.isEmpty {
                    ContentUnavailableView("没有检测到已连接的网络接口", systemImage: "network.slash", description: Text("连接 Wi‑Fi、以太网或 VPN 后，接口和本地地址会显示在这里。"))
                        .frame(maxWidth: .infinity, minHeight: 150)
                } else {
                    ForEach(monitor.networkInterfaces) { interface in
                        NetworkInterfaceCard(
                            interface: interface,
                            gateway: monitor.gatewayInterface == interface.name ? monitor.defaultGateway : nil
                        )
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var publicIPCard: some View {
        HStack(spacing: 16) {
            Image(systemName: "globe.americas.fill")
                .font(.system(size: 23)).foregroundStyle(.cyan)
                .frame(width: 48, height: 48)
                .background(.cyan.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 5) {
        Text(publicIPLookup.address ?? "公网 IP")
                    .font(.system(size: 18, weight: .semibold, design: .rounded)).monospacedDigit()
        Text(publicIPLookup.error ?? (publicIPLookup.address == nil
                     ? "按需查询 · 通过 api.ipify.org 获取，不会自动查询"
                     : "由 api.ipify.org 返回 · 点击刷新"))
                    .font(.system(size: 11)).foregroundStyle(publicIPLookup.error == nil ? Color.secondary : Color.orange)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Button {
                Task { await publicIPLookup.lookup() }
            } label: {
                if publicIPLookup.isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Label(publicIPLookup.address == nil ? "查询" : "刷新", systemImage: "arrow.clockwise")
                }
            }
            .buttonStyle(.bordered)
            .disabled(publicIPLookup.isLoading)
        }
        .padding(18).background(.quaternary.opacity(0.33), in: RoundedRectangle(cornerRadius: 15))
    }

    private var trafficCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("实时流量").font(.system(size: 18, weight: .semibold))
                Spacer()
                Text(String(format: "↓ %.2f MB/s", monitor.networkDownloadMBps))
                    .foregroundStyle(.cyan)
                Text(String(format: "↑ %.2f MB/s", monitor.networkUploadMBps))
                    .foregroundStyle(.green)
            }
            if monitor.samples.isEmpty {
                ContentUnavailableView("正在采集网络流量", systemImage: "arrow.left.arrow.right")
                    .frame(height: 120)
            } else {
                Chart {
                    ForEach(monitor.samples) { sample in
                        LineMark(x: .value("时间", sample.date), y: .value("速率", sample.networkDownload), series: .value("方向", "下载"))
                            .foregroundStyle(.cyan).lineStyle(StrokeStyle(lineWidth: 2))
                        LineMark(x: .value("时间", sample.date), y: .value("速率", sample.networkUpload), series: .value("方向", "上传"))
                            .foregroundStyle(.green).lineStyle(StrokeStyle(lineWidth: 2))
                    }
                }
                .chartXAxis(.hidden).chartYAxisLabel("MB/s")
                .frame(height: 125)
            }
            Text("显示所有物理网络接口的合计收发速率；VPN 等虚拟接口不重复计入。")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
        }
        .padding(18).background(.quaternary.opacity(0.33), in: RoundedRectangle(cornerRadius: 15))
    }

}

@MainActor
private final class PublicIPLookup: ObservableObject {
    @Published var address: String?
    @Published var error: String?
    @Published var isLoading = false

    func lookup() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            var request = URLRequest(url: URL(string: "https://api.ipify.org")!)
            request.timeoutInterval = 8
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
                  let value = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else {
                error = "公网 IP 查询失败，请检查网络后重试。"
                return
            }
            address = value
        } catch let lookupError {
            error = "查询失败：\(lookupError.localizedDescription)"
        }
    }
}

private struct NetworkInterfaceCard: View {
    let interface: NetworkInterfaceReading
    let gateway: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(interface.displayName).font(.system(size: 17, weight: .semibold))
                    Text(interface.name).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                }
                Spacer()
                Circle().fill(.green).frame(width: 9, height: 9)
                Text("已连接").font(.system(size: 11, weight: .medium)).foregroundStyle(.green)
            }
            Divider()
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 12) {
                if !interface.ipv4Addresses.isEmpty {
                    NetworkValue(label: "IPv4 地址", value: interface.ipv4Addresses.joined(separator: "\n"), symbol: "desktopcomputer")
                }
                if !interface.ipv6Addresses.isEmpty {
                    NetworkValue(label: "IPv6 地址", value: interface.ipv6Addresses.joined(separator: "\n"), symbol: "globe")
                }
                if let gateway {
                    NetworkValue(label: "默认网关", value: gateway, symbol: "wifi.router")
                }
            }
            if gateway == nil {
                Text("此接口不是当前默认路由接口，或系统未提供网关。")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
            }
        }
        .padding(16).background(.quaternary.opacity(0.33), in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct NetworkValue: View {
    let label: String
    let value: String
    let symbol: String

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
                Text(value).font(.system(size: 12, weight: .medium, design: .rounded)).monospacedDigit().textSelection(.enabled)
            }
        }
    }
}

private struct StorageVolumeCard: View {
    let volume: DiskVolumeReading
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(volume.name).font(.system(size: 18, weight: .semibold)).lineLimit(1)
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 10)
                Text("\(formatBytes(volume.usedBytes)) / \(formatBytes(volume.totalBytes))")
                    .font(.system(size: 14, weight: .semibold, design: .rounded)).monospacedDigit()
            }
            CapacityBar(fraction: volume.usedFraction, color: .indigo)
            HStack {
                MemoryLegend(color: .indigo, title: "已用", value: formatBytes(volume.usedBytes))
                Spacer()
                MemoryLegend(color: .secondary.opacity(0.45), title: "可用", value: formatBytes(volume.availableBytes))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18).background(.quaternary.opacity(0.33), in: RoundedRectangle(cornerRadius: 15))
    }
}

private struct CapacityBar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.2))
                Capsule().fill(color).frame(width: geometry.size.width * min(1, max(0, fraction)))
            }
        }
        .frame(height: 18)
        .clipShape(Capsule())
        .accessibilityLabel("占用 \(Int((fraction * 100).rounded()))%")
    }
}

private struct MemoryCompositionBar: View {
    let segments: [MemoryCategoryReading]

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                ForEach(segments.filter { $0.bytes > 0 }) { segment in
                    Rectangle()
                        .fill(color(for: segment.name))
                        .frame(width: geometry.size.width * fraction(for: segment.bytes))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.2))
        }
        .frame(height: 19)
        .clipShape(Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(segments.map { "\($0.name) \(formatBytes($0.bytes))" }.joined(separator: ", "))
    }

    private func fraction(for bytes: UInt64) -> CGFloat {
        let total = segments.reduce(UInt64(0)) { $0 + $1.bytes }
        guard total > 0 else { return 0 }
        return CGFloat(Double(bytes) / Double(total))
    }

    private func color(for name: String) -> Color {
        switch name {
        case "Wired": .red
        case "Used": .orange
        case "Cache": .blue
        case "Free": .green
        default: .gray
        }
    }
}

private struct MemoryLegend: View {
    let color: Color
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(color).frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
                Text(value).font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit()
            }
        }
    }
}

private enum ProcessSortColumn {
    case cpu
    case memory
}

@MainActor
private final class ProcessListState: ObservableObject {
    @Published var searchText = ""
    @Published var sortColumn = ProcessSortColumn.memory
    @Published var ascending = false
    @Published var confirmationTarget: ProcessReading?
    @Published var forceKillTarget: ProcessReading?
    @Published var showTerminationConfirmation = false
    @Published var showForceKillConfirmation = false
    @Published var actionError: String?
}

struct ProcessesPage: View {
    @EnvironmentObject private var monitor: SystemMonitor
    @StateObject private var state = ProcessListState()

    private var visibleProcesses: [ProcessReading] {
        let filtered = monitor.processes.filter { process in
            state.searchText.isEmpty || process.name.localizedCaseInsensitiveContains(state.searchText) || String(process.pid).contains(state.searchText)
        }
        return filtered.sorted { first, second in
            let firstValue = state.sortColumn == .cpu ? first.cpu : Double(first.memory)
            let secondValue = state.sortColumn == .cpu ? second.cpu : Double(second.memory)
            if firstValue == secondValue { return state.ascending ? first.pid < second.pid : first.pid > second.pid }
            return state.ascending ? firstValue < secondValue : firstValue > secondValue
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("进程").font(.system(size: 24, weight: .semibold))
                    Text("\(monitor.processes.count) 个进程 · 每 \(Int(monitor.refreshSeconds)) 秒更新")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Spacer()
                TextField("搜索名称或 PID", text: $state.searchText).textFieldStyle(.roundedBorder).frame(width: 220)
            }
            HStack {
                Text("进程名称").frame(maxWidth: .infinity, alignment: .leading)
                sortButton("CPU", column: .cpu).frame(width: 105, alignment: .trailing)
                sortButton("内存", column: .memory).frame(width: 125, alignment: .trailing)
                Text("").frame(width: 32)
            }
            .font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 14).padding(.top, 8)
            if visibleProcesses.isEmpty {
                ContentUnavailableView(state.searchText.isEmpty ? "正在读取进程" : "没有匹配的进程", systemImage: "list.bullet.rectangle", description: Text("可按应用全名或 PID 搜索。"))
                    .frame(maxWidth: .infinity, minHeight: 240)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(visibleProcesses) { process in
                        HStack(spacing: 12) {
                            Group {
                                if let icon = process.icon {
                                    Image(nsImage: icon).resizable().interpolation(.high).scaledToFit()
                                } else {
                                    Image(systemName: "app.dashed").resizable().scaledToFit().foregroundStyle(.blue)
                                }
                            }.frame(width: 22, height: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(process.name).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                                Text("PID \(process.pid)").font(.system(size: 10)).foregroundStyle(.tertiary)
                            }
                            Text(String(format: "%.1f%%", process.cpu)).monospacedDigit().frame(width: 105, alignment: .trailing)
                            Text(formatBytes(process.memory)).monospacedDigit().frame(width: 125, alignment: .trailing)
                            Menu {
                                Button("结束进程…", systemImage: "xmark.circle", role: .destructive) {
                                    state.confirmationTarget = process
                                    state.showTerminationConfirmation = true
                                }.disabled(!process.canTerminate)
                            } label: {
                                Image(systemName: "ellipsis.circle").frame(width: 32)
                            }
                            .menuStyle(.borderlessButton)
                            .help(process.canTerminate ? "更多操作" : "系统进程或其他用户的进程不能从此处结束")
                        }
                        .font(.system(size: 13))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(process.id.isMultiple(of: 2) ? Color.primary.opacity(0.035) : .clear)
                        .contextMenu {
                            Button("结束进程…", systemImage: "xmark.circle", role: .destructive) {
                                state.confirmationTarget = process
                                state.showTerminationConfirmation = true
                            }.disabled(!process.canTerminate)
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .confirmationDialog("结束 \(state.confirmationTarget?.name ?? "进程")？", isPresented: $state.showTerminationConfirmation, titleVisibility: .visible) {
            Button("发送结束请求", role: .destructive) { requestGracefulTermination() }
            Button("取消", role: .cancel) { state.confirmationTarget = nil }
        } message: {
            Text("先尝试让进程正常退出（SIGTERM）。如果 3 秒后仍在运行，会再次询问是否强制结束。仅限当前用户拥有的普通进程。")
        }
        .alert("进程仍在运行", isPresented: $state.showForceKillConfirmation) {
            Button("强制结束", role: .destructive) { forceTerminate() }
            Button("继续等待", role: .cancel) { state.forceKillTarget = nil }
        } message: {
            Text("\(state.forceKillTarget?.name ?? "该进程")在收到正常结束请求后仍未退出。强制结束会立即停止它，可能导致未保存的数据丢失。")
        }
        .alert("无法结束进程", isPresented: Binding(get: { state.actionError != nil }, set: { if !$0 { state.actionError = nil } })) {
            Button("好", role: .cancel) { state.actionError = nil }
        } message: {
            Text(state.actionError ?? "")
        }
    }

    private func sortButton(_ title: String, column: ProcessSortColumn) -> some View {
        Button {
            if state.sortColumn == column { state.ascending.toggle() }
            else { state.sortColumn = column; state.ascending = false }
        } label: {
            HStack(spacing: 4) {
                Text(title)
                if state.sortColumn == column { Image(systemName: state.ascending ? "arrow.up" : "arrow.down") }
            }.frame(maxWidth: .infinity, alignment: .trailing)
        }
        .buttonStyle(.plain)
        .help("点击切换\(title)排序升序/降序")
    }

    private func requestGracefulTermination() {
        guard let process = state.confirmationTarget else { return }
        switch monitor.terminateProcess(process) {
        case .sent:
            state.confirmationTarget = nil
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                if monitor.isStillRunning(process) {
                    state.forceKillTarget = process
                    state.showForceKillConfirmation = true
                }
            }
        case .notAllowed: state.actionError = "出于安全限制，不能结束系统进程、其他用户的进程或 keitop 自身。"
        case .processChanged: state.actionError = "进程已退出或 PID 已被复用，请刷新后重试。"
        case .failed(let message): state.actionError = "系统拒绝了结束请求：\(message)"
        }
    }

    private func forceTerminate() {
        guard let process = state.forceKillTarget else { return }
        switch monitor.terminateProcess(process, force: true) {
        case .sent: state.forceKillTarget = nil
        case .notAllowed: state.actionError = "出于安全限制，不能结束该进程。"
        case .processChanged: state.actionError = "进程已退出或 PID 已被复用。"
        case .failed(let message): state.actionError = "系统拒绝了强制结束请求：\(message)"
        }
    }
}

struct SettingsPage: View {
    @Binding var darkMode: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("设置").font(.system(size: 24, weight: .semibold))
            HStack {
                Label("外观", systemImage: darkMode ? "moon.fill" : "sun.max.fill")
                Spacer()
                Picker("外观", selection: $darkMode) {
                    Text("暗色").tag(true)
                    Text("亮色").tag(false)
                }.pickerStyle(.segmented).frame(width: 180)
            }
            .padding(16).background(.quaternary.opacity(0.33), in: RoundedRectangle(cornerRadius: 12))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct OptionalChartDomain: ViewModifier {
    let domain: ClosedRange<Double>?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let domain {
            content.chartYScale(domain: domain)
        } else {
            content.chartYScale(domain: .automatic(includesZero: true))
        }
    }
}

struct FansPage: View {
    @EnvironmentObject private var monitor: SystemMonitor
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("风扇").font(.system(size: 24, weight: .semibold))
            if monitor.fans.isEmpty {
                HStack(spacing: 16) {
                    Image(systemName: "fanblades.fill").font(.system(size: 34)).foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("暂未读取到风扇传感器").font(.system(size: 16, weight: .semibold))
                        Text(monitor.sensorStatus).font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                }
                .padding(20).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 15))
            } else {
                ForEach(monitor.fans) { fan in
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Label(fan.name.uppercased(), systemImage: "fanblades.fill")
                            Spacer()
                            Text(fan.rpm.map { "\(Int($0)) RPM" } ?? "—")
                                .font(.system(size: 20, weight: .semibold, design: .rounded))
                        }
                        if let rpm = fan.rpm, let maxRPM = fan.max_rpm, maxRPM > 0 {
                            ProgressView(value: min(1, rpm / maxRPM))
                            Text("最大 \(Int(maxRPM)) RPM · 只读监控")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                    .padding(18).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 14))
                }
            }
            Text("通过传感器后端从 Apple SMC 读取。本页目前只读，不会修改风扇策略。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct RecordsPage: View {
    @EnvironmentObject private var monitor: SystemMonitor
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("记录").font(.system(size: 24, weight: .semibold)); Spacer(); Button("记录当前状态") { monitor.saveRecord() }.buttonStyle(.borderedProminent) }
            if monitor.records.isEmpty {
                ContentUnavailableView("暂无记录", systemImage: "clock.arrow.circlepath", description: Text("点击右上角按钮，保存此刻的 CPU 与内存状态。"))
                    .frame(maxWidth: .infinity, minHeight: 260)
            } else {
                ForEach(monitor.records) { record in
                    HStack {
                        Text(record.date.formatted(date: .abbreviated, time: .standard)).foregroundStyle(.secondary)
                        Spacer(); Label("CPU \(Int(record.cpu))%", systemImage: "cpu")
                        Label("内存 \(Int(record.memory))%", systemImage: "memorychip")
                    }.font(.system(size: 13)).padding(14).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }
    }
}

struct OSDSettingsPage: View {
    let openOSD: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("屏幕显示 OSD").font(.system(size: 24, weight: .semibold))
            Text("打开一个悬浮小窗，显示当前 CPU、内存与系统热状态。可拖动窗口放置在屏幕角落。")
                .font(.system(size: 14)).foregroundStyle(.secondary)
            Button(action: openOSD) { Label("打开 OSD 悬浮窗", systemImage: "rectangle.on.rectangle") }.buttonStyle(.borderedProminent)
        }.frame(maxWidth: .infinity, minHeight: 300, alignment: .topLeading)
    }
}

struct OSDView: View {
    @EnvironmentObject private var monitor: SystemMonitor
    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack { Image(systemName: "waveform.path").foregroundStyle(.cyan); Text("KeiTop").fontWeight(.semibold); Spacer(); Text("LIVE").font(.system(size: 9, weight: .bold)).foregroundStyle(.green) }
            Divider().overlay(.white.opacity(0.15))
            HStack { stat("CPU", "\(Int(monitor.cpuUsage))%", "cpu"); Spacer(); stat("GPU", monitor.gpuPower.map { String(format: "%.1f W", $0) } ?? "—", "square.stack.3d.up") }
            HStack { stat("CPU 温度", monitor.cpuTemperature.map { "\(Int($0))°" } ?? "—", "thermometer.medium"); Spacer(); stat("内存", "\(Int(monitor.memoryFraction * 100))%", "memorychip") }
        }.padding(16).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
    private func stat(_ title: String, _ value: String, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 5) { Label(title, systemImage: icon).font(.system(size: 10)).foregroundStyle(.secondary); Text(value).font(.system(size: 17, weight: .semibold, design: .rounded)) }
    }
}
