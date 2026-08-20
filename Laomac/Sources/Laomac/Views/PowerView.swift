import SwiftUI
import Charts

// MARK: - 电源管理页 (电池信息 / 功率监控统计 / 充电限制 / 定时开关机)

struct PowerView: View {
    @EnvironmentObject var app: AppState
    @State private var confirmRestart = false
    @State private var confirmShutdown = false

    private var power: PowerService { app.power }
    private var info: BatteryInfo { power.info }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                HStack(alignment: .top, spacing: 16) {
                    statusCard
                    healthCard
                }
                chartCard
                limitCard
                scheduleCard
                quickCard
                if let msg = power.message {
                    Text(msg)
                        .font(.callout)
                        .foregroundColor(msg.contains("失败") || msg.contains("未") ? .orange : .green)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(20)
        }
        .navigationTitle("电源管理")
        .onAppear { power.refreshChargeLimit() }
        .confirmationDialog("确认重启电脑?", isPresented: $confirmRestart, titleVisibility: .visible) {
            Button("重启", role: .destructive) { systemAction("restart") }
            Button("取消", role: .cancel) {}
        }
        .confirmationDialog("确认关闭电脑?", isPresented: $confirmShutdown, titleVisibility: .visible) {
            Button("关机", role: .destructive) { systemAction("shut down") }
            Button("取消", role: .cancel) {}
        }
    }

    // MARK: 电池状态

    private var statusCard: some View {
        Card(title: "电池状态", subtitle: "每 10 秒采样一次 (ioreg)") {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text(String(format: "%.0f%%", info.percent))
                    .font(.system(size: 40, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundColor(info.percent <= 20 && !info.externalConnected ? .red : .primary)
                VStack(alignment: .leading, spacing: 4) {
                    Label(info.powerSource,
                          systemImage: info.externalConnected ? "powerplug.fill" : "battery.50")
                        .font(.callout.weight(.medium))
                    Text(timeText)
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            Divider()
            InfoRow(label: "AC 适配器功率",
                    value: info.externalConnected
                        ? (info.adapterWatts > 0 ? "\(info.adapterWatts) W" : "--")
                        : "未接入电源")
            InfoRow(label: "电池实时功率",
                    value: String(format: "%.1f W (%@)", info.watts, info.isCharging ? "充电" : "放电"))
        }
    }

    private var timeText: String {
        let m = info.timeRemaining
        guard m > 0 else { return "剩余时间: 计算中…" }
        let prefix = info.isCharging ? "预计充满" : "预计可用"
        return String(format: "%@: %d 小时 %02d 分", prefix, m / 60, m % 60)
    }

    // MARK: 电池健康

    private var healthCard: some View {
        Card(title: "电池健康") {
            HStack(spacing: 10) {
                Circle()
                    .fill(healthColor)
                    .frame(width: 10, height: 10)
                Text(String(format: "健康度 %.1f%%", info.healthPercent))
                    .font(.callout.weight(.medium))
            }
            InfoRow(label: "满充容量", value: "\(info.maxCapacity) mAh")
            InfoRow(label: "设计容量", value: "\(info.designCapacity) mAh")
            InfoRow(label: "循环计数", value: "\(info.cycleCount) 次")
            InfoRow(label: "电池温度", value: String(format: "%.1f ℃", info.temperature))
            InfoRow(label: "电压", value: String(format: "%.3f V", info.voltage))
            InfoRow(label: "电流", value: String(format: "%.2f A", info.amperage))
        }
    }

    private var healthColor: Color {
        if info.healthPercent >= 90 { return .green }
        if info.healthPercent >= 80 { return .yellow }
        return .orange
    }

    // MARK: 功率曲线

    private var chartCard: some View {
        Card(title: "功率趋势", subtitle: "最近 30 分钟 (10 秒粒度)") {
            if power.history.isEmpty {
                Text("采样中…").font(.caption).foregroundColor(.secondary)
            } else {
                Chart(power.history) { s in
                    LineMark(
                        x: .value("时间", s.date),
                        y: .value("功率", s.watts)
                    )
                    .interpolationMethod(.monotone)
                    AreaMark(
                        x: .value("时间", s.date),
                        y: .value("功率", s.watts)
                    )
                    .foregroundStyle(.linearGradient(
                        colors: [.green.opacity(0.25), .clear],
                        startPoint: .top, endPoint: .bottom))
                }
                .frame(height: 150)
            }
            HStack(spacing: 24) {
                statBlock("峰值功率", String(format: "%.1f W", power.maxWatts))
                statBlock("最低功率", String(format: "%.1f W", power.minWatts))
                statBlock("平均功率", String(format: "%.1f W", power.avgWatts))
                statBlock("当前电量", String(format: "%.0f%%", info.percent))
            }
        }
    }

    private func statBlock(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundColor(.secondary)
            Text(value).font(.callout.monospacedDigit().weight(.medium))
        }
    }

    // MARK: 充电限制

    private var limitCard: some View {
        Card(title: "充电限制",
             subtitle: "监控循环 + CHBI 禁充键 (同 AlDente/Battery Toolkit 思路), app 运行期间生效") {
            if !power.limitAvailable {
                Label(power.message ?? "充电限制在此环境不可用",
                      systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundColor(.orange)
            } else {
                Toggle("充电上限维持模式", isOn: $app.power.maintainOn)
                    .toggleStyle(.switch)
                InfoRow(label: "当前状态", value: limitStateText)
                VStack(alignment: .leading, spacing: 4) {
                    Text("充电上限: \(Int(power.limitPercent))% (掉到 \(Int(power.limitPercent) - 5)% 以下自动恢复充电)")
                        .font(.callout)
                    Slider(value: $app.power.limitPercent, in: 50...100, step: 5)
                }
                HStack(spacing: 8) {
                    Button(power.chargeInhibited ? "恢复充电" : "立即停止充电") {
                        power.setChargeInhibited(!power.chargeInhibited)
                    }
                    .buttonStyle(.bordered)
                    .disabled(power.limitLoading)
                    Spacer()
                    Button {
                        power.refreshChargeLimit()
                    } label: {
                        if power.limitLoading {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("刷新", systemImage: "arrow.clockwise")
                        }
                    }
                    .buttonStyle(.bordered)
                }
                Text("注: 保护电池建议日常上限设为 80%; 维持模式需 Laomac 保持运行, 重启/退出后需重新开启 (会自动按上次设置恢复); 「立即停止充电」在重新插拔电源后可能被系统恢复。")
                    .font(.caption2).foregroundColor(.secondary)
            }
        }
    }

    private var limitStateText: String {
        var s = power.maintainOn
            ? "维持中 · 上限 \(Int(power.limitPercent))%"
            : "维持模式关闭"
        if power.chargeInhibited { s += " · 已停止充电" }
        return s
    }

    // MARK: 定时开关机

    private var scheduleCard: some View {
        Card(title: "定时开关机", subtitle: "基于 pmset repeat (仅 Intel 机型支持)") {
            Toggle("定时自动开机", isOn: $app.power.powerOnEnabled)
                .toggleStyle(.switch)
            HStack(spacing: 12) {
                DatePicker("", selection: $app.power.powerOnTime,
                           displayedComponents: .hourAndMinute)
                    .labelsHidden()
                Picker("", selection: $app.power.powerOnDays) {
                    ForEach(DayPreset.allCases) { d in
                        Text(d.label).tag(d)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 260)
            }
            .disabled(!power.powerOnEnabled)

            Divider().padding(.vertical, 2)

            Toggle("定时自动关机", isOn: $app.power.shutdownEnabled)
                .toggleStyle(.switch)
            HStack(spacing: 12) {
                DatePicker("", selection: $app.power.shutdownTime,
                           displayedComponents: .hourAndMinute)
                    .labelsHidden()
                Picker("", selection: $app.power.shutdownDays) {
                    ForEach(DayPreset.allCases) { d in
                        Text(d.label).tag(d)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 260)
                Picker("", selection: $app.power.shutdownAction) {
                    ForEach(ShutdownAction.allCases) { a in
                        Text(a.rawValue).tag(a)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }
            .disabled(!power.shutdownEnabled)

            HStack(spacing: 8) {
                Button("应用定时计划") { power.applySchedule() }
                    .buttonStyle(.borderedProminent)
                Button("取消全部计划") { power.cancelSchedule() }
                    .buttonStyle(.bordered)
                Spacer()
                Button {
                    power.refreshSchedule()
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
            }

            Text("当前系统计划:\n\(power.scheduleText)")
                .font(.caption.monospaced())
                .foregroundColor(.secondary)
                .textSelection(.enabled)
        }
    }

    // MARK: 一键操作

    private var quickCard: some View {
        Card(title: "一键操作") {
            HStack(spacing: 8) {
                Button {
                    Shell.runAsync("pmset sleepnow") { _ in }
                } label: {
                    Label("立即睡眠", systemImage: "moon")
                }
                .buttonStyle(.bordered)

                Button {
                    confirmRestart = true
                } label: {
                    Label("重启…", systemImage: "arrow.clockwise.circle")
                }
                .buttonStyle(.bordered)

                Button {
                    confirmShutdown = true
                } label: {
                    Label("关机…", systemImage: "power")
                }
                .buttonStyle(.bordered)
                .foregroundColor(.red)
            }
        }
    }

    private func systemAction(_ verb: String) {
        let source = "tell application \"System Events\" to \(verb)"
        DispatchQueue.main.async {
            NSAppleScript(source: source)?.executeAndReturnError(nil)
        }
    }
}
