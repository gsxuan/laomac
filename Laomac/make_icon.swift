// make_icon.swift — 程序化绘制 Laomac 图标并生成 AppIcon.icns
// 用法: swift make_icon.swift [输出目录]
import AppKit

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

func drawIcon(_ px: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: px, height: px))
    img.lockFocus()
    let k = px / 1024   // 以 1024 设计稿等比缩放

    func r(_ v: CGFloat) -> CGFloat { v * k }

    func rr(_ rect: NSRect, _ radius: CGFloat) -> NSBezierPath {
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    }

    // ---- 圆角矩形底板 (squircle 近似) ----
    let inset = r(44)
    let rect = NSRect(x: inset, y: inset, width: px - inset * 2, height: px - inset * 2)
    let squircle = rr(rect, r(224))

    let bg = NSGradient(colors: [
        NSColor(calibratedRed: 0.07, green: 0.32, blue: 0.52, alpha: 1),
        NSColor(calibratedRed: 0.04, green: 0.10, blue: 0.22, alpha: 1),
    ])
    bg?.draw(in: squircle, angle: -90)

    // 顶部柔光
    let gloss = NSGradient(colors: [
        NSColor.white.withAlphaComponent(0.14),
        NSColor.white.withAlphaComponent(0),
    ])
    let glossRect = NSRect(x: inset, y: rect.midY, width: rect.width, height: rect.height / 2)
    gloss?.draw(in: rr(glossRect, r(224)), angle: 90)

    // ---- 复古老 Mac 机身 ----
    let bodyW = r(520), bodyH = r(600)
    let bodyX = (px - bodyW) / 2
    let bodyY = (px - bodyH) / 2 - r(16)
    let body = rr(NSRect(x: bodyX, y: bodyY, width: bodyW, height: bodyH), r(56))

    let bodyGrad = NSGradient(colors: [
        NSColor(calibratedRed: 0.96, green: 0.96, blue: 0.94, alpha: 1),
        NSColor(calibratedRed: 0.78, green: 0.80, blue: 0.83, alpha: 1),
    ])
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = r(36)
    shadow.shadowOffset = NSSize(width: 0, height: -r(14))
    shadow.set()
    bodyGrad?.draw(in: body, angle: -90)
    NSShadow().set()   // 重置阴影状态

    // ---- 屏幕: 深色底 + 仪表盘 ----
    let scrPad = r(52)
    let scrH = r(360)
    let scr = NSRect(x: bodyX + scrPad, y: bodyY + bodyH - scrPad - scrH,
                     width: bodyW - scrPad * 2, height: scrH)
    let screen = rr(scr, r(28))
    let scrGrad = NSGradient(colors: [
        NSColor(calibratedRed: 0.05, green: 0.55, blue: 0.45, alpha: 1),
        NSColor(calibratedRed: 0.02, green: 0.25, blue: 0.30, alpha: 1),
    ])
    scrGrad?.draw(in: screen, angle: -90)

    // 仪表弧线刻度
    let cx = scr.midX, cy = scr.midY - r(24)
    let radius = r(128)
    NSColor.white.withAlphaComponent(0.85).setStroke()
    for deg in stride(from: 200.0, through: -20.0, by: -27.5) {
        let a = deg * .pi / 180
        let p1 = NSPoint(x: cx + cos(a) * radius, y: cy + sin(a) * radius)
        let p2 = NSPoint(x: cx + cos(a) * (radius - r(18)), y: cy + sin(a) * (radius - r(18)))
        let tick = NSBezierPath()
        tick.lineWidth = r(6)
        tick.lineCapStyle = .round
        tick.move(to: p1)
        tick.line(to: p2)
        tick.stroke()
    }

    // 指针 (指向高速区)
    let needleAngle = -8.0 * .pi / 180
    let tip = NSPoint(x: cx + cos(needleAngle) * (radius - r(24)),
                      y: cy + sin(needleAngle) * (radius - r(24)))
    let needle = NSBezierPath()
    needle.lineWidth = r(14)
    needle.lineCapStyle = .round
    needle.move(to: NSPoint(x: cx, y: cy))
    needle.line(to: tip)
    NSColor(calibratedRed: 0.30, green: 0.95, blue: 0.55, alpha: 1).setStroke()
    needle.stroke()

    // 指针轴心
    let hub = NSBezierPath(ovalIn: NSRect(x: cx - r(20), y: cy - r(20), width: r(40), height: r(40)))
    NSColor.white.setFill()
    hub.fill()

    // ---- 机身下部: 软驱槽 + 指示灯 ----
    let slotY = bodyY + r(120)
    let slot = rr(NSRect(x: bodyX + scrPad, y: slotY,
                         width: bodyW - scrPad * 2, height: r(20)), r(10))
    NSColor(calibratedRed: 0.55, green: 0.57, blue: 0.60, alpha: 1).setFill()
    slot.fill()

    let led = NSBezierPath(ovalIn: NSRect(x: bodyX + bodyW - scrPad - r(28), y: slotY - r(46),
                                          width: r(26), height: r(26)))
    NSColor(calibratedRed: 0.30, green: 0.95, blue: 0.55, alpha: 1).setFill()
    led.fill()

    img.unlockFocus()
    return img
}

// ---- 生成 iconset ----
let iconset = URL(fileURLWithPath: outDir).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let sizes: [(Int, String)] = [
    (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png"),
]

for (px, name) in sizes {
    let img = drawIcon(CGFloat(px))
    guard let tiff = img.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { continue }
    try png.write(to: iconset.appendingPathComponent(name))
}

// 保留 1024 设计原稿
let master = drawIcon(1024)
if let tiff = master.tiffRepresentation,
   let rep = NSBitmapImageRep(data: tiff),
   let png = rep.representation(using: .png, properties: [:]) {
    try png.write(to: URL(fileURLWithPath: outDir).appendingPathComponent("AppIcon.png"))
}

print("iconset 已生成: \(iconset.path)")
