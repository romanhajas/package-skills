// make-icon.swift - draws AppIcon.icns: Claude Code (a terminal prompt) bridged to the
// Claude app (a chat bubble), with a spark (the skill) crossing over, on a graphite tile.
//
//   swift tools/make-icon.swift

import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let size: CGFloat = 1024

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

let orange = rgb(0xF2894E)
let cream = rgb(0xF5F1EA)
let graphite = rgb(0x1E2024)

func stroke(_ path: NSBezierPath, _ color: NSColor, width: CGFloat) {
    path.lineWidth = width
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    color.setStroke()
    path.stroke()
}

/// A four-point spark centred on `c`.
func spark(at c: NSPoint, radius r: CGFloat) -> NSBezierPath {
    let w = r * 0.24, p = NSBezierPath()
    p.move(to: NSPoint(x: c.x, y: c.y + r))
    p.curve(to: NSPoint(x: c.x + r, y: c.y), controlPoint1: NSPoint(x: c.x + w, y: c.y + w), controlPoint2: NSPoint(x: c.x + w, y: c.y + w))
    p.curve(to: NSPoint(x: c.x, y: c.y - r), controlPoint1: NSPoint(x: c.x + w, y: c.y - w), controlPoint2: NSPoint(x: c.x + w, y: c.y - w))
    p.curve(to: NSPoint(x: c.x - r, y: c.y), controlPoint1: NSPoint(x: c.x - w, y: c.y - w), controlPoint2: NSPoint(x: c.x - w, y: c.y - w))
    p.curve(to: NSPoint(x: c.x, y: c.y + r), controlPoint1: NSPoint(x: c.x - w, y: c.y + w), controlPoint2: NSPoint(x: c.x - w, y: c.y + w))
    return p
}

func drawIcon() -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // The tile, on the macOS icon grid, with a soft shadow.
    let tile = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.shadowBlurRadius = 28
    shadow.set()
    graphite.setFill()
    tile.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: rgb(0x34373D), ending: rgb(0x16171A))!.draw(in: tile, angle: -90)

    // Left: Claude Code, a terminal window with a prompt.
    let code = NSRect(x: 190, y: 270, width: 250, height: 250)
    stroke(NSBezierPath(roundedRect: code, xRadius: 56, yRadius: 56), cream, width: 30)
    let prompt = NSAttributedString(string: ">_", attributes: [
        .font: NSFont.monospacedSystemFont(ofSize: 104, weight: .heavy), .foregroundColor: orange])
    let promptSize = prompt.size()
    prompt.draw(at: NSPoint(x: code.midX - promptSize.width / 2, y: code.midY - promptSize.height / 2 + 4))

    // Right: the Claude app, a chat bubble with a tail.
    let chat = NSRect(x: 584, y: 270, width: 250, height: 250)
    cream.setFill()
    NSBezierPath(roundedRect: chat, xRadius: 56, yRadius: 56).fill()
    let tail = NSBezierPath()
    tail.move(to: NSPoint(x: chat.maxX - 90, y: chat.minY + 4))
    tail.line(to: NSPoint(x: chat.maxX - 30, y: chat.minY - 50))
    tail.line(to: NSPoint(x: chat.maxX - 40, y: chat.minY + 4))
    tail.close()
    tail.fill()
    graphite.setFill()
    for i in 0..<3 {
        NSBezierPath(ovalIn: NSRect(x: chat.midX - 70 + CGFloat(i) * 55, y: chat.midY - 20, width: 40, height: 40)).fill()
    }

    // The bridge between them, and the skill crossing it.
    let start = NSPoint(x: code.midX, y: code.maxY + 40), end = NSPoint(x: chat.midX, y: chat.maxY + 40)
    let bridge = NSBezierPath()
    bridge.move(to: start)
    bridge.curve(to: end, controlPoint1: NSPoint(x: start.x + 20, y: start.y + 200), controlPoint2: NSPoint(x: end.x - 20, y: end.y + 200))
    NSGraphicsContext.saveGraphicsState()
    let glow = NSShadow()
    glow.shadowColor = orange.withAlphaComponent(0.5)
    glow.shadowBlurRadius = 30
    glow.set()
    stroke(bridge, orange, width: 40)
    NSGraphicsContext.restoreGraphicsState()
    cream.setFill()
    spark(at: NSPoint(x: 512, y: 760), radius: 56).fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let png = drawIcon().representation(using: .png, properties: [:])!
let work = FileManager.default.temporaryDirectory.appendingPathComponent("skill-bridge-icon-\(UUID().uuidString)")
let iconset = work.appendingPathComponent("AppIcon.iconset")
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
let master = work.appendingPathComponent("icon-1024.png")
try! png.write(to: master)

func run(_ tool: String, _ args: [String]) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = args
    p.standardOutput = FileHandle.nullDevice
    try! p.run()
    p.waitUntilExit()
}
for s in [16, 32, 128, 256, 512] {
    run("/usr/bin/sips", ["-z", "\(s)", "\(s)", master.path, "--out", iconset.appendingPathComponent("icon_\(s)x\(s).png").path])
    run("/usr/bin/sips", ["-z", "\(s * 2)", "\(s * 2)", master.path, "--out", iconset.appendingPathComponent("icon_\(s)x\(s)@2x.png").path])
}
run("/usr/bin/iconutil", ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("AppIcon.icns").path])
try? FileManager.default.removeItem(at: root.appendingPathComponent("docs/icon.png"))
try? FileManager.default.copyItem(at: master, to: root.appendingPathComponent("docs/icon.png"))
try? FileManager.default.removeItem(at: work)
print("wrote AppIcon.icns")
