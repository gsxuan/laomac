import Foundation
import SwiftUI
import UserNotifications
import Combine

// MARK: - 降频监控 (原 ThrottleMonitor 核心逻辑)
//
// 每 5 秒采样一次 pmset -g therm 与 kernel_task 占用,
// 检测到降频时推送通知, 并可通过 smctool 直写 SMC 键控制风扇转速。

struct ThrottleSnapshot {
    let timestamp: Date
    let speedLimit: Int
    let schedulerLimit: Int
    let availableCPUs: Int
    let kernelTaskCPU: Double
    var isThrottling: Bool {
        speedLimit < 100 || schedulerLimit < 100 || kernelTaskCPU > 100
    }
    var severity: String {
        if speedLimit < 70 || kernelTaskCPU > 300 { return "严重" }
        if speedLimit < 85 || kernelTaskCPU > 200 { return "中等" }
        if speedLimit < 100 || kernelTaskCPU > 100 { return "轻微" }
        return "正常"
    }
}

// MARK: - 风扇控制器 (smctool 直写 SMC, 不依赖第三方软件)
//
// SMC 键: FxTg(目标转速 fpe2) FxMd(手动模式) FxAc(当前转速) FxMx(上限) FS!(模式位图)
// 三种模式: 系统自动 / 手动定速(滑杆) / 温控曲线(温度→转速插值, 仿 Macs Fan Control)

/// 温控曲线控制点 (温度 ℃ → 转速 rpm, 点间线性插值)
struct FanCurvePoint: Codable, Equatable {
    var temp: Double
    var rpm: Double
}

final class FanController: ObservableObject {
    static let shared = FanController()

    // 降频联动: 降频时拉满风扇, 解除后恢复自动 (设置持久化)
    var isEnabled: Bool = UserDefaults.standard.bool(forKey: "fanSmartEnabled") {
        didSet { UserDefaults.standard.set(isEnabled, forKey: "fanSmartEnabled") }
    }
    var isBoosted = false
    var lastSwitchTime: Date = .distantPast
    let switchCooldown: TimeInterval = 10

    // 实时状态 (由 faninfo 刷新)
    @Published var fanCount = 0
    @Published var currentRPMs: [Int] = []
    @Published var maxRPMs: [Int] = []
    @Published var manualActive = false
    @Published var available = PrivilegedTool.activePath != nil

    // MARK: 手动定速与温控曲线状态 (均持久化)

    /// 默认曲线: 低温静音 → 高温满速 (超限转速会被 smctool 自动钳制到风扇上限)
    static let defaultCurve: [FanCurvePoint] = [
        .init(temp: 40, rpm: 2000), .init(temp: 60, rpm: 3200),
        .init(temp: 80, rpm: 4600), .init(temp: 95, rpm: 5900),
    ]

    /// 手动模式各风扇滑杆目标值 (下标对应风扇编号)
    @Published var manualTargets: [Double] = [2500, 2500]
    /// 温控曲线开关 (重启后随 app 启动自动恢复)
    @Published var curveOn = UserDefaults.standard.bool(forKey: "fanCurveOn") {
        didSet { UserDefaults.standard.set(curveOn, forKey: "fanCurveOn") }
    }
    /// 曲线控制点 (按温度升序保存, 编辑后自动持久化)
    @Published var curvePoints: [FanCurvePoint] = FanController.loadCurve() {
        didSet { FanController.saveCurve(curvePoints) }
    }
    /// 曲线采样到的 CPU 温度 (界面展示用)
    @Published var curveTemp: Double?
    private var lastCurveRPM = 0
    private var curveApplied = false
    private var curveBusy = false

    private static func loadCurve() -> [FanCurvePoint] {
        guard let data = UserDefaults.standard.data(forKey: "fanCurvePoints"),
              let pts = try? JSONDecoder().decode([FanCurvePoint].self, from: data),
              !pts.isEmpty else { return defaultCurve }
        return pts.sorted { $0.temp < $1.temp }
    }

    private static func saveCurve(_ pts: [FanCurvePoint]) {
        if let data = try? JSONEncoder().encode(pts) {
            UserDefaults.standard.set(data, forKey: "fanCurvePoints")
        }
    }

    private func run(_ args: String, _ done: @escaping (ShellResult) -> Void) {
        guard PrivilegedTool.activePath != nil else {
            DispatchQueue.main.async { self.available = false }
            return
        }
        PrivilegedTool.run(args) { r in done(r) }
    }

    /// 刷新风扇实时状态 (已安装特权组件时免密码)
    func refresh() {
        run("faninfo") { [weak self] r in
            guard let self else { return }
            guard r.ok else { self.available = false; return }
            self.available = true
            var cur: [Int] = [], mx: [Int] = [], manual = false
            for line in r.text.split(separator: "\n") {
                let s = String(line)
                func val(_ k: String) -> Int? {
                    guard let m = s.range(of: "\(k)=(-?\\d+)", options: .regularExpression) else { return nil }
                    return Int(s[m].components(separatedBy: "=").last ?? "")
                }
                if let c = val("cur") { cur.append(c) }
                if let m2 = val("max"), m2 > 0 { mx.append(m2) }
                if (val("manual") ?? 0) != 0 { manual = true }
            }
            self.fanCount = cur.count
            self.currentRPMs = cur
            self.maxRPMs = mx
            self.manualActive = manual
            if !manual { self.isBoosted = false }
        }
    }

    /// 所有风扇拉到各自上限转速 (手动接管, 关闭温控曲线)
    func setFullSpeed() {
        curveOn = false
        let n = max(fanCount, 1)
        // 多参数形式单进程写入: 旧的 "&&" 拼接会逐个启动进程,
        // 且第二个起的命令会命中 fanset 多参数语法解析失败, 导致部分风扇拉满失败并卡死在手动模式
        let cmds = "fanset " + Array(repeating: "12000", count: n).joined(separator: " ")
        run(cmds) { [weak self] r in
            guard let self else { return }
            if r.ok {
                self.manualActive = true
                self.isBoosted = true
                self.isEnabled = true
                self.lastSwitchTime = Date()
            }
            NSLog("[Laomac] 风扇满速: \(r.ok ? "成功" : "失败 \(r.text.prefix(60))")")
            self.refresh()
        }
    }

    /// 恢复 SMC 自动调速 (同时关闭温控曲线)
    func setAuto() {
        curveOn = false
        curveApplied = false
        lastCurveRPM = 0
        run("fanset auto") { [weak self] r in
            guard let self else { return }
            if r.ok {
                self.manualActive = false
                self.isBoosted = false
                self.lastSwitchTime = Date()
            }
            NSLog("[Laomac] 风扇恢复自动: \(r.ok ? "成功" : "失败")")
            self.refresh()
        }
    }

    /// 根据降频状态联动风扇 (温控曲线开启时让位, 不干预)
    func update(isThrottling: Bool) {
        guard isEnabled, !curveOn else { return }
        let now = Date()
        guard now.timeIntervalSince(lastSwitchTime) > switchCooldown else { return }
        if isThrottling && !isBoosted {
            setFullSpeed()
        } else if !isThrottling && isBoosted {
            setAuto()
        }
    }

    func stop() {
        isEnabled = false
        curveOn = false
        if manualActive { setAuto() }
    }

    var currentMode: String {
        if curveOn { return "温控曲线" }
        if manualActive { return "手动定速" }
        return "系统自动"
    }

    // MARK: 手动定速 (滑杆目标值 → 逐风扇应用)

    /// 按 manualTargets 对每个风扇定速; 手动接管时关闭温控曲线与降频联动避免互抢
    func applyManual() {
        let n = max(fanCount, 1)
        while manualTargets.count < n { manualTargets.append(2500) }
        curveOn = false
        isEnabled = false
        // 多参数形式: fanset <风扇0转速> <风扇1转速> ... 单进程一次写入, 避免逐个启动进程间的 SMC 竞争
        let cmds = "fanset " + (0..<n).map { "\(Int(manualTargets[$0]))" }.joined(separator: " ")
        run(cmds) { [weak self] r in
            guard let self else { return }
            if r.ok {
                self.manualActive = true
                self.isBoosted = false
            }
            NSLog("[Laomac] 手动定速: \(r.ok ? "成功" : "失败 \(r.text.prefix(60))")")
            self.refresh()
        }
    }

    // MARK: 温控曲线 (温度采样 → 插值 → 调速)
    //
    // 由 ThrottleService 的 5 秒节拍调用: 读 CPU 温度 (TC0E 优先), 按曲线插值目标转速,
    // 与上次施加值相差 ≥150 rpm 才写 SMC (防抖, 避免高频写键)。
    // 仅在 app 运行期间生效; SMC 重启后复位为自动, app 启动时按持久化开关重新接管。

    /// 开关温控曲线 (与降频联动互斥)
    func setCurveEnabled(_ on: Bool) {
        if on {
            isEnabled = false
            curveOn = true
            curveApplied = false
            curveTick(force: true)
        } else {
            setAuto()
        }
    }

    func curveTick(force: Bool = false) {
        guard curveOn, !curveBusy, PrivilegedTool.activePath != nil else { return }
        curveBusy = true
        run("temps") { [weak self] r in
            guard let self else { return }
            self.curveBusy = false
            guard self.curveOn, r.ok else { return }
            var temps: [String: Double] = [:]
            for line in r.text.split(separator: "\n") {
                let parts = line.split(separator: "|")
                if parts.count == 3, let v = Double(parts[2]) { temps[String(parts[0])] = v }
            }
            // 优先 CPU Die 均值, 其次 CPU 附近, 兜底全传感器最高温 (更保守)
            guard let temp = temps["TC0E"] ?? temps["TC0P"] ?? temps.values.max() else { return }
            self.curveTemp = temp
            let target = self.interpolate(temp: temp)
            if !force, self.curveApplied, abs(target - self.lastCurveRPM) < 150 { return }
            let n = max(self.fanCount, 1)
            // 多参数形式一次写入全部风扇 (单进程, 避免逐个写时与其它风扇操作的 SMC 竞争)
            let cmds = "fanset " + Array(repeating: "\(target)", count: n).joined(separator: " ")
            self.run(cmds) { res in
                if res.ok {
                    self.lastCurveRPM = target
                    self.curveApplied = true
                    self.manualActive = true
                } else {
                    // 失败不更新防抖基准, 下个 5 秒节拍自动重试 (自愈)
                    self.curveApplied = false
                }
                NSLog("[Laomac] 温控曲线: \(Int(temp))℃ → \(target) rpm (\(res.ok ? "已施加" : "失败, 待重试"))")
            }
        }
    }

    /// 线性插值: 低于首点取首点转速, 高于末点取末点转速, 中间线性过渡
    func interpolate(temp: Double) -> Int {
        let pts = curvePoints.sorted { $0.temp < $1.temp }
        guard let first = pts.first else { return 2500 }
        if temp <= first.temp { return Int(first.rpm) }
        guard let last = pts.last else { return Int(first.rpm) }
        if temp >= last.temp { return Int(last.rpm) }
        for i in 0..<(pts.count - 1) {
            let a = pts[i], b = pts[i + 1]
            if temp >= a.temp && temp <= b.temp {
                let k = (temp - a.temp) / max(b.temp - a.temp, 0.1)
                return Int(a.rpm + (b.rpm - a.rpm) * k)
            }
        }
        return Int(last.rpm)
    }
}

// MARK: - 历史记录

final class ThrottleHistoryStore {
    var snapshots: [ThrottleSnapshot] = []
    var throttleEvents: [(date: Date, severity: String, speedLimit: Int)] = []
    let maxSnapshots = 120
    let maxEvents = 50

    func add(_ s: ThrottleSnapshot) {
        snapshots.append(s)
        if snapshots.count > maxSnapshots { snapshots.removeFirst(snapshots.count - maxSnapshots) }
        if s.isThrottling {
            throttleEvents.append((date: s.timestamp, severity: s.severity, speedLimit: s.speedLimit))
            if throttleEvents.count > maxEvents { throttleEvents.removeFirst(throttleEvents.count - maxEvents) }
        }
    }

    func clear() { snapshots.removeAll(); throttleEvents.removeAll() }

    var sparkline: String {
        let recent = Array(snapshots.suffix(30))
        guard !recent.isEmpty else { return "── 暂无数据 ──" }
        let bars = ["▁","▂","▃","▄","▅","▆","▇","█"]
        return recent.map { s -> String in
            let ratio = max(0, min(1, Double(100 - s.speedLimit) / 30.0))
            let idx = min(Int(ratio * Double(bars.count - 1)), bars.count - 1)
            return s.isThrottling ? bars[max(3, idx)] : bars[0]
        }.joined()
    }

    var maxSpeed: Int { snapshots.map(\.speedLimit).max() ?? 100 }
    var minSpeed: Int { snapshots.map(\.speedLimit).min() ?? 100 }
    var avgSpeed: Int { guard !snapshots.isEmpty else { return 100 }; return snapshots.map(\.speedLimit).reduce(0,+) / snapshots.count }
    var peakKernel: Double { snapshots.map(\.kernelTaskCPU).max() ?? 0 }
}

// MARK: - 降频监控服务

final class ThrottleService: ObservableObject {
    @Published var current = ThrottleSnapshot(timestamp: Date(), speedLimit: 100,
                                              schedulerLimit: 100, availableCPUs: 12,
                                              kernelTaskCPU: 0)
    @Published var eventLog: [String] = []

    let store = ThrottleHistoryStore()
    let fan = FanController.shared
    private var timer: Timer?
    private var wasThrottling = false
    private var fanTick = 0
    private var fanSub: AnyCancellable?

    init() {
        // 风扇状态变化同步驱动本视图刷新
        fanSub = fan.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    func start() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        check()
        fan.refresh()
        // 温控曲线开关持久化: SMC 重启后会复位为自动, 启动时按上次设置重新接管 (延迟等 faninfo 就绪)
        if fan.curveOn {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, self.fan.curveOn else { return }
                self.fan.curveTick(force: true)
                self.log("🌀 温控曲线已按上次设置恢复")
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.check()
        }
        if let timer { RunLoop.current.add(timer, forMode: .common) }
    }

    deinit { timer?.invalidate() }

    // MARK: 采样

    private func check() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }

            var speed = 100, sched = 100, cpus = 12

            if let out = self.run("/usr/bin/pmset", ["-g", "therm"]) {
                for line in out.components(separatedBy: "\n") {
                    let cleaned = line.replacingOccurrences(of: "\t", with: " ")
                                      .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard cleaned.contains("=") else { continue }
                    let kv = cleaned.components(separatedBy: "=").map { $0.trimmingCharacters(in: .whitespaces) }
                    guard kv.count >= 2, let v = Int(kv[1]) else { continue }
                    switch kv[0] {
                    case "CPU_Speed_Limit": speed = v
                    case "CPU_Scheduler_Limit": sched = v
                    case "CPU_Available_CPUs": cpus = v
                    default: break
                    }
                }
            }

            var kCPU = 0.0
            if let out = self.run("/bin/ps", ["aux"]) {
                for line in out.components(separatedBy: "\n") where line.contains("kernel_task") {
                    let cols = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                    if cols.count > 2, let v = Double(cols[2]) { kCPU = v; break }
                }
            }

            let snap = ThrottleSnapshot(timestamp: Date(), speedLimit: speed, schedulerLimit: sched,
                                        availableCPUs: cpus, kernelTaskCPU: kCPU)

            // 降频时联动风扇 + 温控曲线节拍 + 周期性刷新风扇实时转速
            self.fan.update(isThrottling: snap.isThrottling)
            self.fan.curveTick()
            self.fanTick += 1
            if self.fanTick % 3 == 0 { self.fan.refresh() }

            DispatchQueue.main.async {
                let wasT = self.current.isThrottling
                self.current = snap
                self.store.add(snap)

                if !wasT && snap.isThrottling {
                    self.notify("⚠️ CPU 降频警告", "CPU 正在降频（\(snap.severity)），频率: \(snap.speedLimit)%")
                    self.log("⚠️ 检测到降频: \(snap.severity), 频率限制 \(snap.speedLimit)%")
                } else if wasT && !snap.isThrottling {
                    self.notify("✅ CPU 恢复正常", "降频已解除，CPU 满速运行")
                    self.log("✅ 降频解除, CPU 恢复满速")
                }
                self.wasThrottling = snap.isThrottling
            }
        }
    }

    private func run(_ path: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardInput = FileHandle.nullDevice
        let outPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = Pipe()
        do {
            try p.run()
            let deadline = Date(timeIntervalSinceNow: 3.0)
            while p.isRunning && Date() < deadline { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1)) }
            if p.isRunning { p.terminate(); return nil }
            return String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        } catch { return nil }
    }

    private func notify(_ title: String, _ body: String) {
        let c = UNMutableNotificationContent()
        c.title = title; c.body = body; c.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }

    // MARK: 风扇操作 (供界面调用, smctool 直写 SMC)

    func toggleFan() {
        fan.isEnabled.toggle()
        if fan.isEnabled && fan.curveOn { fan.curveOn = false }   // 与温控曲线互斥
        if !fan.isEnabled && fan.manualActive { fan.setAuto() }
        log(fan.isEnabled ? "🌀 降频联动风扇已启用" : "🌀 风扇联动已关闭")
        objectWillChange.send()
    }

    func fanFullSpeed() {
        fan.setFullSpeed()
        log("🌀 风扇已拉满 (手动定速)")
        objectWillChange.send()
    }

    func fanNormalSpeed() {
        fan.setAuto()
        log("🌀 风扇已恢复系统自动调速")
        objectWillChange.send()
    }

    /// 界面滑杆应用手动定速 (FanController 内会关闭曲线/联动避免互抢)
    func fanApplyManual() {
        fan.applyManual()
        log("🌀 已按滑杆值手动定速")
        objectWillChange.send()
    }

    /// 界面开关温控曲线 (开=立即按曲线接管, 关=恢复系统自动)
    func fanToggleCurve(_ on: Bool) {
        fan.setCurveEnabled(on)
        log(on ? "🌀 温控曲线已启用 (按 CPU 温度自动调速)" : "🌀 温控曲线已关闭")
        objectWillChange.send()
    }

    func clearHistory() {
        store.clear()
        log("已清除历史记录")
        objectWillChange.send()
    }

    private func log(_ msg: String) {
        let time = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        eventLog.insert("[\(time)] \(msg)", at: 0)
        if eventLog.count > 50 { eventLog.removeLast(eventLog.count - 50) }
    }
}
