// Captures every on-screen Gitoken window individually and composites them, at their on-screen positions, onto a
// generated background. Nothing else on the screen (wallpaper, other apps) can end up in the image.
//
//   swift scripts/compose-screenshot.swift <output.png> [padding-points]
//
// Needs Screen Recording permission for the terminal running it.
import AppKit
import CoreGraphics

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write(Data("usage: compose-screenshot.swift <output.png> [padding]\n".utf8))
    exit(2)
}
let output = URL(fileURLWithPath: args[1])
let padding = CGFloat(args.count > 2 ? Double(args[2]) ?? 48 : 48)

struct Window { let id: CGWindowID; let frame: CGRect; let layer: Int }

let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
let windows: [Window] = info.compactMap { w in
    guard w[kCGWindowOwnerName as String] as? String == "Gitoken",
          w[kCGWindowName as String] as? String != "Gitoken Screenshot Backdrop", // debug scenes' glass backdrop
          (w[kCGWindowAlpha as String] as? Double ?? 0) > 0,
          let id = w[kCGWindowNumber as String] as? CGWindowID,
          let b = w[kCGWindowBounds as String] as? [String: CGFloat],
          let frame = CGRect(dictionaryRepresentation: b as CFDictionary),
          frame.width > 40, frame.height > 40 else { return nil }
    return Window(id: id, frame: frame, layer: w[kCGWindowLayer as String] as? Int ?? 0)
}.reversed() // back to front
guard !windows.isEmpty else { FileHandle.standardError.write(Data("no Gitoken windows on screen\n".utf8)); exit(1) }

let tmp = FileManager.default.temporaryDirectory.appending(path: "gitoken-shots-\(getpid())")
try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmp) }

/// Bounds of the clearly opaque pixels, in points relative to the window: panels sit in larger transparent windows.
func opaqueBounds(_ image: CGImage, scale: CGFloat) -> CGRect? {
    let w = image.width, h = image.height
    var pixels = [UInt8](repeating: 0, count: w * h * 4)
    let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
        guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return true
    }
    guard drawn else { return nil }
    var minX = w, minY = h, maxX = -1, maxY = -1
    for y in 0..<h { // row 0 is the top of the image
        for x in 0..<w where pixels[(y * w + x) * 4 + 3] > 128 {
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        }
    }
    guard maxX >= 0 else { return nil }
    return CGRect(x: CGFloat(minX) / scale, y: CGFloat(minY) / scale,
                  width: CGFloat(maxX - minX + 1) / scale, height: CGFloat(maxY - minY + 1) / scale)
}

// (image, window frame, opaque content frame), all frames in top-left screen points.
var layers: [(NSImage, CGRect, CGRect)] = []
for w in windows {
    let file = tmp.appending(path: "\(w.id).png")
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    p.arguments = ["-x", "-o", "-l", String(w.id), file.path]
    try p.run(); p.waitUntilExit()
    guard let image = NSImage(contentsOf: file),
          let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
          let content = opaqueBounds(cg, scale: CGFloat(cg.width) / w.frame.width) else { continue }
    layers.append((image, w.frame, content.offsetBy(dx: w.frame.minX, dy: w.frame.minY)))
}
guard !layers.isEmpty else { FileHandle.standardError.write(Data("no opaque Gitoken content captured\n".utf8)); exit(1) }

let union = layers.map(\.2).reduce(CGRect.null) { $0.union($1) }
let scale = layers.compactMap { img, frame, _ -> CGFloat? in
    guard let rep = img.representations.first else { return nil }
    return CGFloat(rep.pixelsWide) / frame.width
}.max() ?? 2
let canvas = CGSize(width: (union.width + padding * 2).rounded(), height: (union.height + padding * 2).rounded())

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(canvas.width * scale), pixelsHigh: Int(canvas.height * scale),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = canvas
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// Background: the same dusk gradient as the README header.
NSGradient(colors: [NSColor(srgbRed: 0.11, green: 0.10, blue: 0.20, alpha: 1),
                    NSColor(srgbRed: 0.33, green: 0.22, blue: 0.45, alpha: 1),
                    NSColor(srgbRed: 0.78, green: 0.47, blue: 0.47, alpha: 1)])!
    .draw(in: CGRect(origin: .zero, size: canvas), angle: -70)

for (image, frame, _) in layers {
    // Screen coordinates are top-left based; AppKit drawing is bottom-left based.
    let x = frame.minX - union.minX + padding
    let y = canvas.height - (frame.minY - union.minY + padding) - frame.height
    let rect = CGRect(x: x, y: y, width: frame.width, height: frame.height)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
    shadow.shadowBlurRadius = 28
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.set()
    image.draw(in: rect)
    NSGraphicsContext.restoreGraphicsState()
}
NSGraphicsContext.restoreGraphicsState()

try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
try rep.representation(using: .png, properties: [:])!.write(to: output)
print("\(output.path)  \(layers.count) window(s)")
