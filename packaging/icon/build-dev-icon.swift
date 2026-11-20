#!/usr/bin/env swift
// Regenerate packaging/icon/Tarmac-dev-1024.png, the Dock icon of a `make run`
// dev app (issue #438): Tarmac.svg with its slashes in the dev colour, plus a
// DEV pill, in the same padded box as Tarmac-1024.png so the two sit at one size
// in the Dock. Run: swift packaging/icon/build-dev-icon.swift
//
// The pill is drawn here, not in the SVG: AppKit's SVG renderer is not relied
// on for <text>.
import AppKit

let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let dev: (r: Int, g: Int, b: Int) = (0xFF, 0x8A, 0x3D)
let ink = NSColor(srgbRed: 0x10 / 255, green: 0x14 / 255, blue: 0x1A / 255, alpha: 1)

let source = try String(contentsOf: dir.appendingPathComponent("Tarmac.svg"), encoding: .utf8)
precondition(source.contains("#4DD4DB"), "Tarmac.svg no longer draws its slashes in #4DD4DB")
let svg = source.replacingOccurrences(of: "#4DD4DB", with: String(format: "#%02X%02X%02X", dev.r, dev.g, dev.b))
guard let art = NSImage(data: Data(svg.utf8)) else { fatalError("Tarmac.svg did not load") }

// Tarmac-1024.png's opaque box, measured: 836 wide at (94, 89) from the top left.
let canvas: CGFloat = 1024, side: CGFloat = 836, left: CGFloat = 94, top: CGFloat = 89
let scale = side / canvas

/// A rect in the SVG's 1024 space (top-left origin) as a rect on the canvas.
func place(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
    NSRect(x: left + x * scale, y: canvas - top - (y + h) * scale, width: w * scale, height: h * scale)
}

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(canvas), pixelsHigh: Int(canvas), bitsPerSample: 8,
    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.4)
shadow.shadowOffset = NSSize(width: 0, height: -20)
shadow.shadowBlurRadius = 34
shadow.set()
art.draw(in: place(0, 0, canvas, canvas))
NSGraphicsContext.restoreGraphicsState()

let pillRect = place(548, 770, 404, 176)
let pill = NSBezierPath(roundedRect: pillRect, xRadius: pillRect.height / 2, yRadius: pillRect.height / 2)
NSColor(srgbRed: CGFloat(dev.r) / 255, green: CGFloat(dev.g) / 255, blue: CGFloat(dev.b) / 255, alpha: 1).setFill()
pill.fill()
ink.setStroke()
pill.lineWidth = 18 * scale
pill.stroke()

let label = NSAttributedString(string: "DEV", attributes: [
    .font: NSFont.monospacedSystemFont(ofSize: 120 * scale, weight: .heavy),
    .foregroundColor: ink,
    .kern: 8 * scale,
])
let size = label.size()
label.draw(at: NSPoint(x: pillRect.midX - size.width / 2 + 4 * scale, y: pillRect.midY - size.height / 2))

try rep.representation(using: .png, properties: [:])!.write(to: dir.appendingPathComponent("Tarmac-dev-1024.png"))
print("✓ Wrote packaging/icon/Tarmac-dev-1024.png")
