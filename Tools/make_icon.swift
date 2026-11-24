// Writes the app icon in Icon Composer's format (`AppIcon.icon`: icon.json + the mark as an SVG layer),
// which is what macOS, iOS and iPadOS 26 and later draw with their glass effect and in dark, clear and
// tinted looks. Run from the repo root:
//
//   swift Tools/make_icon.swift "Add Captions/AppIcon.icon"
//
// Add `--png <folder>` to also write flat PNG previews (Mac shape, 512 px and 32 px).
//
// The mark is a screen with a play sign and two caption lines: a video, captioned. `LogoMark` in the
// app (Frontend/LogoMark.swift) draws the same thing; keep `markPath` the same as `LogoMark.path(in:)`.
// Same family as Lecture Me Faster's icon: chalk on the brand blue.
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let brand = CGColor(srgbRed: 0x27 / 255.0, green: 0x74 / 255.0, blue: 0xAE / 255.0, alpha: 1)   // #2774AE, the "Brand" colour
let chalk = CGColor(srgbRed: 0.957, green: 0.945, blue: 0.910, alpha: 1)
let aspectRatio: CGFloat = 1.25

/// Copy of `LogoMark.path(in:)`, y going down.
func markPath(in rect: CGRect) -> CGPath {
    let w = rect.width, h = rect.height
    let path = CGMutablePath()
    let frame = rect
    let frameRadius = w * 0.17
    let thickness = w * 0.075
    path.addRoundedRect(in: frame, cornerWidth: frameRadius, cornerHeight: frameRadius)
    let inside = frame.insetBy(dx: thickness, dy: thickness)
    path.addRoundedRect(in: inside, cornerWidth: frameRadius - thickness, cornerHeight: frameRadius - thickness)
    let triangleHeight = h * 0.3
    let triangleWidth = triangleHeight * 0.9
    let center = CGPoint(x: rect.midX + triangleWidth * 0.08, y: rect.minY + h * 0.36)
    path.move(to: CGPoint(x: center.x - triangleWidth / 2, y: center.y - triangleHeight / 2))
    path.addLine(to: CGPoint(x: center.x + triangleWidth / 2, y: center.y))
    path.addLine(to: CGPoint(x: center.x - triangleWidth / 2, y: center.y + triangleHeight / 2))
    path.closeSubpath()
    for (width, y) in [(0.56, 0.63), (0.36, 0.78)] as [(CGFloat, CGFloat)] {
        let line = CGRect(x: rect.midX - w * width / 2, y: rect.minY + h * y, width: w * width, height: h * 0.095)
        path.addRoundedRect(in: line, cornerWidth: line.height / 2, cornerHeight: line.height / 2)
    }
    return path
}

/// `rounded` draws the Mac shape (a rounded square with a margin and a soft shadow). Without it the
/// square is filled to the edges, which is what iPhone and iPad want (they round the corners themselves).
func icon(pixels: Int, rounded: Bool) -> CGImage {
    let size = CGFloat(pixels)
    let context = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    // Flip so y goes down, like SwiftUI. (Shadow offsets ignore this flip: negative still means down.)
    context.translateBy(x: 0, y: size)
    context.scaleBy(x: 1, y: -1)
    let tile = rounded
        ? CGRect(x: 0, y: 0, width: size, height: size).insetBy(dx: size * 100 / 1024, dy: size * 100 / 1024)
        : CGRect(x: 0, y: 0, width: size, height: size)

    context.saveGState()
    if rounded {
        context.setShadow(
            offset: CGSize(width: 0, height: -size * 10 / 1024), blur: size * 20 / 1024,
            color: CGColor(gray: 0, alpha: 0.3)
        )
        context.addPath(CGPath(roundedRect: tile, cornerWidth: tile.width * 0.2237, cornerHeight: tile.width * 0.2237, transform: nil))
    } else {
        context.addRect(tile)
    }
    context.setFillColor(brand)
    context.fillPath()
    context.restoreGState()

    let markWidth = tile.width * 0.6
    let markHeight = markWidth / aspectRatio
    let mark = CGRect(x: tile.midX - markWidth / 2, y: tile.midY - markHeight / 2, width: markWidth, height: markHeight)
    context.setFillColor(chalk)
    context.addPath(markPath(in: mark))
    context.fillPath(using: .evenOdd)
    return context.makeImage()!
}

func write(_ image: CGImage, to url: URL) {
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("Couldn't write \(url.path)") }
}

/// The mark as SVG path data, y going down (SVG's own direction).
func svgPathData(_ path: CGPath) -> String {
    var parts: [String] = []
    func f(_ v: CGFloat) -> String { String(format: "%.2f", v) }
    path.applyWithBlock { element in
        let e = element.pointee, p = e.points
        switch e.type {
        case .moveToPoint: parts.append("M\(f(p[0].x)) \(f(p[0].y))")
        case .addLineToPoint: parts.append("L\(f(p[0].x)) \(f(p[0].y))")
        case .addQuadCurveToPoint: parts.append("Q\(f(p[0].x)) \(f(p[0].y)) \(f(p[1].x)) \(f(p[1].y))")
        case .addCurveToPoint:
            parts.append("C\(f(p[0].x)) \(f(p[0].y)) \(f(p[1].x)) \(f(p[1].y)) \(f(p[2].x)) \(f(p[2].y))")
        case .closeSubpath: parts.append("Z")
        @unknown default: break
        }
    }
    return parts.joined(separator: " ")
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let first = arguments.first, first.hasSuffix(".icon") else { fatalError("Give the path of AppIcon.icon") }
let iconFolder = URL(fileURLWithPath: first)
let assets = iconFolder.appendingPathComponent("Assets")
try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)

// Icon Composer's canvas is 1024 × 1024 points; the mark sits in the middle at 60% of the width.
let canvas: CGFloat = 1024
let markWidth = canvas * 0.6, markHeight = markWidth / aspectRatio
let markRect = CGRect(x: (canvas - markWidth) / 2, y: (canvas - markHeight) / 2, width: markWidth, height: markHeight)
let svg = """
<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
  <path fill="#F4F1E8" fill-rule="evenodd" d="\(svgPathData(markPath(in: markRect)))"/>
</svg>

"""
try svg.write(to: assets.appendingPathComponent("mark.svg"), atomically: true, encoding: .utf8)

// The background is the brand blue; the mark is one glass layer over it.
let iconJSON = """
{
  "fill" : {
    "solid" : "srgb:0.15294,0.45490,0.68235,1.00000"
  },
  "groups" : [
    {
      "layers" : [
        {
          "glass" : true,
          "image-name" : "mark.svg",
          "name" : "mark"
        }
      ],
      "shadow" : {
        "kind" : "neutral",
        "opacity" : 0.5
      },
      "translucency" : {
        "enabled" : true,
        "value" : 0.4
      }
    }
  ],
  "supported-platforms" : {
    "circles" : [
      "watchOS"
    ],
    "squares" : "shared"
  }
}

"""
try iconJSON.write(to: iconFolder.appendingPathComponent("icon.json"), atomically: true, encoding: .utf8)
print("Wrote \(iconFolder.path)")

if let flag = arguments.firstIndex(of: "--png"), arguments.indices.contains(flag + 1) {
    let previews = URL(fileURLWithPath: arguments[flag + 1])
    try FileManager.default.createDirectory(at: previews, withIntermediateDirectories: true)
    for pixels in [512, 32] {
        write(icon(pixels: pixels, rounded: true), to: previews.appendingPathComponent("icon-\(pixels).png"))
    }
    print("Wrote previews to \(previews.path)")
}
