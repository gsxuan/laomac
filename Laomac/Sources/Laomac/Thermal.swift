import Foundation
import SwiftUI

// MARK: - CPU 采样点

struct CPUSample: Identifiable {
    let id = UUID()
    let date: Date
    let usage: Double   // 0~100
}

struct SensorReading: Identifiable {
    let id: String      // SMC 键名
    let key: String
    let label: String
    let value: Double   // ℃
}

enum WatchdogAction: String, CaseIterable, Identifiable {
    case renice = "降低优先级 (renice)"
    case kill   = "强制结束 (kill)"
    case notify = "仅提醒"
    var id: String { rawValue }
}

// MARK: - 温控服务
//
// 针对 Intel Mac (如 i7-8750H) 过热降频问题的完整优化方案:
// 1. 实时监控: 系统热状态 (ProcessInfo.thermalState) + 全核 CPU 使用率曲线
// 2. 降频检测: pmset -g therm 读取 CPU_Speed_Limit, <100 表示正在被降频
// 3. 压制守护: 自动发现持续高 CPU 的进程并降低其优先级或结束
// 4. 温度/风扇: 通过 powermetrics (需管理员) 读取 die 温度和风扇转速
// 5. 一键措施: 低功耗模式、立即压制当前高耗进程、优化建议
//

final class ThermalService: ObservableObject {
    // 实时监控
    @Published var thermalState: ProcessInfo.ThermalState = .nominal
    @Published var history: [CPUSample] = []
    @Published var currentCPU: Double = 0
    @Published var speedLimit: Int = 100        // CPU_Speed_Limit, <100 = 降频中
    @Published var dieTemp: Double?             // CPU die 温度 ℃
    @Published var fanSpeed: Int?               // 风扇 rpm
    @Published var sensorLoading = false

    // 压制守护 (设置持久化到 UserDefaults)
    @Published var watchdogOn = false {
        didSet { UserDefaults.standard.set(watchdogOn, forKey: "thermalWatchdogOn") }
    }
    @Published var threshold: Double = 250 {
        didSet { UserDefaults.standard.set(threshold, forKey: "thermalThreshold") }
    }
    @Published var sustainedSamples = 3 {
        didSet { UserDefaults.standard.set(sustainedSamples, forKey: "thermalSamples") }
    }
    @Published var action: WatchdogAction = .renice {
        didSet { UserDefaults.standard.set(action.rawValue, forKey: "thermalAction") }
    }
    @Published var events: [String] = []
    @Published var hotProcesses: [ProcessItem] = []

    // 多温度传感器 (smctool temps, 参考 exelban/stats 的键表)
    @Published var sensors: [SensorReading] = []
    @Published var sensorsLoading = false

    private var timer: Timer?
    private var hotCount: [Int32: Int] = [:]
    private var handled = Set<Int32>()
    private let sampleInterval: TimeInterval = 3

    init() {
        let d = UserDefaults.standard
        watchdogOn = d.bool(forKey: "thermalWatchdogOn")
        if d.double(forKey: "thermalThreshold") > 0 { threshold = d.double(forKey: "thermalThreshold") }
        if d.integer(forKey: "thermalSamples") > 0 { sustainedSamples = d.integer(forKey: "thermalSamples") }
        if let raw = d.string(forKey: "thermalAction"), let a = WatchdogAction(rawValue: raw) { action = a }
    }

    // MARK: 生命周期

    func start() {
        NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.thermalState = ProcessInfo.processInfo.thermalState
            self.log("系统热状态变化: \(Self.thermalText(self.thermalState))")
        }
        thermalState = ProcessInfo.processInfo.thermalState
        startTimer()
    }

    deinit {
        timer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: sampleInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        tick()
    }

    // MARK: 采样循环

    private func tick() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let usage = Self.readCPUUsage()
            let limit = Self.readSpeedLimit()
            let procs = ProcessService.readTop(25)
            DispatchQueue.main.async {
                self.apply(usage: usage, limit: limit, procs: procs)
            }
        }
    }

    private func apply(usage: Double, limit: Int, procs: [ProcessItem]) {
        currentCPU = usage
        speedLimit = limit
        history.append(CPUSample(date: Date(), usage: usage))
        if history.count > 60 { history.removeFirst(history.count - 60) }
        hotProcesses = procs.filter { $0.cpu >= threshold }
        if watchdogOn { runWatchdog(on: procs) }

        if limit < 100 {
            log("⚠️ 检测到 CPU 降频: 当前速度限制 \(limit)%")
        }
    }

    /// 全核瞬时使用率: 用 top 第二次采样 (第一次是启动以来的平均值, 不准)
    private static func readCPUUsage() -> Double {
        let r = Shell.run("top -l 2 -n 0 -s 1 | grep 'CPU usage' | tail -1")
        if let match = r.text.range(of: #"([\d.]+)% idle"#, options: .regularExpression) {
            let numStr = r.text[match].split(separator: "%").first ?? ""
            if let idle = Double(numStr) { return max(0, min(100, 100 - idle)) }
        }
        return 0
    }

    /// CPU_Speed_Limit < 100 说明系统正在因过热而降频
    private static func readSpeedLimit() -> Int {
        let r = Shell.run("pmset -g therm | awk '/CPU_Speed_Limit/ {print $3}'")
        return Int(r.text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 100
    }

    // MARK: 压制守护

    private func runWatchdog(on procs: [ProcessItem]) {
        let myPid = ProcessInfo.processInfo.processIdentifier
        var current = Set<Int32>()
        for p in procs where p.cpu >= threshold && p.pid != myPid {
            current.insert(p.pid)
            hotCount[p.pid, default: 0] += 1
            if let count = hotCount[p.pid], count >= sustainedSamples, !handled.contains(p.pid) {
                handled.insert(p.pid)
                switch action {
                case .renice:
                    let ok = Shell.run("renice +15 -p \(p.pid) 2>/dev/null").ok
                    log(ok ? "🛡️ 已降低 \(p.name) (PID \(p.pid)) 优先级"
                           : "降低优先级失败: \(p.name) (可能需要管理员权限)")
                case .kill:
                    let ok = Shell.run("kill -9 \(p.pid) 2>/dev/null").ok
                    log(ok ? "⛔ 已结束高耗进程 \(p.name) (PID \(p.pid))"
                           : "结束失败: \(p.name) (可能需要管理员权限)")
                case .notify:
                    log("🔔 提醒: \(p.name) (PID \(p.pid)) CPU 达 \(Int(p.cpu))%")
                }
            }
        }
        // 恢复正常后重置计数
        for pid in Array(hotCount.keys) where !current.contains(pid) {
            hotCount.removeValue(forKey: pid)
            handled.remove(pid)
        }
    }

    /// 一键压制当前所有超阈值进程
    func suppressNow() {
        let procs = hotProcesses
        guard !procs.isEmpty else {
            log("当前没有超过阈值的进程")
            return
        }
        let myPid = ProcessInfo.processInfo.processIdentifier
        for p in procs where p.pid != myPid {
            let ok = Shell.run("renice +15 -p \(p.pid) 2>/dev/null").ok
            log(ok ? "🛡️ 已压制 \(p.name) (PID \(p.pid))" : "压制失败: \(p.name)")
        }
    }

    // MARK: 传感器 (需要管理员权限)

    func refreshSensors() {
        guard !sensorLoading else { return }
        sensorLoading = true
        let cmd = "powermetrics --samplers smc -i 1000 -n 1 2>/dev/null"
        Shell.runAdminAsync(cmd) { [weak self] r in
            guard let self else { return }
            self.sensorLoading = false
            if r.code == -2 { self.log("已取消传感器读取"); return }
            if !r.ok {
                self.log("传感器读取失败: \(r.text.prefix(80))")
                return
            }
            if let m = r.text.range(of: #"CPU die temperature: ([\d.]+) C"#, options: .regularExpression) {
                let seg = r.text[m]
                let numStr = seg.replacingOccurrences(of: "CPU die temperature: ", with: "")
                    .replacingOccurrences(of: " C", with: "")
                self.dieTemp = Double(numStr)
            }
            if let m = r.text.range(of: #"Fan[^0-9]*(\d+) rpm"#, options: .regularExpression) {
                let seg = r.text[m]
                let digits = seg.filter { $0.isNumber }
                self.fanSpeed = Int(digits)
            }
            self.log("传感器已刷新: \(self.dieTemp.map { String(format: "%.1f℃", $0) } ?? "--") / " +
                     "\(self.fanSpeed.map { "\($0) rpm" } ?? "--")")
        }
    }

    // MARK: 多传感器温度 (smctool temps, 需管理员)

    func refreshSensorList() {
        guard !sensorsLoading else { return }
        guard PrivilegedTool.activePath != nil else {
            log("未找到 smctool, 请用 ./build-app.sh 打包后使用")
            return
        }
        sensorsLoading = true
        PrivilegedTool.run("temps") { [weak self] r in
            guard let self else { return }
            self.sensorsLoading = false
            if r.code == -2 { self.log("已取消传感器读取"); return }
            var list: [SensorReading] = []
            for line in r.text.split(separator: "\n") {
                let parts = line.split(separator: "|")
                if parts.count == 3, let v = Double(parts[2]) {
                    list.append(SensorReading(id: String(parts[0]), key: String(parts[0]),
                                              label: String(parts[1]), value: v))
                }
            }
            list.sort { $0.value > $1.value }
            self.sensors = list
            self.log(list.isEmpty ? "未读到有效温度传感器: \(r.text.prefix(60))"
                                  : "已读取 \(list.count) 个温度传感器")
        }
    }

    // MARK: 低功耗模式 (部分 Intel 机型不支持)

    func setLowPowerMode(_ on: Bool) {
        let cmd = "pmset -a lowpowermode \(on ? 1 : 0) 2>&1"
        Shell.runAdminAsync(cmd) { [weak self] r in
            if r.code == -2 { self?.log("已取消"); return }
            self?.log(r.ok ? (on ? "✅ 已开启低功耗模式" : "✅ 已关闭低功耗模式")
                           : "低功耗模式设置失败 (该 Intel 机型可能不支持): \(r.text.prefix(60))")
        }
    }

    // MARK: 工具

    func log(_ msg: String) {
        let time = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        events.insert("[\(time)] \(msg)", at: 0)
        if events.count > 100 { events.removeLast(events.count - 100) }
    }

    var thermalText: String { Self.thermalText(thermalState) }

    static func thermalText(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal:  return "正常"
        case .fair:     return "偏热"
        case .serious:  return "过热"
        case .critical: return "严重过热"
        @unknown default: return "未知"
        }
    }

    var thermalColor: Color {
        switch thermalState {
        case .nominal:  return .green
        case .fair:     return .yellow
        case .serious:  return .orange
        case .critical: return .red
        @unknown default: return .gray
        }
    }
}
