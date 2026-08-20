import SwiftUI
import Charts

// MARK: - CPU 降温页

struct ThermalView: View {
    @EnvironmentObject var app: AppState
    @State private var lowPowerOn = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                HStack(alignment: .top, spacing: 16) {
                    monitorCard
                    sensorCard
                }
                multiSensorCard
                chartCard
                HStack(alignment: .top, spacing: 16) {
                    watchdogCard
                    hotProcessCard
                }
                adviceCard
                eventLogCard
            }
            .padding(20)
        }
        .navigationTitle("CPU 降温")
    }

    // MARK: 实时监控

    private var monitorCard: some View {
        Card(title: "实时监控", subtitle: "每 3 秒采样一次") {
            HStack(spacing: 10) {
                Circle()
                    .fill(app.thermal.thermalColor)
                    .frame(width: 14, height: 14)
                Text(app.thermal.thermalText)
                    .font(.title3.weight(.semibold))
                    .foregroundColor(app.thermal.thermalColor)
            }
            HStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("CPU 使用率").font(.caption).foregroundColor(.secondary)
                    Text(String(format: "%.1f%%", app.thermal.currentCPU))
                        .font(.title2.monospacedDigit().weight(.medium))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("速度限制").font(.caption).foregroundColor(.secondary)
                    Text("\(app.thermal.speedLimit)%")
                        .font(.title2.monospacedDigit().weight(.medium))
                        .foregroundColor(app.thermal.speedLimit < 100 ? .orange : .primary)
                }
            }
            if app.thermal.speedLimit < 100 {
                Label("CPU 正在因过热被降频, 建议压制高耗进程并改善散热",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundColor(.orange)
            }
            Button {
                app.thermal.suppressNow()
            } label: {
                Label("一键压制高耗进程", systemImage: "hare")
            }
            .buttonStyle(.borderedProminent)
            .disabled(app.thermal.hotProcesses.isEmpty)
        }
    }

    // MARK: 传感器

    private var sensorCard: some View {
        Card(title: "温度 / 风扇", subtitle: "读取需要管理员密码 (powermetrics)") {
            HStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("CPU 核心温度").font(.caption).foregroundColor(.secondary)
                    Text(app.thermal.dieTemp.map { String(format: "%.1f ℃", $0) } ?? "--")
                        .font(.title2.monospacedDigit().weight(.medium))
                        .foregroundColor(tempColor)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("风扇转速").font(.caption).foregroundColor(.secondary)
                    Text(app.thermal.fanSpeed.map { "\($0) rpm" } ?? "--")
                        .font(.title2.monospacedDigit().weight(.medium))
                }
            }
            Button {
                app.thermal.refreshSensors()
            } label: {
                if app.thermal.sensorLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Label("读取传感器", systemImage: "thermometer.sun")
                }
            }
            .buttonStyle(.bordered)
            .disabled(app.thermal.sensorLoading)

            Divider()

            Toggle("低功耗模式 (限制性能换取低温)", isOn: $lowPowerOn)
                .toggleStyle(.switch)
                .font(.callout)
                .onChange(of: lowPowerOn) { newValue in
                    app.thermal.setLowPowerMode(newValue)
                }
            Text("注: 部分 Intel 机型不支持此选项, 结果见事件日志")
                .font(.caption2).foregroundColor(.secondary)
        }
    }

    private var tempColor: Color {
        guard let t = app.thermal.dieTemp else { return .primary }
        if t >= 95 { return .red }
        if t >= 80 { return .orange }
        if t >= 65 { return .yellow }
        return .green
    }

    // MARK: 多温度传感器 (smctool 直读 SMC, 键表参考 exelban/stats)

    private var multiSensorCard: some View {
        Card(title: "多温度传感器", subtitle: "smctool 直读 SMC, 按温度降序排列") {
            HStack {
                Button {
                    app.thermal.refreshSensorList()
                } label: {
                    if app.thermal.sensorsLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("读取全部传感器", systemImage: "thermometer.sun")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(app.thermal.sensorsLoading)
                Spacer()
                if !app.thermal.sensors.isEmpty {
                    Text("共 \(app.thermal.sensors.count) 个").font(.caption).foregroundColor(.secondary)
                }
            }
            if app.thermal.sensors.isEmpty {
                Text("点「读取全部传感器」获取 CPU/GPU/电池/掌托等各部位温度")
                    .font(.caption).foregroundColor(.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 12)], spacing: 8) {
                    ForEach(app.thermal.sensors) { s in
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(s.label).font(.caption).foregroundColor(.secondary)
                                Text(s.key).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                            }
                            Spacer()
                            Text(String(format: "%.1f℃", s.value))
                                .font(.callout.monospacedDigit().weight(.medium))
                                .foregroundColor(s.value >= 90 ? .red : s.value >= 75 ? .orange : .primary)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
        }
    }

    // MARK: 使用率曲线

    private var chartCard: some View {
        Card(title: "CPU 使用率曲线", subtitle: "最近 3 分钟") {
            Chart(app.thermal.history) { sample in
                LineMark(
                    x: .value("时间", sample.date),
                    y: .value("CPU", sample.usage)
                )
                .interpolationMethod(.monotone)
                AreaMark(
                    x: .value("时间", sample.date),
                    y: .value("CPU", sample.usage)
                )
                .foregroundStyle(.linearGradient(
                    colors: [.blue.opacity(0.3), .clear],
                    startPoint: .top, endPoint: .bottom))
            }
            .chartYScale(domain: 0...100)
            .chartYAxis {
                AxisMarks(values: [0, 25, 50, 75, 100])
            }
            .frame(height: 160)
        }
    }

    // MARK: 压制守护

    private var watchdogCard: some View {
        Card(title: "压制守护",
             subtitle: "自动处理持续占用过高的进程, 防止过热降频") {
            Toggle("启用守护", isOn: Binding(
                get: { app.thermal.watchdogOn },
                set: { app.thermal.watchdogOn = $0 }
            ))
            .toggleStyle(.switch)

            VStack(alignment: .leading, spacing: 6) {
                Text("触发阈值: \(Int(app.thermal.threshold))% CPU")
                    .font(.callout)
                Slider(value: Binding(
                    get: { app.thermal.threshold },
                    set: { app.thermal.threshold = $0 }
                ), in: 100...600, step: 50)
                Text("多核累计占用, i7-8750H 满载为 1200%")
                    .font(.caption2).foregroundColor(.secondary)
            }

            Stepper("持续 \(app.thermal.sustainedSamples) 次采样后处理 (约 \(app.thermal.sustainedSamples * 3) 秒)",
                    value: Binding(
                        get: { app.thermal.sustainedSamples },
                        set: { app.thermal.sustainedSamples = $0 }
                    ), in: 1...10)
                .font(.callout)

            Picker("处理方式", selection: Binding(
                get: { app.thermal.action },
                set: { app.thermal.action = $0 }
            )) {
                ForEach(WatchdogAction.allCases) { a in
                    Text(a.rawValue).tag(a)
                }
            }
            .pickerStyle(.menu)
        }
    }

    // MARK: 高耗进程

    private var hotProcessCard: some View {
        Card(title: "当前高耗进程",
             subtitle: "超过阈值的进程 (每 3 秒更新)") {
            if app.thermal.hotProcesses.isEmpty {
                Text("✅ 当前没有高耗进程")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 20)
            } else {
                ForEach(app.thermal.hotProcesses) { p in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.name.split(separator: "/").last.map(String.init) ?? p.name)
                                .font(.callout).lineLimit(1)
                            Text("PID \(p.pid)").font(.caption2).foregroundColor(.secondary)
                        }
                        Spacer()
                        Text(String(format: "%.0f%%", p.cpu))
                            .font(.callout.monospacedDigit().weight(.medium))
                            .foregroundColor(.red)
                        Button("压制") {
                            app.processes.renice(p.pid)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        Button("结束") {
                            app.processes.kill(p.pid, force: true)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .foregroundColor(.red)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    // MARK: 优化建议

    private var adviceCard: some View {
        Card(title: "过热降频优化方案") {
            VStack(alignment: .leading, spacing: 8) {
                adviceRow("开启压制守护", "自动限制后台失控进程, 是降频问题的第一道防线")
                adviceRow("排查后台大户", "在「进程管理」中结束不需要的进程; 在「启动项」中禁用常驻后台程序")
                adviceRow("降低 Turbo Boost 冲击", "安装 Turbo Boost Switcher 等工具可在高温时禁用睿频, 降温 10℃ 以上 (需系统权限)")
                adviceRow("物理散热", "垫高机身底部、避免软表面、定期清理进出风口灰尘 (2018 款建议每年清灰换硅脂)")
                adviceRow("系统设置", "系统设置 > 电池 中开启「优化电池充电」; 高温环境避免边充边用")
                adviceRow("释放磁盘空间", "存储接近满载会加剧发热, 可在「空间清理」中回收空间")
            }
        }
    }

    private func adviceRow(_ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
                .font(.callout)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.medium))
                Text(detail).font(.caption).foregroundColor(.secondary)
            }
        }
    }

    // MARK: 事件日志

    private var eventLogCard: some View {
        Card(title: "事件日志") {
            if app.thermal.events.isEmpty {
                Text("暂无事件").font(.caption).foregroundColor(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(app.thermal.events, id: \.self) { e in
                            Text(e).font(.caption.monospaced())
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 160)
            }
        }
    }
}
