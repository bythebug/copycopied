// Draws the CopyCopied app icon and writes assets/AppIcon.icns, assets/icon.png (1024) and assets/favicon.png (64).
//   swift scripts/make-icon.swift
// Design: dark rounded square; a soft grey orb (the original) behind a glowing green orb (the verified copy) with a check.
import AppKit

func draw(_ ctx: CGContext, size: CGFloat) {
    let s = size / 1024
    ctx.scaleBy(x: s, y: s)
    let space = CGColorSpaceCreateDeviceRGB()
    func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
        CGColor(red: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
    }

    // Rounded square on Apple's 1024 grid: 824pt body, 100pt margin.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: color(0x000000, 0.45))
    ctx.addPath(shape)
    ctx.setFillColor(color(0x111113))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let bg = CGGradient(colorsSpace: space, colors: [color(0x26262A), color(0x0A0A0B)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

    func orb(center: CGPoint, radius: CGFloat, colors: [CGColor]) {
        let g = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: [0, 0.45, 1])!
        ctx.drawRadialGradient(g, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
    }
    // The original: soft grey, up and left.
    orb(center: CGPoint(x: 400, y: 600), radius: 260,
        colors: [color(0xF2F2F7, 0.85), color(0xC7C7CC, 0.35), color(0xC7C7CC, 0)])
    // The verified copy: green, down and right, in front.
    orb(center: CGPoint(x: 600, y: 420), radius: 300,
        colors: [color(0x8FF5B4), color(0x22C55E, 0.75), color(0x16A34A, 0)])

    // Check mark on the green orb.
    ctx.setStrokeColor(color(0xFFFFFF, 0.95))
    ctx.setLineWidth(46)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.move(to: CGPoint(x: 512, y: 425))
    ctx.addLine(to: CGPoint(x: 575, y: 362))
    ctx.addLine(to: CGPoint(x: 700, y: 500))
    ctx.strokePath()
    ctx.restoreGState()
}

func png(_ size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    draw(ctx.cgContext, size: CGFloat(size))
    ctx.flushGraphics()
    return rep.representation(using: .png, properties: [:])!
}

let assets = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent("assets")
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try png(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try png(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try png(1024).write(to: assets.appendingPathComponent("icon.png"))
try png(64).write(to: assets.appendingPathComponent("favicon.png"))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", assets.appendingPathComponent("AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
precondition(iconutil.terminationStatus == 0, "iconutil failed")
print(assets.path)
