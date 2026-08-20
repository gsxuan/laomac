import SwiftUI

// MARK: - 应用设置页 (菜单栏 / Dock 图标显示, 开机自启)

struct AppSettingsView: View {
    @AppStorage(AppSettingsKey.showMenuBar) private var showMenuBar = true
    @AppStorage(AppSettingsKey.showDock) private var showDock = true
    @State private var launchAtLogin = LaunchAtLogin.isEnabled

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Card(title: "图标显示", subtitle: "可自由组合, 建议至少保留一个入口") {
                    Toggle("在菜单栏显示图标", isOn: $showMenuBar)
                        .toggleStyle(.switch)
                    Text("菜单栏图标可随时打开菜单、切换手势、唤出主窗口。")
                        .font(.caption2).foregroundColor(.secondary)

                    Divider().padding(.vertical, 2)

                    Toggle("在 Dock 栏显示图标", isOn: $showDock)
                        .toggleStyle(.switch)
                        .onChange(of: showDock) { newValue in
                            AppSettings.setShowDock(newValue)
                        }
                    Text("关闭后应用以后台模式运行, Dock 中不再出现图标。")
                        .font(.caption2).foregroundColor(.secondary)

                    if !showMenuBar && !showDock {
                        Label("两个入口都已隐藏, 只能通过活动监视器或重启方式找到本应用!",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }

                Card(title: "常规") {
                    Toggle("开机自动启动", isOn: Binding(
                        get: { launchAtLogin },
                        set: { newValue in
                            LaunchAtLogin.setEnabled(newValue)
                            launchAtLogin = LaunchAtLogin.isEnabled
                        }
                    ))
                    .toggleStyle(.switch)
                }

                Card(title: "关于") {
                    InfoRow(label: "名称", value: "Laomac")
                    InfoRow(label: "版本", value: "1.0")
                    InfoRow(label: "融合自", value: "MacOptimizer + MouseGesture + ThrottleMonitor")
                }
            }
            .padding(20)
        }
        .navigationTitle("应用设置")
    }
}
