import AppKit

// Retain PNG pixels and structural chunks, but no local display/EXIF metadata.
func publicPNG(_ data: Data) -> Data {
    var result = Data(data.prefix(8))
    var offset = 8
    while offset + 12 <= data.count {
        let length = (0..<4).reduce(0) { ($0 << 8) | Int(data[offset + $1]) }
        let end = offset + length + 12
        precondition(end <= data.count, "Invalid generated PNG")
        let kind = String(decoding: data[(offset + 4)..<(offset + 8)], as: UTF8.self)
        if !["iCCP", "eXIf", "iTXt", "tEXt", "zTXt"].contains(kind) {
            result.append(data[offset..<end])
        }
        offset = end
    }
    return result
}

// Original code-drawn app mark; product renders are separate unmodified assets.
let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let size = points * scale
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        let scaleFactor = CGFloat(size)/1024
        let transform = NSAffineTransform(); transform.scale(by: scaleFactor); transform.concat()
        let rect = NSRect(x: 75, y: 75, width: 874, height: 874)
        let shape = NSBezierPath(roundedRect: rect, xRadius: 196, yRadius: 196)
        NSGradient(starting: NSColor(calibratedRed: 0.22, green: 0.28, blue: 0.40, alpha: 1), ending: NSColor(calibratedRed: 0.07, green: 0.09, blue: 0.14, alpha: 1))!.draw(in: shape, angle: -65)
        let heights: [CGFloat] = [110, 250, 420, 310, 540, 260, 150]
        for (i, height) in heights.enumerated() {
            NSColor(calibratedRed: 0.72 + CGFloat(i)*0.025, green: 0.83 + CGFloat(i)*0.02, blue: 1, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: 263 + CGFloat(i)*74, y: 512-height/2, width: 42, height: height), xRadius: 21, yRadius: 21).fill()
        }
        image.unlockFocus()
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        // AppKit can inherit a display profile containing a personal device name.
        bitmap.setProperty(.colorSyncProfileData, withValue: nil)
        let suffix = scale == 2 ? "@2x" : ""
        try publicPNG(bitmap.representation(using: .png, properties: [:])!).write(to: folder.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
    }
}
