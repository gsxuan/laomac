import AppKit

/// 全屏透明覆盖层:右键拖动时实时绘制手势轨迹(可视化反馈)
final class TrailOverlay {
    static let shared = TrailOverlay()

    private var window: NSWindow?
    private var trailView: TrailView?
    private var union = CGRect.null          // 所有屏幕的联合区域(全局坐标)
    private var fadeTimer: Timer?
    private var visible = false

    /// 手势开始,显示覆盖层并记录起点
    func begin(at point: CGPoint) {
        guard UserDefaults.standard.bool(forKey: SettingsKey.showTrail) else { return }
        fadeTimer?.invalidate()
        fadeTimer = nil
        ensureWindow()
        trailView?.setTrail(from: toLocal(point), to: toLocal(point), recognized: false)
        window?.alphaValue = 1
        window?.orderFrontRegardless()
        visible = true
    }

    /// 拖动过程中更新轨迹终点
    func update(to point: CGPoint) {
        guard visible else { return }
        trailView?.updateEnd(toLocal(point))
    }

    /// 手势结束:识别成功时轨迹变绿并短暂停留,随后淡出
    func end(recognized: Bool) {
        guard visible else { return }
        trailView?.setRecognized(recognized)
        fadeTimer = Timer.scheduledTimer(withTimeInterval: recognized ? 0.35 : 0.12, repeats: false) { [weak self] _ in
            self?.fadeOut()
        }
    }

    private func fadeOut() {
        guard let window, visible else { return }
        visible = false
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            window.animator().alphaValue = 0
        }, completionHandler: {
            window.orderOut(nil)
        })
    }

    /// 全局鼠标坐标 -> 覆盖层视图坐标(视图为翻转坐标系,原点左上)
    private func toLocal(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x - union.minX, y: point.y - union.minY)
    }

    private func ensureWindow() {
        union = NSScreen.screens.map(\.frame).reduce(CGRect.null) { $0.union($1) }
        if window == nil {
            let view = TrailView(frame: NSRect(origin: .zero, size: union.size))
            let w = NSWindow(contentRect: NSRect(origin: .zero, size: union.size),
                             styleMask: .borderless,
                             backing: .buffered,
                             defer: false)
            w.contentView = view
            w.isOpaque = false
            w.backgroundColor = .clear
            w.ignoresMouseEvents = true
            w.level = .screenSaver
            w.hasShadow = false
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window = w
            trailView = view
        }
        window?.setFrame(NSRect(origin: union.origin, size: union.size), display: true)
        trailView?.frame = NSRect(origin: .zero, size: union.size)
    }
}

/// 实际绘制轨迹的视图
final class TrailView: NSView {
    private var from: CGPoint?
    private var to: CGPoint?
    private var recognized = false

    override var isFlipped: Bool { true }     // 与屏幕全局坐标方向一致(y 向下)

    func setTrail(from startPoint: CGPoint, to endPoint: CGPoint, recognized flag: Bool) {
        from = startPoint
        to = endPoint
        recognized = flag
        needsDisplay = true
    }

    func updateEnd(_ point: CGPoint) {
        to = point
        needsDisplay = true
    }

    func setRecognized(_ flag: Bool) {
        recognized = flag
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let from, let to else { return }
        let hex = UserDefaults.standard.string(forKey: SettingsKey.colorHex) ?? "#4A90FF"
        let strokeColor = recognized ? NSColor.systemGreen : NSColor(colorFromHex(hex))
        let width = CGFloat(UserDefaults.standard.double(forKey: SettingsKey.lineWidth))

        // 主轨迹线
        let path = NSBezierPath()
        path.lineWidth = width
        path.lineCapStyle = .round
        path.move(to: from)
        path.line(to: to)
        strokeColor.withAlphaComponent(0.85).setStroke()
        path.stroke()

        // 终点箭头:指示手势方向
        let lineLength = hypot(to.x - from.x, to.y - from.y)
        if lineLength > 24 {
            let angle = atan2(to.y - from.y, to.x - from.x)
            let arrowLength = 8 + width * 1.5
            let spread = CGFloat.pi / 6                              // 箭头张角 30°
            let arrow = NSBezierPath()
            arrow.lineWidth = width
            arrow.lineCapStyle = .round
            for side in [spread, -spread] {
                let tail = CGPoint(x: to.x - arrowLength * cos(angle + side),
                                   y: to.y - arrowLength * sin(angle + side))
                arrow.move(to: to)
                arrow.line(to: tail)
            }
            strokeColor.withAlphaComponent(0.85).setStroke()
            arrow.stroke()
        }

        // 起点圆点标记
        let dotRadius = width
        let dot = NSBezierPath(ovalIn: CGRect(x: from.x - dotRadius, y: from.y - dotRadius,
                                              width: dotRadius * 2, height: dotRadius * 2))
        strokeColor.setFill()
        dot.fill()
    }
}
