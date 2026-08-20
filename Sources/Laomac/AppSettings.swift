import AppKit
import ServiceManagement

// MARK: - 应用级设置 (菜单栏 / Dock 图标显示)

enum AppSettingsKey {
    static let showMenuBar = "showMenuBarIcon"   // 是否显示菜单栏图标
    static let showDock    = "showDockIcon"      // 是否显示 Dock 图标
}

enum AppSettings {
    /// 根据「是否显示 Dock 图标」切换激活策略:
    /// .regular = 普通应用 (Dock 有图标), .accessory = 后台应用 (Dock 无图标)
    static func applyActivationPolicy() {
        let showDock = UserDefaults.standard.object(forKey: AppSettingsKey.showDock) as? Bool ?? true
        NSApp.setActivationPolicy(showDock ? .regular : .accessory)
    }

    static func setShowDock(_ show: Bool) {
        NSApp.setActivationPolicy(show ? .regular : .accessory)
        if show { NSApp.activate(ignoringOtherApps: true) }
    }
}

// MARK: - 开机自启

enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }
    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("设置开机自启失败: \(error)")
        }
    }
}
