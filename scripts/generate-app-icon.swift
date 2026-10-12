#!/usr/bin/env swift
import AppKit

// The same one-period wave as TildeMark, on tilde's pure-black surface.
// Run from the repository root. No installed bundle or preferences are touched.
let destination = URL(fileURLWithPath: "Tilde/Assets.xcassets/AppIcon.appiconset", isDirectory: true)
let slots = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]
var images: [[String: String]] = []

for (points, scale) in slots {
    let pixels = points * scale
    let image = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: image)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    let cg = context.cgContext
    cg.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    cg.setAllowsAntialiasing(true)
    cg.setShouldAntialias(true)

    cg.addPath(CGPath(roundedRect: CGRect(x: 80, y: 80, width: 864, height: 864), cornerWidth: 192, cornerHeight: 192, transform: nil))
    cg.setFillColor(NSColor.black.cgColor)
    cg.fillPath()

    let wave = CGMutablePath()
    for i in 0...192 {
        let fraction = CGFloat(i) / 192
        let point = CGPoint(x: 222 + fraction * 580, y: 512 + 110 * sin(2 * .pi * fraction))
        if i == 0 { wave.move(to: point) } else { wave.addLine(to: point) }
    }
    cg.addPath(wave)
    cg.setStrokeColor(NSColor.white.cgColor)
    cg.setLineWidth(84)
    cg.setLineCap(.round)
    cg.setLineJoin(.round)
    cg.strokePath()
    NSGraphicsContext.restoreGraphicsState()

    let filename = "icon_\(points)x\(points)@\(scale)x.png"
    try image.representation(using: .png, properties: [:])!.write(to: destination.appending(path: filename))
    images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": filename])
}
let manifest: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
try (data + Data("\n".utf8)).write(to: destination.appending(path: "Contents.json"))
