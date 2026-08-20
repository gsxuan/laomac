import SwiftUI

// MARK: - 配置项键名与默认值
enum SettingsKey {
    static let enabled    = "gestureEnabled"     // 手势总开关
    static let threshold  = "dragThreshold"     // 触发下拉距离(pt)
    static let ratio      = "horizontalRatio"   // 水平位移允许占垂直位移的比例
    static let showTrail  = "showTrail"         // 是否显示轨迹
    static let lineWidth  = "trailLineWidth"    // 轨迹粗细
    static let colorHex   = "trailColorHex"     // 轨迹颜色(十六进制)
    static let actionUp    = "actionUp"         // 上拉动作
    static let actionDown  = "actionDown"       // 下拉动作
    static let actionLeft  = "actionLeft"       // 左拉动作
    static let actionRight = "actionRight"      // 右拉动作
}

enum GestureDefaults {
    static func register() {
        UserDefaults.standard.register(defaults: [
            SettingsKey.enabled: true,
            SettingsKey.threshold: 80.0,
            SettingsKey.ratio: 0.8,
            SettingsKey.showTrail: true,
            SettingsKey.lineWidth: 5.0,
            SettingsKey.colorHex: "#4A90FF",
            SettingsKey.actionUp: GestureAction.missionControl.rawValue,
            SettingsKey.actionDown: GestureAction.minimize.rawValue,
            SettingsKey.actionLeft: GestureAction.switchWindow.rawValue,
            SettingsKey.actionRight: GestureAction.switchApp.rawValue,
        ])
    }
}

// MARK: - 手势方向
enum GestureDirection {
    case up, down, left, right

    var settingsKey: String {
        switch self {
        case .up:    return SettingsKey.actionUp
        case .down:  return SettingsKey.actionDown
        case .left:  return SettingsKey.actionLeft
        case .right: return SettingsKey.actionRight
        }
    }

    var description: String {
        switch self {
        case .up:    return "上拉"
        case .down:  return "下拉"
        case .left:  return "左拉"
        case .right: return "右拉"
        }
    }
}

// MARK: - 手势动作(可在设置中为每个方向单独绑定)
enum GestureAction: String, CaseIterable, Identifiable {
    case none
    case minimize
    case hideApp
    case closeWindow
    case newWindow
    case switchWindow
    case switchApp
    case missionControl
    case showDesktop
    case lockScreen
    case screenshot

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none:          return "无动作"
        case .minimize:      return "最小化窗口 (⌘M)"
        case .hideApp:       return "隐藏应用 (⌘H)"
        case .closeWindow:   return "关闭窗口 (⌘W)"
        case .newWindow:     return "新建窗口 (⌘N)"
        case .switchWindow:  return "切换同应用窗口 (⌘`)"
        case .switchApp:     return "切换应用 (⌘Tab)"
        case .missionControl: return "调度中心 (⌃↑)"
        case .showDesktop:   return "显示桌面 (F11)"
        case .lockScreen:    return "锁定屏幕 (⌃⌘Q)"
        case .screenshot:    return "全屏截图 (⇧⌘3)"
        }
    }

    /// 读取指定方向当前配置的动作
    static func configured(for direction: GestureDirection) -> GestureAction {
        let raw = UserDefaults.standard.string(forKey: direction.settingsKey) ?? ""
        return GestureAction(rawValue: raw) ?? .none
    }
}

// MARK: - 颜色十六进制互转(用于持久化轨迹颜色)
func colorFromHex(_ hex: String) -> Color {
    var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
    if s.hasPrefix("#") { s.removeFirst() }
    var value: UInt64 = 0
    Scanner(string: s).scanHexInt64(&value)
    return Color(
        red:   Double((value >> 16) & 0xFF) / 255,
        green: Double((value >> 8)  & 0xFF) / 255,
        blue:  Double(value & 0xFF) / 255
    )
}

func hexString(from color: Color) -> String {
    guard let c = NSColor(color).usingColorSpace(.sRGB) else { return "#4A90FF" }
    return String(format: "#%02X%02X%02X",
                  Int(c.redComponent * 255),
                  Int(c.greenComponent * 255),
                  Int(c.blueComponent * 255))
}

