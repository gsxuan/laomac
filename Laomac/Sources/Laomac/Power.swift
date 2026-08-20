import Foundation
import SwiftUI

// MARK: - 电源管理 (电池信息 / 功率监控与统计 / 充电限制 / 定时开关机)

struct PowerSample: Identifiable {
    let id = UUID()
    let date: Date
    let watts: Double     // 电池瞬时功率 (绝对值, W)
    let percent: Double   // 电量百分比
}

struct BatteryInfo {
    var present = false
    var externalConnected = false
    var isCharging = false
    var fullyCharged = false
    var percent: Double = 0
    var maxCapacity = 0       // mAh 当前满充容量
    var designCapacity = 0    // mAh 设计容量
    var cycleCount = 0
    var temperature: Double = 0   // ℃
    var voltage: Double = 0       // V
    var amperage: Double = 0      // A (充电为正, 放电为负)
    var timeRemaining = 0         // 分钟
    var adapterWatts = 0          // AC 适配器功率

    var healthPercent: Double {
        designCapacity > 0 ? Double(maxCapacity) / Double(designCapacity) * 100 : 0
    }
    var watts: Double { abs(voltage * amperage) }
    var powerSource: String {
        if externalConnected {
            if isCharging { return "交流电源 · 充电中" }
            return fullyCharged ? "交流电源 · 已充满" : "交流电源 · 未在充电"
        }
        return "电池供电 · 放电中"
    }
}

// MARK: - 定时开关机枚举

enum DayPreset: String, CaseIterable, Identifiable {
    case all      = "MTWRFSU"
    case weekdays = "MTWRF"
    case weekend  = "SU"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all:      return "每天"
        case .weekdays: return "工作日"
        case .weekend:  return "周末"
        }
    }

    /// 从 pmset -g sched 的星期描述反推预设
    static func from(text: String) -> DayPreset {
        let s = text.lowercased()
        if s.contains("weekday") { return .weekdays }
        if s.contains("weekend") { return .weekend }
        let words = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]
        let present = words.filter { s.contains($0) }
        if present.count == 7 { return .all }
        if present == ["mon", "tue", "wed", "thu", "fri"] { return .weekdays }
        if present == ["sat", "sun"] { return .weekend }
        return .all
    }
}

enum ShutdownAction: String, CaseIterable, Identifiable {
    case shutdown = "关机"
    case sleep    = "睡眠"
    var id: String { rawValue }
}

// MARK: - 电源服务

final class PowerService: ObservableObject {
    @Published var info = BatteryInfo()
    @Published var history: [PowerSample] = []
    @Published var message: String?

    // 充电限制
    @Published var limitAvailable = true
    @Published var limitLoading = false
    @Published var limitEnabled = false
    @Published var limitCurrentValue: Int?
    @Published var limitPercent: Double = UserDefaults.standard.double(forKey: "chargeLimitPercent") > 0
        ? UserDefaults.standard.double(forKey: "chargeLimitPercent") : 80 {
        didSet { UserDefaults.standard.set(limitPercent, forKey: "chargeLimitPercent") }
    }
    @Published var chargeInhibited = false

    // 充电上限维持模式 (AlDente/Battery Toolkit 同款思路: CHBI 禁充键 + 监控循环)
    @Published var maintainOn = UserDefaults.standard.bool(forKey: "chargeMaintainOn") {
        didSet {
            UserDefaults.standard.set(maintainOn, forKey: "chargeMaintainOn")
            if maintainOn {
                tickChargeLimit(force: true)   // 立即施加一次
            } else if chargeInhibited {
                // 兜底: 关闭时必须恢复充电, 避免禁充卡死
                setChargeInhibited(false)
            }
        }
    }
    /// 回差: 掉到上限以下多少才恢复充电, 避免阈值附近频繁开关伤电池
    static let maintainHysteresis: Double = 5

    // 定时开关机
    @Published var powerOnEnabled = false
    @Published var powerOnTime = PowerService.dateAt(9, 0)
    @Published var powerOnDays: DayPreset = .all
    @Published var shutdownEnabled = false
    @Published var shutdownTime = PowerService.dateAt(23, 0)
    @Published var shutdownDays: DayPreset = .all
    @Published var shutdownAction: ShutdownAction = .shutdown
    @Published var scheduleText = "--"

    private var timer: Timer?

    static func dateAt(_ hour: Int, _ minute: Int) -> Date {
        Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? Date()
    }

    func start() {
        refreshBattery()
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.refreshBattery()
        }
        if let timer { RunLoop.current.add(timer, forMode: .common) }
        refreshSchedule()
        // 延迟到管理员授权就绪后执行启动兜底
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.startupFailsafe()
        }
    }

    /// 启动兜底: 维持模式关闭但 SMC 仍处于禁充状态 (如上次异常退出) 时主动恢复充电,
    /// 避免用户电池卡在无法充电的状态 (成熟充电限制软件的必备安全逻辑)
    private func startupFailsafe() {
        guard !maintainOn, Self.smcToolPath != nil else { return }
        runSmc("read CHBI") { [weak self] r in
            guard let self else { return }
            let v = Int(r.text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            if r.ok, v != 0 {
                NSLog("[Laomac] 检测到残留禁充状态, 自动恢复充电")
                self.chargeInhibited = true
                self.setChargeInhibited(false)
            }
        }
    }

    deinit { timer?.invalidate() }

    // MARK: 电池采样 (ioreg, 无需 root)

    func refreshBattery() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let out = Shell.run("ioreg -rn AppleSmartBattery -w0").text

            func intV(_ key: String) -> Int? {
                // 注意: 键名前加空格, 避免 DesignCapacity 误匹配 NomadDesignCapacity 等长键
                guard let r = out.range(of: " \"\(key)\" = (-?\\d+)", options: .regularExpression) else { return nil }
                let num = out[r].components(separatedBy: "=").last?
                    .trimmingCharacters(in: .whitespaces) ?? ""
                return Int(num)
            }
            func boolV(_ key: String) -> Bool { out.contains("\"\(key)\" = Yes") }

            var b = BatteryInfo()
            b.present = out.contains("BatteryInfo") || out.contains("AppleSmartBattery")
            b.externalConnected = boolV("ExternalConnected")
            b.isCharging = boolV("IsCharging")
            b.fullyCharged = boolV("FullyCharged")
            b.designCapacity = intV("DesignCapacity") ?? 0
            b.maxCapacity = intV("AppleRawMaxCapacity") ?? 0
            let current = intV("AppleRawCurrentCapacity") ?? 0
            b.percent = b.maxCapacity > 0 ? Double(current) / Double(b.maxCapacity) * 100 : 0
            b.cycleCount = intV("CycleCount") ?? 0
            b.temperature = Double(intV("Temperature") ?? 0) / 100
            b.voltage = Double(intV("Voltage") ?? 0) / 1000
            b.amperage = Double(intV("InstantAmperage") ?? 0) / 1000
            b.timeRemaining = intV("TimeRemaining") ?? 0
            if let r = out.range(of: "\"Watts\"=(\\d+)", options: .regularExpression) {
                b.adapterWatts = Int(out[r].filter(\.isNumber)) ?? 0
            }

            let sample = PowerSample(date: Date(), watts: b.watts, percent: b.percent)
            DispatchQueue.main.async {
                self.info = b
                self.history.append(sample)
                if self.history.count > 180 { self.history.removeFirst(self.history.count - 180) }
                // 充电上限维持循环: 每次电池采样后执行判断 (10s 粒度)
                self.tickChargeLimit()
            }
        }
    }

    // MARK: 充电限制 (通过 smctool 以 root 写 SMC)
    //
    // BCLM: 充电限制模式 (0 关闭 / 1 开启)
    // CH0B: 充电上限百分比
    // CHBI: 禁止充电 (1 立即停止充电)
    // 注: SMC 键因机型固件而异, 不支持的键会在界面提示失败

    static var smcToolPath: String? {
        if let p = Bundle.main.path(forResource: "smctool", ofType: nil),
           FileManager.default.isExecutableFile(atPath: p) {
            return p
        }
        // 开发模式 (swift run) 时位于项目目录
        let dev = FileManager.default.currentDirectoryPath + "/smctool"
        return FileManager.default.isExecutableFile(atPath: dev) ? dev : nil
    }

    private func runSmc(_ args: String, _ done: @escaping (ShellResult) -> Void) {
        guard PrivilegedTool.activePath != nil else {
            DispatchQueue.main.async {
                self.limitAvailable = false
                self.message = "未找到 smctool, 请用 ./build-app.sh 打包后使用"
            }
            return
        }
        PrivilegedTool.run(args) { r in done(r) }
    }

    func refreshChargeLimit() {
        guard let tool = PrivilegedTool.activePath else {
            limitAvailable = false
            message = "未找到 smctool, 请用 ./build-app.sh 打包后使用"
            return
        }
        limitLoading = true
        let q = Shell.quote(tool)
        PrivilegedTool.runShell("\(q) read BCLM; \(q) read CH0B; \(q) read CHBI") { [weak self] r in
            guard let self = self else { return }
            self.limitLoading = false
            if r.code == -2 { self.message = "未获得管理员授权, 无法读取充电限制状态"; return }
            let lines = r.text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            if lines.count >= 1, let v = Int(lines[0]) { self.limitEnabled = v != 0 }
            if lines.count >= 2, let v = Int(lines[1]), (30...100).contains(v) {
                self.limitCurrentValue = v
                self.limitPercent = Double(v)
            } else {
                self.limitCurrentValue = nil
            }
            if lines.count >= 3, let v = Int(lines[2]) { self.chargeInhibited = v != 0 }
            if lines.isEmpty || !lines.contains(where: { Int($0) != nil }) {
                self.limitAvailable = false
                self.message = "SMC 读取失败, 该机型可能不支持充电限制键: \(r.text.prefix(60))"
            }
        }
    }

    func applyChargeLimit() {
        let p = Int(limitPercent)
        limitLoading = true
        let q = Shell.quote(PrivilegedTool.activePath ?? "")
        PrivilegedTool.runShell("\(q) write BCLM 1 && \(q) write CH0B \(p)") { [weak self] r in
            guard let self = self else { return }
            self.message = r.ok ? "已设置充电上限 \(p)% (BCLM/CH0B)" : "设置失败: \(r.text.prefix(60))"
            self.refreshChargeLimit()
        }
    }

    func disableChargeLimit() {
        limitLoading = true
        runSmc("write BCLM 0") { [weak self] r in
            guard let self = self else { return }
            self.message = r.ok ? "已关闭充电限制" : "关闭失败: \(r.text.prefix(60))"
            self.refreshChargeLimit()
        }
    }

    func setChargeInhibited(_ on: Bool) {
        limitLoading = true
        runSmc("write CHBI \(on ? 1 : 0)") { [weak self] r in
            guard let self = self else { return }
            self.limitLoading = false
            if r.ok {
                self.chargeInhibited = on
                self.message = on ? "已停止充电 (CHBI)" : "已恢复充电"
            } else {
                self.message = "操作失败: \(r.text.prefix(60))"
            }
        }
    }

    // MARK: 充电上限维持循环 (软件模拟固件限制, T2/Apple Silicon 机型通用方案)
    //
    // 本机型无固件百分比键 (CH0B 不存在), 改用监控循环:
    // 电量 ≥ 上限 → CHBI 1 禁充; 掉到 上限-回差 以下 → CHBI 0 恢复。
    // 仅在 app 运行期间生效 (与 AlDente 免费版同级限制)。

    /// 每次电池采样后调用; force=true 时忽略去抖立即施加 (开启时/写失败重试)
    private func tickChargeLimit(force: Bool = false) {
        guard maintainOn, Self.smcToolPath != nil, info.percent > 0 else { return }
        let limit = Int(limitPercent)
        let target: Bool
        if chargeInhibited {
            // 已禁充: 掉到 上限-回差 才恢复 (回差防抖)
            target = info.percent <= Double(limit) - Self.maintainHysteresis ? false : true
        } else {
            target = info.percent >= Double(limit)
        }
        // 去抖: 状态一致且非强制时不重复写 SMC
        guard target != chargeInhibited || force else { return }
        limitLoading = true
        let on = target ? 1 : 0
        runSmc("write CHBI \(on)") { [weak self] r in
            guard let self = self else { return }
            self.limitLoading = false
            if r.ok {
                self.chargeInhibited = target
                self.message = target
                    ? "🔋 电量达 \(Int(self.info.percent))%, 已暂停充电 (上限 \(limit)%)"
                    : "🔋 电量降至 \(Int(self.info.percent))%, 已恢复充电"
            } else if self.maintainOn {
                // 写失败: 30s 后的下次采样重试 (force 避免去抖拦截)
                DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
                    self?.tickChargeLimit(force: true)
                }
                self.message = "充电限制写入失败: \(r.text.prefix(60))"
            }
        }
    }

    // MARK: 定时开关机 (pmset repeat, 需 root)

    func refreshSchedule() {
        Shell.runAsync("pmset -g sched 2>&1") { [weak self] r in
            guard let self = self else { return }
            let text = r.text.trimmingCharacters(in: .whitespacesAndNewlines)
            self.scheduleText = text.isEmpty ? "(无计划任务)" : text
            self.parseSchedule(text)
        }
    }

    private func parseSchedule(_ text: String) {
        powerOnEnabled = false
        shutdownEnabled = false
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let m = line.range(of: #"^(wakeorpoweron|wake|poweron) at (\d{1,2}):(\d{2}):\d{2}\s+(.+)$"#,
                                  options: .regularExpression) {
                powerOnEnabled = true
                let parts = String(line[m]).split(separator: " ")
                if parts.count >= 4 {
                    let t = parts[2].split(separator: ":")
                    if t.count >= 2, let h = Int(t[0]), let mi = Int(t[1]) {
                        powerOnTime = Self.dateAt(h, mi)
                    }
                    powerOnDays = DayPreset.from(text: String(parts[3]))
                }
            } else if let m = line.range(of: #"^(shutdown|sleep) at (\d{1,2}):(\d{2}):\d{2}\s+(.+)$"#,
                                         options: .regularExpression) {
                shutdownEnabled = true
                shutdownAction = line.hasPrefix("shutdown") ? .shutdown : .sleep
                let parts = String(line[m]).split(separator: " ")
                if parts.count >= 4 {
                    let t = parts[2].split(separator: ":")
                    if t.count >= 2, let h = Int(t[0]), let mi = Int(t[1]) {
                        shutdownTime = Self.dateAt(h, mi)
                    }
                    shutdownDays = DayPreset.from(text: String(parts[3]))
                }
            }
        }
    }

    func applySchedule() {
        var args: [String] = []
        if powerOnEnabled {
            args += ["wakeorpoweron", powerOnDays.rawValue, Self.timeStr(powerOnTime)]
        }
        if shutdownEnabled {
            args += [shutdownAction == .shutdown ? "shutdown" : "sleep",
                     shutdownDays.rawValue, Self.timeStr(shutdownTime)]
        }
        let cmd = args.isEmpty ? "pmset repeat cancel" : "pmset repeat \(args.joined(separator: " "))"
        Shell.runAdminAsync(cmd + " 2>&1") { [weak self] r in
            guard let self = self else { return }
            self.message = r.ok
                ? (args.isEmpty ? "已取消全部定时任务" : "定时任务已生效")
                : "设置失败: \(r.text.prefix(80))"
            self.refreshSchedule()
        }
    }

    func cancelSchedule() {
        powerOnEnabled = false
        shutdownEnabled = false
        applySchedule()
    }

    static func timeStr(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return String(format: "%d:%02d:00", c.hour ?? 0, c.minute ?? 0)
    }

    // MARK: 会话统计

    var maxWatts: Double { history.map(\.watts).max() ?? 0 }
    var minWatts: Double { history.map(\.watts).min() ?? 0 }
    var avgWatts: Double {
        guard !history.isEmpty else { return 0 }
        return history.map(\.watts).reduce(0, +) / Double(history.count)
    }
}
