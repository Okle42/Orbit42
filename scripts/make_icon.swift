// Generates assets/Orbit42.icns: a wireframe sphere on a dark rounded square, a tilted orbit and one red satellite.
//   swift scripts/make_icon.swift
import AppKit

func draw(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px) / 1024, ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: s, y: s)
    let body = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
    NSGradient(colors: [NSColor(white: 0.13, alpha: 1), NSColor(white: 0.03, alpha: 1)])!.draw(in: body, angle: -90)
    body.addClip()
    let c = NSPoint(x: 512, y: 512), R: CGFloat = 230
    // sphere: outline + meridians + parallels
    NSColor(white: 1, alpha: 0.85).setStroke()
    let outline = NSBezierPath(ovalIn: NSRect(x: c.x - R, y: c.y - R, width: R * 2, height: R * 2)); outline.lineWidth = 10; outline.stroke()
    NSColor(white: 1, alpha: 0.35).setStroke()
    for k in [0.35, 0.7] {
        let w = R * CGFloat(k)
        let m = NSBezierPath(ovalIn: NSRect(x: c.x - w, y: c.y - R, width: w * 2, height: R * 2)); m.lineWidth = 6; m.stroke()
        let p = NSBezierPath(ovalIn: NSRect(x: c.x - R, y: c.y - w, width: R * 2, height: w * 2)); p.lineWidth = 6; p.stroke()
    }
    // tilted orbit
    ctx.saveGState()
    ctx.translateBy(x: c.x, y: c.y); ctx.rotate(by: -0.42)
    let orbit = NSBezierPath(ovalIn: NSRect(x: -360, y: -120, width: 720, height: 240))
    NSColor(white: 0.85, alpha: 0.9).setStroke(); orbit.lineWidth = 9; orbit.stroke()
    // red satellite with glow, on the orbit's right side
    let sat = NSPoint(x: 330, y: 50)
    let sh = NSShadow(); sh.shadowColor = NSColor(red: 1, green: 0.23, blue: 0.19, alpha: 1); sh.shadowBlurRadius = 60; sh.shadowOffset = .zero; sh.set()
    NSColor(red: 1, green: 0.23, blue: 0.19, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: sat.x - 42, y: sat.y - 42, width: 84, height: 84)).fill()
    ctx.restoreGState()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let set = root.appendingPathComponent("assets/Orbit42.iconset")
try? FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
                   ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! draw(px).write(to: set.appendingPathComponent("icon_\(name).png"))
}
try! draw(1024).write(to: root.appendingPathComponent("assets/Orbit42.png"))
let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set.path, "-o", root.appendingPathComponent("assets/Orbit42.icns").path]
try! p.run(); p.waitUntilExit()
try? FileManager.default.removeItem(at: set)
print("assets/Orbit42.icns")
