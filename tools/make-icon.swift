// Generates Resources/AppIcon.icns (waveform logo). Usage: swift tools/make-icon.swift
import AppKit

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    let inset = s * 0.055
    let rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let bg = NSBezierPath(roundedRect: rect, xRadius: s * 0.225, yRadius: s * 0.225)
    NSGradient(starting: NSColor(red: 0.13, green: 0.17, blue: 0.42, alpha: 1), ending: NSColor(red: 0.47, green: 0.22, blue: 0.78, alpha: 1))!
        .draw(in: bg, angle: -60)
    // waveform bars
    let heights: [CGFloat] = [0.18, 0.34, 0.56, 0.40, 0.68, 0.48, 0.30, 0.52, 0.26, 0.14]
    let barW = s * 0.05, gap = s * 0.027
    let total = CGFloat(heights.count) * barW + CGFloat(heights.count - 1) * gap
    var x = (s - total) / 2
    NSColor.white.setFill()
    for h in heights {
        let bh = s * h
        NSBezierPath(roundedRect: NSRect(x: x, y: (s - bh) / 2, width: barW, height: bh), xRadius: barW / 2, yRadius: barW / 2).fill()
        x += barW + gap
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let set = "Resources/AppIcon.iconset"
try? FileManager.default.removeItem(atPath: set)
try! FileManager.default.createDirectory(atPath: set, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: URL(fileURLWithPath: "\(set)/icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: URL(fileURLWithPath: "\(set)/icon_\(base)x\(base)@2x.png"))
}
