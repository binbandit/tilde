#!/usr/bin/env swift
import Foundation

// tilde's icon: the same one-period wave as TildeMark, white on its pure-black surface, as an
// Icon Composer icon. macOS masks it to its own shape; artwork in the older PNG format gets
// boxed onto a grey plate instead. Run from the repository root (`just icon`).
let icon = URL(fileURLWithPath: "Tilde/AppIcon.icon", isDirectory: true)
let assets = icon.appending(path: "Assets")
try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)

// Fine enough to read as a curve at any size. SVG's y runs down, so the wave rises first, like the ~.
let points = (0...192).map { i in
    let fraction = Double(i) / 192
    return String(format: "%.2f %.2f", 168 + fraction * 688, 512 - 130 * sin(2 * .pi * fraction))
}
let svg = """
    <svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
      <path d="M\(points.joined(separator: " L"))" fill="none" stroke="#FFFFFF" stroke-width="100" stroke-linecap="round" stroke-linejoin="round"/>
    </svg>

    """
try svg.write(to: assets.appending(path: "wave.svg"), atomically: true, encoding: .utf8)

let manifest: [String: Any] = [
    "fill": ["solid": "srgb:0.00000,0.00000,0.00000,1.00000"],
    "groups": [[
        "name": "wave",
        "layers": [["name": "wave", "image-name": "wave.svg"]],
        // Black and white, no glass, like the rest of tilde.
        "translucency": ["enabled": false, "value": 0],
    ]],
    "supported-platforms": ["squares": ["macOS"]],
]
let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
try (data + Data("\n".utf8)).write(to: icon.appending(path: "icon.json"))
