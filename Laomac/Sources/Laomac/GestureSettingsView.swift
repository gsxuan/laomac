import SwiftUI

// MARK: - 鼠标手势页 (原 MouseGesture 设置窗口, 融合为主界面分区)

struct GestureSettingsView: View {
    @EnvironmentObject var app: AppState
    @AppStorage(SettingsKey.enabled) private var enabled = true
    @AppStorage(SettingsKey.threshold) private var threshold = 80.0
    @AppStorage(SettingsKey.ratio) private var ratio = 0.8
    @AppStorage(SettingsKey.showTrail) private var showTrail = true
    @AppStorage(SettingsKey.lineWidth) private var lineWidth = 5.0
    @AppStorage(SettingsKey.colorHex) private var colorHex = "#4A90FF"
    @AppStorage(SettingsKey.actionUp) private var actionUp = GestureAction.missionControl.rawValue
    @AppStorage(SettingsKey.actionDown) private var actionDown = GestureAction.minimize.rawValue
    @AppStorage(SettingsKey.actionLeft) private var actionLeft = GestureAction.switchWindow.rawValue
    @AppStorage(SettingsKey.actionRight) private var actionRight = GestureAction.switchApp.rawValue

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                statusCard

                Card(title: "手势") {
                    Toggle("启用右键手势", isOn: Binding(
                        get: { enabled },
                        set: { newValue in
                            enabled = newValue
                            if newValue { app.gestures.tryStart(prompt: true) }
                            else { app.gestures.stop() }
                        }
                    ))
                    .toggleStyle(.switch)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("触发距离:\(Int(threshold)) pt(拖动超过该距离才生效)")
                        Slider(value: $threshold, in: 40...300, step: 5)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("方向判定宽容度:\(String(format: "%.1f", ratio))(越小越要求画直线)")
                        Slider(value: $ratio, in: 0.2...1.5, step: 0.1)
                    }
                }

                Card(title: "四方向动作") {
                    actionPicker("上拉 ↑", selection: $actionUp)
                    actionPicker("下拉 ↓", selection: $actionDown)
                    actionPicker("左拉 ←", selection: $actionLeft)
                    actionPicker("右拉 →", selection: $actionRight)
                }

                Card(title: "轨迹可视化") {
                    Toggle("拖动时显示轨迹", isOn: $showTrail)
                        .toggleStyle(.switch)
                    ColorPicker("轨迹颜色", selection: trailColor, supportsOpacity: false)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("轨迹粗细:\(Int(lineWidth)) pt")
                        Slider(value: $lineWidth, in: 2...12, step: 1)
                    }
                    .disabled(!showTrail)
                }

                Text("用法:在任意窗口按住鼠标右键,向上/下/左/右画直线后松开,触发对应方向绑定的动作。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(20)
        }
        .navigationTitle("鼠标手势")
    }

    // MARK: 服务状态

    private var statusCard: some View {
        Card(title: "服务状态", subtitle: "手势监听需要「辅助功能」权限") {
            HStack(spacing: 10) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)
                Text(statusText)
                    .font(.callout)
                Spacer()
                if !app.gestures.trusted {
                    Button("授予辅助功能权限…") {
                        app.gestures.tryStart(prompt: true)
                    }
                    .buttonStyle(.borderedProminent)
                } else if !app.gestures.running && enabled {
                    Button("启动引擎") {
                        app.gestures.tryStart(prompt: false)
                    }
                    .buttonStyle(.bordered)
                }
                Button {
                    app.gestures.refreshTrust()
                } label: {
                    Label("重新检查", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
            }
            if !app.gestures.trusted {
                Text("授权后若状态未更新, 点击「重新检查」或重启应用。")
                    .font(.caption2).foregroundColor(.secondary)
            }
        }
    }

    private var statusColor: Color {
        if !app.gestures.trusted { return .red }
        if !enabled { return .gray }
        return app.gestures.running ? .green : .orange
    }

    private var statusText: String {
        if !app.gestures.trusted { return "未获得辅助功能权限" }
        if !enabled { return "手势已关闭" }
        return app.gestures.running ? "运行中" : "已授权但未启动"
    }

    private func actionPicker(_ label: String, selection: Binding<String>) -> some View {
        Picker(label, selection: selection) {
            ForEach(GestureAction.allCases) { action in
                Text(action.displayName).tag(action.rawValue)
            }
        }
    }

    private var trailColor: Binding<Color> {
        Binding(
            get: { colorFromHex(colorHex) },
            set: { colorHex = hexString(from: $0) }
        )
    }
}
