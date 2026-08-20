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
            InfoRow(label: "当前模式", value: app.throttle.fan.currentMode)
            if app.throttle.fan.available {
                if !app.throttle.fan.currentRPMs.isEmpty {
                    InfoRow(label: "实时转速",
                            value: app.throttle.fan.currentRPMs.enumerated()
                                .map { "风扇\($0.offset): \($0.element) rpm" }.joined(separator: "  "))
                }
                Toggle("降频时自动拉满风扇", isOn: Binding(
                    get: { app.throttle.fan.isEnabled },
                    set: { _ in app.throttle.toggleFan() }
                ))
                .toggleStyle(.switch)

                HStack(spacing: 8) {
                    Button("立即拉满") { app.throttle.fanFullSpeed() }
                        .buttonStyle(.bordered)
                    Button("恢复自动调速") { app.throttle.fanNormalSpeed() }
                        .buttonStyle(.bordered)
                }
                Text("手动定速/联动期间风扇不受系统控制; 恢复自动后交还 SMC 调速。重启后 SMC 自动复位为自动模式。")
                    .font(.caption2).foregroundColor(.secondary)
            } else {
                Text("未找到 smctool, 请用 ./build-app.sh 打包后使用")
                    .font(.caption).foregroundColor(.secondary)
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
