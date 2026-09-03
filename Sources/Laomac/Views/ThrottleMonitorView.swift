import SwiftUI

// MARK: - 降频监控页 (原 ThrottleMonitor 菜单栏应用, 融合为主界面分区)

struct ThrottleMonitorView: View {
    @EnvironmentObject var app: AppState

    private var snap: ThrottleSnapshot { app.throttle.current }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                HStack(alignment: .top, spacing: 16) {
                    statusCard
                    fanCard
                }
                historyCard
                eventCard
            }
            .padding(20)
        }
        .navigationTitle("降频监控")
    }

    // MARK: 实时状态

    private var statusCard: some View {
        Card(title: "实时状态", subtitle: "每 5 秒采样一次 (pmset + kernel_task)") {
            HStack(spacing: 10) {
                Circle()
                    .fill(snap.isThrottling ? Color.orange : Color.green)
                    .frame(width: 14, height: 14)
                Text(snap.isThrottling ? "CPU 正在降频 — \(snap.severity)" : "CPU 运行正常")
                    .font(.title3.weight(.semibold))
                    .foregroundColor(snap.isThrottling ? .orange : .green)
            }
            InfoRow(label: "频率限制", value: "\(snap.speedLimit)%")
            InfoRow(label: "调度限制", value: "\(snap.schedulerLimit)%")
            InfoRow(label: "可用核心", value: "\(snap.availableCPUs)")
            InfoRow(label: "kernel_task", value: String(format: "%.1f%%", snap.kernelTaskCPU))
            if snap.isThrottling {
                Label("建议前往「CPU 降温」页压制高耗进程, 或手动加速风扇",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundColor(.orange)
            }
        }
    }

    // MARK: 风扇控制

    private var fanCard: some View {
        Card(title: "风扇控制",
             subtitle: PrivilegedTool.installed
                 ? "特权组件已安装, 风扇操作不再需要密码"
                 : "smctool 直写 SMC; 特权组件安装前需管理员授权") {
            let fan = app.throttle.fan
            InfoRow(label: "当前模式", value: fan.currentMode)
            if fan.available {
                if !fan.currentRPMs.isEmpty {
                    InfoRow(label: "实时转速",
                            value: fan.currentRPMs.enumerated()
                                .map { "风扇\($0.offset): \($0.element) rpm" }.joined(separator: "  "))
                }
                Toggle("降频时自动拉满风扇", isOn: Binding(
                    get: { fan.isEnabled },
                    set: { _ in app.throttle.toggleFan() }
                ))
                .toggleStyle(.switch)

                HStack(spacing: 8) {
                    Button("立即拉满") { app.throttle.fanFullSpeed() }
                        .buttonStyle(.bordered)
                    Button("恢复自动调速") { app.throttle.fanNormalSpeed() }
                        .buttonStyle(.bordered)
                }

                Divider().padding(.vertical, 2)
                manualSection(fan)
                Divider().padding(.vertical, 2)
                curveSection(fan)

                Text("手动定速/曲线/联动期间风扇不受系统控制; 恢复自动后交还 SMC 调速。三种手动模式互斥, 后启用者生效; 重启后 SMC 复位为自动, 曲线开关随 app 启动自动恢复。")
                    .font(.caption2).foregroundColor(.secondary)
            } else {
                Text("未找到 SMC 组件 smctool (应随 app 一起分发), 风扇控制不可用。")
                    .font(.caption).foregroundColor(.secondary)
                Button("安装 / 更新 SMC 组件") {
                    app.throttle.fan.installHelper { ok in
                        if !ok { app.throttle.fan.available = false }
                    }
                }
                .buttonStyle(.bordered)
            }
        }
    }

    // MARK: 手动定速 (每风扇一个滑杆)

    private func manualSection(_ fan: FanController) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("手动定速").font(.callout.weight(.medium))
            ForEach(Array(0..<max(fan.fanCount, 1)), id: \.self) { i in
                let maxRPM = fan.maxRPMs.count > i ? Double(fan.maxRPMs[i]) : 6000
                HStack(spacing: 8) {
                    Text("风扇\(i)")
                        .font(.caption).foregroundColor(.secondary)
                        .frame(width: 40, alignment: .leading)
                    Slider(value: Binding(
                        get: { fan.manualTargets.count > i ? fan.manualTargets[i] : 2500 },
                        set: { v in
                            while fan.manualTargets.count <= i { fan.manualTargets.append(2500) }
                            fan.manualTargets[i] = v
                        }
                    ), in: 1200...maxRPM, step: 50)
                    Text("\(Int(fan.manualTargets.count > i ? fan.manualTargets[i] : 2500)) rpm")
                        .font(.caption.monospacedDigit())
                        .frame(width: 72, alignment: .trailing)
                }
            }
            Button("按滑杆值定速") { app.throttle.fanApplyManual() }
                .buttonStyle(.bordered)
        }
    }

    // MARK: 温控曲线 (温度 → 转速 插值)

    private func curveSection(_ fan: FanController) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("温控曲线 (按 CPU 温度自动调速)", isOn: Binding(
                get: { fan.curveOn },
                set: { app.throttle.fanToggleCurve($0) }
            ))
            .toggleStyle(.switch)

            if fan.curveOn {
                if let t = fan.curveTemp {
                    InfoRow(label: "曲线采样温度",
                            value: String(format: "%.1f ℃ → 目标 %d rpm", t, fan.interpolate(temp: t)))
                }
                ForEach(Array(fan.curvePoints.indices), id: \.self) { i in
                    VStack(spacing: 2) {
                        HStack(spacing: 8) {
                            Text("点\(i + 1) 温度")
                                .font(.caption).foregroundColor(.secondary)
                                .frame(width: 56, alignment: .leading)
                            Slider(value: Binding(
                                get: { fan.curvePoints[i].temp },
                                set: { fan.curvePoints[i].temp = $0 }
                            ), in: 30...100, step: 1)
                            Text("\(Int(fan.curvePoints[i].temp))℃")
                                .font(.caption.monospacedDigit())
                                .frame(width: 48, alignment: .trailing)
                        }
                        HStack(spacing: 8) {
                            Text("      转速")
                                .font(.caption).foregroundColor(.secondary)
                                .frame(width: 56, alignment: .leading)
                            Slider(value: Binding(
                                get: { fan.curvePoints[i].rpm },
                                set: { fan.curvePoints[i].rpm = $0 }
                            ), in: 1200...6000, step: 100)
                            Text("\(Int(fan.curvePoints[i].rpm)) rpm")
                                .font(.caption.monospacedDigit())
                                .frame(width: 72, alignment: .trailing)
                        }
                    }
                }
                Button("恢复默认曲线") { fan.curvePoints = FanController.defaultCurve }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Text("每 5 秒采样一次, 点间线性插值, 转速变化 ≥150 rpm 才写入 (防抖)。")
                    .font(.caption2).foregroundColor(.secondary)
            }
        }
    }

    // MARK: 历史记录

    private var historyCard: some View {
        Card(title: "历史记录", subtitle: "保留最近 \(app.throttle.store.snapshots.count) 次采样") {
            InfoRow(label: "降频趋势", value: app.throttle.store.sparkline)
            HStack(spacing: 24) {
                statBlock("最高频率", "\(app.throttle.store.maxSpeed)%")
                statBlock("最低频率", "\(app.throttle.store.minSpeed)%")
                statBlock("平均频率", "\(app.throttle.store.avgSpeed)%")
                statBlock("kernel 峰值", String(format: "%.0f%%", app.throttle.store.peakKernel))
                statBlock("累计降频", "\(app.throttle.store.throttleEvents.count) 次")
            }

            if !app.throttle.store.throttleEvents.isEmpty {
                Divider()
                Text("最近降频事件")
                    .font(.callout.weight(.medium))
                ForEach(Array(app.throttle.store.throttleEvents.suffix(8).enumerated()), id: \.offset) { _, ev in
                    HStack {
                        Text(Self.timeFmt.string(from: ev.date))
                            .font(.caption.monospacedDigit()).foregroundColor(.secondary)
                        Text(ev.severity)
                            .font(.caption).foregroundColor(.orange)
                        Spacer()
                        Text("频率: \(ev.speedLimit)%")
                            .font(.caption.monospacedDigit())
                    }
                }
            }

            Button("清除历史记录") { app.throttle.clearHistory() }
                .buttonStyle(.bordered)
                .disabled(app.throttle.store.snapshots.isEmpty)
        }
    }

    private func statBlock(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundColor(.secondary)
            Text(value).font(.callout.monospacedDigit().weight(.medium))
        }
    }

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    // MARK: 事件日志

    private var eventCard: some View {
        Card(title: "事件日志") {
            if app.throttle.eventLog.isEmpty {
                Text("暂无事件").font(.caption).foregroundColor(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(app.throttle.eventLog, id: \.self) { e in
                            Text(e).font(.caption.monospaced())
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 140)
            }
        }
    }
}
