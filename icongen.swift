// Generates the kagami app icon: a round mirror with 鏡 in it.
// Run: swift icongen.swift   → writes icon_1024.png next to it (build.sh turns it into .icns)
import AppKit

let px = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let S = CGFloat(px)
let center = NSPoint(x: S / 2, y: S / 2)

// background squircle (Apple icon grid: ~90px margin)
let squircle = NSBezierPath(roundedRect: NSRect(x: 90, y: 90, width: S - 180, height: S - 180),
                            xRadius: 190, yRadius: 190)
NSGradient(colors: [NSColor(red: 0.10, green: 0.11, blue: 0.15, alpha: 1),
                    NSColor(red: 0.05, green: 0.06, blue: 0.09, alpha: 1)])!
    .draw(in: squircle, angle: -90)

// metallic ring
let outerR: CGFloat = 340
let ringPath = NSBezierPath(ovalIn: NSRect(x: center.x - outerR, y: center.y - outerR,
                                           width: outerR * 2, height: outerR * 2))
NSGradient(colorsAndLocations:
    (NSColor(white: 0.92, alpha: 1), 0.0),
    (NSColor(white: 0.55, alpha: 1), 0.35),
    (NSColor(white: 0.30, alpha: 1), 0.65),
    (NSColor(white: 0.78, alpha: 1), 1.0))!
    .draw(in: ringPath, angle: -60)

// mirror glass
let glassR: CGFloat = 296
let glassPath = NSBezierPath(ovalIn: NSRect(x: center.x - glassR, y: center.y - glassR,
                                            width: glassR * 2, height: glassR * 2))
NSGradient(colors: [NSColor(red: 0.34, green: 0.44, blue: 0.55, alpha: 1),
                    NSColor(red: 0.10, green: 0.14, blue: 0.20, alpha: 1)])!
    .draw(in: glassPath, relativeCenterPosition: NSPoint(x: -0.35, y: 0.4))

// specular streak across the glass
NSGraphicsContext.current!.saveGraphicsState()
glassPath.addClip()
let streak = NSBezierPath()
streak.move(to: NSPoint(x: center.x - 320, y: center.y + 300))
streak.line(to: NSPoint(x: center.x - 120, y: center.y + 340))
streak.line(to: NSPoint(x: center.x + 340, y: center.y - 220))
streak.line(to: NSPoint(x: center.x + 180, y: center.y - 300))
streak.close()
NSColor(white: 1.0, alpha: 0.10).setFill()
streak.fill()
NSGraphicsContext.current!.restoreGraphicsState()

// 鏡
let font = NSFont(name: "HiraMinProN-W6", size: 400) ?? NSFont.systemFont(ofSize: 400, weight: .bold)
let shadow = NSShadow()
shadow.shadowColor = NSColor(white: 0, alpha: 0.55)
shadow.shadowOffset = NSSize(width: 0, height: -8)
shadow.shadowBlurRadius = 22
let attrs: [NSAttributedString.Key: Any] = [
    .font: font,
    .foregroundColor: NSColor(white: 0.96, alpha: 1),
    .shadow: shadow,
]
let glyph = NSAttributedString(string: "鏡", attributes: attrs)
let gsize = glyph.size()
glyph.draw(at: NSPoint(x: center.x - gsize.width / 2, y: center.y - gsize.height / 2))

NSGraphicsContext.restoreGraphicsState()
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: "icon_1024.png"))
print("wrote icon_1024.png")
