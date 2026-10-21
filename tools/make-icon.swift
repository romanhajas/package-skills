// Draws the Package Skills app icon (1024x1024 PNG): a parcel with an upload badge.
import AppKit

let out = CommandLine.arguments[1]
let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))

func rgb(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: 1)
}

func symbol(_ name: String, points: CGFloat, weight: NSFont.Weight = .semibold, colors: [NSColor]) -> NSImage {
    let config = NSImage.SymbolConfiguration(pointSize: points, weight: weight)
        .applying(NSImage.SymbolConfiguration(paletteColors: colors))
    return NSImage(systemSymbolName: name, accessibilityDescription: nil)!.withSymbolConfiguration(config)!
}

func draw(_ img: NSImage, centeredAt c: NSPoint) {
    img.draw(in: NSRect(x: c.x - img.size.width / 2, y: c.y - img.size.height / 2,
                        width: img.size.width, height: img.size.height))
}

let orange = rgb(0xD97757)
let deep = rgb(0xB8532F)

image.lockFocus()

// macOS icon grid: 824pt tile inside the 1024 canvas, with a soft drop shadow.
let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
shadow.shadowOffset = NSSize(width: 0, height: -12)
shadow.shadowBlurRadius = 28
shadow.set()
orange.setFill()
shape.fill()
NSGraphicsContext.restoreGraphicsState()
NSGradient(starting: rgb(0xE8906F), ending: deep)!.draw(in: shape, angle: -90)

// The parcel, then the upload badge over its lower right corner.
draw(symbol("shippingbox.fill", points: 400, colors: [.white]), centeredAt: NSPoint(x: 490, y: 540))
let badgeCenter = NSPoint(x: 690, y: 330)
func disc(_ radius: CGFloat, _ color: NSColor) {
    color.setFill()
    NSBezierPath(ovalIn: NSRect(x: badgeCenter.x - radius, y: badgeCenter.y - radius,
                                width: radius * 2, height: radius * 2)).fill()
}
disc(145, .white)
disc(120, deep)
draw(symbol("arrow.up", points: 150, weight: .black, colors: [.white]), centeredAt: badgeCenter)

image.unlockFocus()

let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
