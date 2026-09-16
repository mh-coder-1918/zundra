import AppKit

// Composes the app icon from the brain glyph and writes an .icns.
//
//   swift scripts/make-icon.swift Resources/brain.svg Resources/AppIcon.icns
//
// This is a *different* image from the menu-bar glyph. MenuIconTemplate.png is
// a template — macOS throws away its colour and tints it for light/dark. An app
// icon is the opposite: it is never tinted, it has to carry its own colour, and
// it is seen in Finder, the DMG window, the Dock, Sparkle's update dialog and
// every "an app downloaded from the internet" prompt. Without one, all of those
// show the generic blank page.
//
// Needs `iconutil`, which ships with the Command Line Tools.

let args = CommandLine.arguments
guard args.count == 3 else {
    fputs("usage: make-icon in.svg out.icns\n", stderr)
    exit(2)
}
let svgURL = URL(fileURLWithPath: args[1])
let icnsURL = URL(fileURLWithPath: args[2])

guard let glyph = NSImage(contentsOf: svgURL) else {
    fputs("failed to load \(svgURL.path)\n", stderr)
    exit(1)
}

// Big Sur onwards, a macOS icon is a rounded square floating in a transparent
// canvas rather than filling it: 824pt of art on a 1024pt grid, corner radius
// 185. Everything below is expressed as a fraction of the canvas so each size
// renders from the same geometry rather than from a scaled bitmap.
let bodyInset: CGFloat = 100.0 / 1024.0
let cornerRadius: CGFloat = 185.0 / 1024.0
let glyphWidth: CGFloat = 0.58

// Indigo into violet. Deliberately not one of the three colours the panel
// already spends meaning on (the accent tint = today, purple = long-term,
// orange = the planning task): an icon sitting in the Dock next to the panel
// shouldn't look like it is saying one of those things.
let top = NSColor(srgbRed: 0.42, green: 0.35, blue: 0.93, alpha: 1)
let bottom = NSColor(srgbRed: 0.28, green: 0.20, blue: 0.72, alpha: 1)

func render(_ px: Int) -> NSBitmapImageRep {
    let side = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: side, height: side)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor.clear.set()
    NSRect(x: 0, y: 0, width: side, height: side).fill()

    let inset = side * bodyInset
    let body = NSRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
    let radius = side * cornerRadius
    let shape = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)
    shape.addClip()
    NSGradient(starting: top, ending: bottom)?.draw(in: body, angle: -90)

    // The glyph is a white stroked outline, so it lands on the gradient as-is.
    // At 16pt those strokes are barely over a pixel wide — legible, but this is
    // the honest limit of reusing a line-art glyph as an app icon, and the
    // reason to revisit this once the app has a visual identity of its own.
    let w = side * glyphWidth
    let box = NSRect(x: (side - w) / 2, y: (side - w) / 2, width: w, height: w)
    glyph.draw(in: box, from: .zero, operation: .sourceOver, fraction: 1.0)

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

// iconutil reads a directory of exactly these names.
let slices: [(name: String, px: Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

let iconset = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("AppIcon-\(ProcessInfo.processInfo.processIdentifier).iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for slice in slices {
    guard let data = render(slice.px).representation(using: .png, properties: [:]) else {
        fputs("png encode failed for \(slice.name)\n", stderr)
        exit(1)
    }
    try! data.write(to: iconset.appendingPathComponent(slice.name))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", icnsURL.path]
try! iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    fputs("iconutil failed (\(iconutil.terminationStatus))\n", stderr)
    exit(1)
}
try? FileManager.default.removeItem(at: iconset)
print("wrote \(icnsURL.path)")
