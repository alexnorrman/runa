// Renders the Runa app icon: the Raido rune (ᚱ) on a dark tile. Run: swift scripts/make-icon.swift <appiconset dir>
import AppKit
import CoreGraphics

let output = URL(fileURLWithPath: CommandLine.arguments[1])

func render(size: Int) -> Data {
    let s = CGFloat(size)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: s / 1024, y: s / 1024)
    // macOS icon grid: 824pt tile centered in 1024, corner radius ~185.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let path = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: CGColor(gray: 0, alpha: 0.35))
    ctx.addPath(path)
    ctx.setFillColor(CGColor(srgbRed: 0.03, green: 0.035, blue: 0.04, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let background = CGGradient(colorsSpace: space, colors: [
        CGColor(srgbRed: 0.13, green: 0.14, blue: 0.20, alpha: 1),
        CGColor(srgbRed: 0.035, green: 0.04, blue: 0.045, alpha: 1),
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(background, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    // Soft accent glow behind the glyph.
    let glow = CGGradient(colorsSpace: space, colors: [
        CGColor(srgbRed: 0.37, green: 0.42, blue: 0.82, alpha: 0.35),
        CGColor(srgbRed: 0.37, green: 0.42, blue: 0.82, alpha: 0),
    ] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 560), startRadius: 0, endCenter: CGPoint(x: 512, y: 560), endRadius: 420, options: [])
    ctx.restoreGState()
    // Hairline border.
    ctx.addPath(path)
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.10))
    ctx.setLineWidth(4)
    ctx.strokePath()

    // The rune ᚱ: a stem, an angular bowl, and a leg.
    let rune = CGMutablePath()
    rune.move(to: CGPoint(x: 400, y: 260))   // stem bottom
    rune.addLine(to: CGPoint(x: 400, y: 764)) // stem top
    rune.addLine(to: CGPoint(x: 624, y: 636)) // bowl point
    rune.addLine(to: CGPoint(x: 400, y: 512)) // back to stem
    rune.addLine(to: CGPoint(x: 640, y: 260)) // leg
    ctx.saveGState()
    ctx.addPath(rune)
    ctx.setLineWidth(74)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    let ink = CGGradient(colorsSpace: space, colors: [
        CGColor(srgbRed: 0.62, green: 0.66, blue: 1.0, alpha: 1),
        CGColor(srgbRed: 0.37, green: 0.42, blue: 0.82, alpha: 1),
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(ink, start: CGPoint(x: 400, y: 800), end: CGPoint(x: 640, y: 230), options: [])
    ctx.restoreGState()

    let image = ctx.makeImage()!
    let rep = NSBitmapImageRep(cgImage: image)
    return rep.representation(using: .png, properties: [:])!
}

var images: [String] = []
for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let pixels = points * scale
    let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
    try! render(size: pixels).write(to: output.appendingPathComponent(name))
    images.append("""
        { "filename" : "\(name)", "idiom" : "mac", "scale" : "\(scale)x", "size" : "\(points)x\(points)" }
    """)
}
let contents = "{\n  \"images\" : [\n\(images.joined(separator: ",\n"))\n  ],\n  \"info\" : { \"author\" : \"xcode\", \"version\" : 1 }\n}\n"
try! contents.write(to: output.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
print("Wrote \(images.count) icons")
