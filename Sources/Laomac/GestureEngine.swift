import AppKit
import CoreGraphics

/// 手势引擎:通过 CGEventTap 监听右键按下/拖动/抬起,识别"向下画竖线"手势
final class GestureEngine {
    /// 右键按下(全局坐标)
    var onDragStart: ((CGPoint) -> Void)?
    /// 右键拖动中(全局坐标)
    var onDragMove: ((CGPoint) -> Void)?
    /// 右键抬起,参数表示手势是否被识别
    var onDragEnd: ((Bool) -> Void)?

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var dragging = false
    private var firedDirection: GestureDirection?
    private var startPoint = CGPoint.zero

    /// 启动事件监听,返回是否成功(失败通常是权限问题)
    func start() -> Bool {
        guard tap == nil else { return true }

        let mask: CGEventMask =
            (1 << CGEventType.rightMouseDown.rawValue) |
            (1 << CGEventType.rightMouseDragged.rawValue) |
            (1 << CGEventType.rightMouseUp.rawValue)

        let ref = Unmanaged.passUnretained(self).toOpaque()
        guard let t = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let engine = Unmanaged<GestureEngine>.fromOpaque(refcon).takeUnretainedValue()
                return engine.handle(type: type, event: event)
            },
            userInfo: ref
        ) else { return false }

        tap = t
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        NSLog("手势引擎已启动")
        return true
    }

    /// 停止事件监听
    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        tap = nil
        runLoopSource = nil
        dragging = false
        firedDirection = nil
        NSLog("手势引擎已停止")
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .rightMouseDown:
            if UserDefaults.standard.bool(forKey: SettingsKey.enabled) {
                dragging = true
                firedDirection = nil
                startPoint = event.location
                onDragStart?(startPoint)
            }

        case .rightMouseDragged:
            if dragging {
                let point = event.location
                if firedDirection == nil,
                   let direction = Self.detectDirection(from: startPoint, to: point),
                   GestureAction.configured(for: direction) != .none {
                    firedDirection = direction
                    NSLog("手势识别:右键\(direction.description) -> \(GestureAction.configured(for: direction).displayName)")
                }
                onDragMove?(point)
                if firedDirection != nil {
                    return nil                                        // 吞掉后续拖动事件
                }
            }

        case .rightMouseUp:
            if dragging {
                dragging = false
                let direction = firedDirection
                firedDirection = nil
                onDragEnd?(direction != nil)
                if let direction {
                    GestureAction.configured(for: direction).perform()
                    return nil                                        // 吞掉抬起事件,防止右键菜单弹出
                }
            }

        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }

        default:
            break
        }
        return Unmanaged.passUnretained(event)
    }

    /// 判断手势方向:主导轴位移达到阈值,且副轴偏移在宽容度内
    private static func detectDirection(from start: CGPoint, to point: CGPoint) -> GestureDirection? {
        let dx = point.x - start.x
        let dy = point.y - start.y                                   // 屏幕坐标 y 向下为正
        let ax = abs(dx)
        let ay = abs(dy)
        let threshold = CGFloat(UserDefaults.standard.double(forKey: SettingsKey.threshold))
        let ratio = CGFloat(UserDefaults.standard.double(forKey: SettingsKey.ratio))

        if ay >= ax {                                                // 垂直方向主导
            guard ay >= threshold, ax <= ay * ratio else { return nil }
            return dy > 0 ? .down : .up
        } else {                                                     // 水平方向主导
            guard ax >= threshold, ay <= ax * ratio else { return nil }
            return dx > 0 ? .right : .left
        }
    }
}

// MARK: - 动作执行(通过模拟系统快捷键实现)
extension GestureAction {
    func perform() {
        switch self {
        case .none:           break
        case .minimize:       postKey(0x2E, flags: .maskCommand)                              // ⌘M
        case .hideApp:        postKey(0x04, flags: .maskCommand)                              // ⌘H
        case .closeWindow:    postKey(0x0D, flags: .maskCommand)                              // ⌘W
        case .newWindow:      postKey(0x2D, flags: .maskCommand)                              // ⌘N
        case .switchWindow:   postKey(0x32, flags: .maskCommand)                              // ⌘`
        case .switchApp:      postKey(0x30, flags: .maskCommand)                              // ⌘Tab
        case .missionControl: postKey(0x7E, flags: .maskControl)                              // ⌃↑
        case .showDesktop:    postKey(0x67, flags: .maskSecondaryFn)                          // F11
        case .lockScreen:     postKey(0x0C, flags: [.maskCommand, .maskControl])              // ⌃⌘Q
        case .screenshot:     postKey(0x14, flags: [.maskCommand, .maskShift])                // ⇧⌘3
        }
    }

    private func postKey(_ keyCode: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        let keyUp   = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        keyDown?.flags = flags
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }
}
