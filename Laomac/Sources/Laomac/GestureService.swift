import AppKit
import ApplicationServices

// MARK: - 鼠标手势服务 (原 MouseGesture 的引擎管理)

final class GestureService: ObservableObject {
    let engine = GestureEngine()
    @Published var running = false
    @Published var trusted = AXIsProcessTrusted()

    init() {
        engine.onDragStart = { TrailOverlay.shared.begin(at: $0) }
        engine.onDragMove  = { TrailOverlay.shared.update(to: $0) }
        engine.onDragEnd   = { TrailOverlay.shared.end(recognized: $0) }
    }

    /// 启动时自动拉起: 仅在已授权且开关打开时静默启动
    func autoStart() {
        guard UserDefaults.standard.bool(forKey: SettingsKey.enabled) else { return }
        tryStart(prompt: false)
    }

    /// 尝试启动手势引擎
    /// - Parameter prompt: 无权限时是否弹出系统授权引导
    @discardableResult
    func tryStart(prompt: Bool) -> Bool {
        trusted = AXIsProcessTrusted()
        if !trusted {
            if prompt {
                let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                AXIsProcessTrustedWithOptions(options)
            }
            running = false
            return false
        }
        running = engine.start()
        return running
    }

    func stop() {
        engine.stop()
        running = false
    }

    /// 重新检查辅助功能权限状态
    func refreshTrust() {
        trusted = AXIsProcessTrusted()
        if trusted, !running, UserDefaults.standard.bool(forKey: SettingsKey.enabled) {
            running = engine.start()
        }
    }
}
