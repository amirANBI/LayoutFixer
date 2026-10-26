// Draws the LayoutFixer icons ("Stacked keys"): an English A key tilted behind
// a Persian ش key that is coming to the front.
// Usage: swift icon/make_icon.swift <output dir>
// Writes icon_1024.png, AppIcon.iconset/ and the MenuBarIcon template PNGs.

import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")

func color(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

/// Renders `draw` onto a `size`-pixel square whose coordinates run 0...`canvas` (y up).
func render(size: Int, canvas: CGFloat, _ draw: () -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current!.imageInterpolation = .high
    NSGraphicsContext.current!.cgContext.scaleBy(x: CGFloat(size) / canvas, y: CGFloat(size) / canvas)
    draw()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func save(_ rep: NSBitmapImageRep, _ path: String) {
    let url = out.appendingPathComponent(path)
    try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

func text(_ s: String, font: NSFont, color: NSColor, center: NSPoint) {
    let str = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color])
    let b = str.boundingRect(with: .zero, options: [.usesLineFragmentOrigin, .usesDeviceMetrics])
    str.draw(at: NSPoint(x: center.x - b.midX, y: center.y - b.midY))
}

func persianFont(_ size: CGFloat) -> NSFont {
    for name in ["Vazirmatn-ExtraBold", "SFArabic-Heavy", "SFArabic-Bold", "GeezaPro-Bold"] {
        if let f = NSFont(name: name, size: size) { return f }
    }
    return .systemFont(ofSize: size, weight: .heavy)
}

/// Runs `draw` rotated by `degrees` (counter-clockwise) around `center`.
func rotated(_ degrees: CGFloat, around center: NSPoint, _ draw: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    let t = NSAffineTransform()
    t.translateX(by: center.x, yBy: center.y)
    t.rotate(byDegrees: degrees)
    t.translateX(by: -center.x, yBy: -center.y)
    t.concat()
    draw()
    NSGraphicsContext.restoreGraphicsState()
}

func rounded(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: NSRect(x: x, y: y, width: w, height: h), xRadius: r, yRadius: r)
}

// MARK: App icon (1024 canvas, macOS icon grid: 824 body with a 100 margin)

let teal = color(0x0F5E57)

func drawAppIcon() {
    let body = rounded(100, 100, 824, 824, 185)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = .black.withAlphaComponent(0.3)
    shadow.shadowBlurRadius = 24
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.set()
    teal.setFill()
    body.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: color(0x14B8A6), ending: teal)!.draw(in: body, angle: -90)

    // English key, tilted back.
    rotated(12, around: NSPoint(x: 420, y: 604)) {
        color(0x0B4A44, 0.55).setFill()
        rounded(230, 394, 380, 380, 76).fill()
        color(0x5EEAD4).setFill()
        rounded(230, 424, 380, 370, 76).fill()
        text("A", font: .systemFont(ofSize: 200, weight: .heavy), color: teal, center: NSPoint(x: 420, y: 614))
    }

    // Persian key, in front.
    rotated(-6, around: NSPoint(x: 610, y: 414)) {
        NSGraphicsContext.saveGraphicsState()
        let keyShadow = NSShadow()
        keyShadow.shadowColor = .black.withAlphaComponent(0.25)
        keyShadow.shadowBlurRadius = 30
        keyShadow.shadowOffset = NSSize(width: 0, height: -14)
        keyShadow.set()
        color(0x0B3B36).setFill()
        rounded(420, 194, 380, 380, 76).fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor.white.setFill()
        rounded(420, 224, 380, 380, 76).fill()
        text("ش", font: persianFont(220), color: teal, center: NSPoint(x: 610, y: 424))
    }
}

let master = render(size: 1024, canvas: 1024, drawAppIcon)
save(master, "icon_1024.png")
for points in [16, 32, 128, 256, 512] {
    save(render(size: points, canvas: 1024, drawAppIcon), "AppIcon.iconset/icon_\(points)x\(points).png")
    save(render(size: points * 2, canvas: 1024, drawAppIcon), "AppIcon.iconset/icon_\(points)x\(points)@2x.png")
}

// MARK: Menu bar template (36 canvas, black on clear; macOS tints it)

/// A filled key with A and ش cut out, in the style of the macOS input-source icon.
func drawMenuBarIcon() {
    NSColor.black.setFill()
    rounded(1, 1, 34, 34, 8).fill()
    NSGraphicsContext.current!.compositingOperation = .destinationOut
    text("A", font: .systemFont(ofSize: 16, weight: .heavy), color: .black, center: NSPoint(x: 11.5, y: 24.5))
    text("ش", font: persianFont(19), color: .black, center: NSPoint(x: 24, y: 11.5))
    NSGraphicsContext.current!.compositingOperation = .sourceOver
}

save(render(size: 18, canvas: 36, drawMenuBarIcon), "MenuBarIcon.png")
save(render(size: 36, canvas: 36, drawMenuBarIcon), "MenuBarIcon@2x.png")
print("wrote icons to \(out.path)")
