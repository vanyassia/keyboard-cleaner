import Cocoa
import CoreGraphics

func createIcon() {
    let size = NSSize(width: 512, height: 512)
    let image = NSImage(size: size)
    
    image.lockFocus()
    let context = NSGraphicsContext.current!.cgContext

    // Follow the macOS icon grid: a rounded-rect tile inset from the canvas
    // edges, otherwise newer macOS versions box the icon in a gray plate.
    let tileRect = CGRect(x: 50, y: 50, width: 412, height: 412)
    context.addPath(CGPath(roundedRect: tileRect, cornerWidth: 92, cornerHeight: 92, transform: nil))
    context.clip()
    context.translateBy(x: 50, y: 50)
    context.scaleBy(x: 412.0 / 512.0, y: 412.0 / 512.0)

    // Draw background gradient (dark charcoal to black)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let colors = [
        NSColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 1.0).cgColor,
        NSColor(red: 0.04, green: 0.04, blue: 0.05, alpha: 1.0).cgColor
    ] as CFArray
    let locations: [CGFloat] = [0.0, 1.0]
    let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: locations)!
    context.drawLinearGradient(gradient, start: CGPoint.zero, end: CGPoint(x: 0, y: 512), options: [])
    
    // Draw a beautiful blue/green circular ring around the icon
    context.setLineWidth(12)
    let ringPath = CGPath(ellipseIn: CGRect(x: 24, y: 24, width: 464, height: 464), transform: nil)
    context.addPath(ringPath)
    
    // Gradient stroke
    let strokeColors = [
        NSColor.cyan.cgColor,
        NSColor.green.cgColor
    ] as CFArray
    let strokeGradient = CGGradient(colorsSpace: colorSpace, colors: strokeColors, locations: nil)!
    context.replacePathWithStrokedPath()
    context.clip()
    context.drawLinearGradient(strokeGradient, start: CGPoint(x: 24, y: 24), end: CGPoint(x: 488, y: 488), options: [])
    
    // Draw keyboard icon inside the circle
    context.resetClip()
    
    // Draw a keyboard shape: base frame
    let kbRect = CGRect(x: 100, y: 180, width: 312, height: 160)
    let kbPath = CGPath(roundedRect: kbRect, cornerWidth: 20, cornerHeight: 20, transform: nil)
    context.addPath(kbPath)
    context.setFillColor(NSColor(white: 0.15, alpha: 1.0).cgColor)
    context.setStrokeColor(NSColor(white: 0.3, alpha: 1.0).cgColor)
    context.setLineWidth(4)
    context.drawPath(using: .fillStroke)
    
    // Draw keyboard keys (rows of small rounded rects)
    let keyWidth: CGFloat = 20
    let keyHeight: CGFloat = 16
    let spacing: CGFloat = 8
    
    let keyColors = [
        NSColor(red: 0.15, green: 0.6, blue: 0.9, alpha: 1.0).cgColor, // light blue
        NSColor(red: 0.1, green: 0.8, blue: 0.5, alpha: 1.0).cgColor   // green
    ]
    
    for row in 0..<4 {
        let y = 180 + 16 + CGFloat(row) * (keyHeight + spacing)
        let numKeys = row == 0 ? 9 : (row == 3 ? 5 : 9)
        let rowWidth = CGFloat(numKeys) * keyWidth + CGFloat(numKeys - 1) * spacing
        let startX = 100 + (312 - rowWidth) / 2
        
        for col in 0..<numKeys {
            let x = startX + CGFloat(col) * (keyWidth + spacing)
            
            // Draw spacebar in row 0
            if row == 0 && col == 4 {
                let spaceRect = CGRect(x: x - 10, y: y, width: 80, height: keyHeight)
                let keyPath = CGPath(roundedRect: spaceRect, cornerWidth: 4, cornerHeight: 4, transform: nil)
                context.addPath(keyPath)
                context.setFillColor(NSColor(white: 0.25, alpha: 1.0).cgColor)
                context.fillPath()
                continue
            }
            
            // Skip keys covered by spacebar
            if row == 0 && (col == 3 || col == 5) {
                continue
            }
            
            let keyRect = CGRect(x: x, y: y, width: keyWidth, height: keyHeight)
            let keyPath = CGPath(roundedRect: keyRect, cornerWidth: 4, cornerHeight: 4, transform: nil)
            context.addPath(keyPath)
            
            // Randomly color a key with cyan/green gradient to show activity
            if (row + col) % 5 == 0 {
                context.setFillColor(keyColors[col % 2])
            } else {
                context.setFillColor(NSColor(white: 0.25, alpha: 1.0).cgColor)
            }
            context.fillPath()
        }
    }
    
    // Draw lock badge in top-right of keyboard
    let lockBgRect = CGRect(x: 310, y: 280, width: 80, height: 80)
    context.addPath(CGPath(ellipseIn: lockBgRect, transform: nil))
    context.setFillColor(NSColor(red: 0.95, green: 0.35, blue: 0.15, alpha: 1.0).cgColor) // orange badge
    context.fillPath()
    
    // Lock icon inside badge
    context.setStrokeColor(NSColor.white.cgColor)
    context.setFillColor(NSColor.white.cgColor)
    context.setLineWidth(4)
    
    // Lock body
    let lockBodyRect = CGRect(x: 330, y: 295, width: 40, height: 30)
    context.addPath(CGPath(roundedRect: lockBodyRect, cornerWidth: 4, cornerHeight: 4, transform: nil))
    context.fillPath()
    
    // Lock shackle
    let shacklePath = CGMutablePath()
    shacklePath.addArc(center: CGPoint(x: 350, y: 325), radius: 14, startAngle: 0, endAngle: .pi, clockwise: false)
    context.addPath(shacklePath)
    context.drawPath(using: .stroke)
    
    image.unlockFocus()
    
    // Save to file
    let tiffData = image.tiffRepresentation!
    let bitmap = NSBitmapImageRep(data: tiffData)!
    let pngData = bitmap.representation(using: .png, properties: [:])!
    
    let fileManager = FileManager.default
    let iconsetURL = URL(fileURLWithPath: "icon.iconset")
    try? fileManager.createDirectory(at: iconsetURL, withIntermediateDirectories: true, attributes: nil)
    
    // iconutil requires the complete macOS iconset size matrix. Render all
    // required pixel sizes from the master image, including the 2x variants.
    let iconSizes: [(String, CGFloat)] = [
        ("icon_16x16.png", 16),
        ("icon_16x16@2x.png", 32),
        ("icon_32x32.png", 32),
        ("icon_32x32@2x.png", 64),
        ("icon_128x128.png", 128),
        ("icon_128x128@2x.png", 256),
        ("icon_256x256.png", 256),
        ("icon_256x256@2x.png", 512),
        ("icon_512x512.png", 512),
        ("icon_512x512@2x.png", 1024)
    ]

    let sourceImage = NSImage(data: pngData)
    for (fileName, pixelSize) in iconSizes {
        guard let sourceImage else { continue }

        let resizedImage = NSImage(size: NSSize(width: pixelSize, height: pixelSize))
        resizedImage.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        sourceImage.draw(
            in: NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize),
            from: .zero,
            operation: .copy,
            fraction: 1.0
        )
        resizedImage.unlockFocus()

        if let resizedTIFF = resizedImage.tiffRepresentation,
           let resizedBitmap = NSBitmapImageRep(data: resizedTIFF),
           let resizedPNG = resizedBitmap.representation(using: .png, properties: [:]) {
            try? resizedPNG.write(to: iconsetURL.appendingPathComponent(fileName))
        }
    }

    // Build an ICNS container directly from the PNG representations. This is
    // intentionally independent of iconutil/ImageIO conversion behavior.
    func appendBigEndian(_ value: UInt32, to data: inout Data) {
        var bigEndianValue = value.bigEndian
        withUnsafeBytes(of: &bigEndianValue) { bytes in
            data.append(contentsOf: bytes)
        }
    }

    let icnsEntries: [(String, String)] = [
        ("icp4", "icon_16x16.png"),
        ("icp5", "icon_32x32.png"),
        ("ic07", "icon_128x128.png"),
        ("ic08", "icon_256x256.png"),
        ("ic09", "icon_512x512.png"),
        ("ic11", "icon_16x16@2x.png"),
        ("ic12", "icon_32x32@2x.png"),
        ("ic13", "icon_128x128@2x.png"),
        ("ic14", "icon_256x256@2x.png"),
        ("ic10", "icon_512x512@2x.png")
    ]

    var icnsBody = Data()
    for (type, fileName) in icnsEntries {
        let pngURL = iconsetURL.appendingPathComponent(fileName)
        guard let pngData = try? Data(contentsOf: pngURL) else { continue }

        icnsBody.append(contentsOf: Data(type.utf8))
        appendBigEndian(UInt32(8 + pngData.count), to: &icnsBody)
        icnsBody.append(pngData)
    }

    var icnsData = Data("icns".utf8)
    appendBigEndian(UInt32(8 + icnsBody.count), to: &icnsData)
    icnsData.append(icnsBody)
    if (try? icnsData.write(to: URL(fileURLWithPath: "AppIcon.icns"))) != nil {
        print("ICNS generated")
    }
    
    print("Icon PNG images generated inside icon.iconset/")
}

createIcon()
