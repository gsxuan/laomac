import SwiftUI
import AppKit

// MARK: - App 入口
//
// Laomac = MacOptimizer(优化中心) + MouseGesture(鼠标手势) + ThrottleMonitor(降频监控)
// 菜单栏图标与 Dock 图标均可在「应用设置」中独立开关。

@main
struct LaomacApp: App {
    @NSApplicationDelegateAdaptor(LaomacAppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()
    @AppStorage(AppSettingsKey.showMenuBar) private var showMenuBar = true
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup("Laomac", id: "main") {
            ContentView()
                .environmentObject(appState)
                .frame(minWidth: 1040, minHeight: 680)
                // 从系统设置授权返回后自动刷新辅助功能状态, 无需手动点重新检查
                .onChange(of: scenePhase) { phase in
                    if phase == .active { appState.gestures.refreshTrust() }
                }
        }

        MenuBarExtra(isInserted: $showMenuBar) {
            MenuBarView()
                .environmentObject(appState)
        } label: {
            let throttling = appState.throttle.current.isThrottling
            Label(throttling ? "降频 \(appState.throttle.current.speedLimit)%" : "",
                  systemImage: throttling ? "exclamationmark.triangle.fill" : "laptopcomputer")
        }
        .menuBarExtraStyle(.menu)
    }
}

// MARK: - AppDelegate

final class LaomacAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        GestureDefaults.register()
        AppSettings.applyActivationPolicy()

        // 管理员授权改为懒触发: 首次用到提权功能时才弹密码框 (支持 Touch ID),
        // 风扇/传感器/充电操作在安装特权组件后永久免密码, 日常使用不再弹窗
    }

    /// 常驻菜单栏运行: 关闭主窗口不退出
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

// MARK: - 全局状态容器

final class AppState: ObservableObject {
    let thermal = ThermalService()
    let info = SystemInfoService()
    let processes = ProcessService()
    let launchAgents = LaunchAgentsService()
    let disk = DiskService()
    let clean = CleanService()
    let uninstaller = UninstallerService()
    let tune = TuneService()
    let throttle = ThrottleService()
    let gestures = GestureService()
    @Published var power = PowerService()
    @Published var net = NetSpeedService()

    init() {
        thermal.start()
        info.load()
        processes.refresh()
        launchAgents.refresh()
        tune.refresh()
        throttle.start()
        gestures.autoStart()
        power.start()
        net.start()

        // 重量级磁盘扫描延迟 1 秒执行, 保证首屏快速出现
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.disk.scan()
            self?.clean.refresh()
            // 安装特权组件 (仅首次需管理员授权, 之后风扇/传感器/充电操作永久免密码)
            PrivilegedTool.installIfNeeded { _ in }
        }
    }
}

// MARK: - 侧边栏导航

enum AppSection: String, CaseIterable, Identifiable {
    case overview = "系统概览"
    case thermal  = "CPU 降温"
    case throttle = "降频监控"
    case power    = "电源管理"
    case clean    = "空间清理"
    case uninstall = "应用卸载"
    case tune     = "系统调优"
    case launch   = "启动项"
    case process  = "进程管理"
    case disk     = "磁盘分析"
    case gesture  = "鼠标手势"
    case settings = "应用设置"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .thermal:  return "thermometer"
        case .throttle: return "gauge.with.dots.needle.50percent"
        case .power:    return "battery.75"
        case .clean:    return "trash"
        case .uninstall: return "app.badge"
        case .tune:     return "slider.horizontal.3"
        case .launch:   return "power"
        case .process:  return "speedometer"
        case .disk:     return "internaldrive"
        case .gesture:  return "cursorarrow.click.2"
        case .settings: return "gearshape"
        }
    }
}

/// 侧边栏分组
enum AppSectionGroup: String, CaseIterable, Identifiable {
    case monitor  = "监控"
    case optimize = "优化"
    case tools    = "工具与设置"

    var id: String { rawValue }

    var sections: [AppSection] {
        switch self {
        case .monitor:  return [.overview, .thermal, .throttle, .power]
        case .optimize: return [.clean, .uninstall, .tune, .launch, .process, .disk]
        case .tools:    return [.gesture, .settings]
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var app: AppState
    @State private var selection: AppSection? = .overview

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(AppSectionGroup.allCases) { group in
                    Section(group.rawValue) {
                        ForEach(group.sections) { section in
                            Label(section.rawValue, systemImage: section.icon)
                                .tag(section)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("Laomac")
            .frame(minWidth: 170)
        } detail: {
            switch selection ?? .overview {
            case .overview: OverviewView()
            case .thermal:  ThermalView()
            case .throttle: ThrottleMonitorView()
            case .power:    PowerView()
            case .clean:    CleanView()
            case .uninstall: UninstallerView()
            case .tune:     TuneView()
            case .launch:   LaunchAgentsView()
            case .process:  ProcessView()
            case .disk:     DiskView()
            case .gesture:  GestureSettingsView()
            case .settings: AppSettingsView()
            }
        }
    }
}

// MARK: - 菜单栏下拉菜单

struct MenuBarView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.openWindow) private var openWindow
    @AppStorage(SettingsKey.enabled) private var gestureEnabled = true

    var body: some View {
        let snap = app.throttle.current

        Group {
            Text(snap.isThrottling ? "⚠️ CPU 正在降频 — \(snap.severity)" : "✅ CPU 运行正常")
            Divider()

            Text("频率限制 \(snap.speedLimit)%   调度 \(snap.schedulerLimit)%")
            Text(String(format: "kernel_task %.1f%%   风扇: %@", snap.kernelTaskCPU, app.throttle.fan.currentMode))
            Text("内存 \(app.info.memUsage)")
            Divider()

            Toggle("启用鼠标手势", isOn: Binding(
                get: { gestureEnabled },
                set: { newValue in
                    gestureEnabled = newValue
                    if newValue { app.gestures.tryStart(prompt: false) }
                    else { app.gestures.stop() }
                }
            ))
            Divider()

            Button("打开 Laomac") { openMainWindow() }
                .keyboardShortcut("o")
            Button("退出") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
    }

    private func openMainWindow() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - 通用卡片组件

struct Card<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundColor(.secondary)
                }
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
        )
    }
}

/// 信息键值对展示行
struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .top) {
            Text(label)
                .foregroundColor(.secondary)
                .frame(width: 110, alignment: .leading)
            Text(value)
                .textSelection(.enabled)
            Spacer()
        }
        .font(.callout)
    }
}
