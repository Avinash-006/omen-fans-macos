import AppKit

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
}

func paintIcon(size: Int) -> Data? {
    let canvas = NSSize(width: size, height: size)
    let image = NSImage(size: canvas, flipped: false) { _ in
        let scale = CGFloat(size) / 1024
        let transform = NSAffineTransform()
        transform.scale(by: scale)
        transform.concat()

        let tile = NSBezierPath(roundedRect: NSRect(x: 89, y: 89, width: 846, height: 846),
                                xRadius: 199, yRadius: 199)
        NSGradient(starting: color(0.23, 0.19, 0.25), ending: color(0.06, 0.06, 0.09))?
            .draw(in: tile, angle: -65)
        color(0.92, 0.83, 0.89, 0.30).setStroke()
        tile.lineWidth = 12
        tile.stroke()

        let ring = NSBezierPath(ovalIn: NSRect(x: 204, y: 204, width: 616, height: 616))
        color(0.98, 0.28, 0.40, 0.19).setStroke()
        ring.lineWidth = 12
        ring.stroke()

        let gradient = NSGradient(starting: color(1, 0.44, 0.53), ending: color(0.95, 0.12, 0.27))
        for index in 0..<5 {
            NSGraphicsContext.saveGraphicsState()
            let rotation = NSAffineTransform()
            rotation.translateX(by: 512, yBy: 512)
            rotation.rotate(byDegrees: CGFloat(index) * 72)
            rotation.concat()
            let blade = NSBezierPath()
            blade.move(to: NSPoint(x: 34, y: 46))
            blade.curve(to: NSPoint(x: 54, y: 273), controlPoint1: NSPoint(x: 102, y: 114), controlPoint2: NSPoint(x: 110, y: 238))
            blade.curve(to: NSPoint(x: -104, y: 162), controlPoint1: NSPoint(x: 7, y: 305), controlPoint2: NSPoint(x: -93, y: 261))
            blade.curve(to: NSPoint(x: -16, y: 57), controlPoint1: NSPoint(x: -115, y: 88), controlPoint2: NSPoint(x: -54, y: 87))
            blade.close()
            gradient?.draw(in: blade, angle: -55)
            NSGraphicsContext.restoreGraphicsState()
        }

        color(0.99, 0.42, 0.51).setFill()
        NSBezierPath(ovalIn: NSRect(x: 469, y: 469, width: 86, height: 86)).fill()
        return true
    }
    guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
    return bitmap.representation(using: .png, properties: [:])
}

let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let suffix = scale == 2 ? "@2x" : ""
        let path = directory.appendingPathComponent("icon_\(size)x\(size)\(suffix).png")
        guard let data = paintIcon(size: size * scale) else { fatalError("Couldn’t render \(path.lastPathComponent)") }
        try data.write(to: path)
    }
}
