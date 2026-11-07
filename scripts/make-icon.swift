// Generates the app icon as an Icon Composer document with light and dark appearances:
//   light: white background + iCloud-style blue gradient cloud
//   dark:  black background + low-saturation cloud
// Output: Resources/AppIcon.icon (compiled by scripts/bundle.sh with actool)
//         Resources/AppIcon-light.png / AppIcon-dark.png (flattened previews)
// Usage: swift scripts/make-icon.swift
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let resources = root.appendingPathComponent("Resources")
let iconDoc = resources.appendingPathComponent("AppIcon.icon")
let assets = iconDoc.appendingPathComponent("Assets")
try? FileManager.default.removeItem(at: iconDoc)
try? FileManager.default.removeItem(at: resources.appendingPathComponent("AppIcon.icns"))
try? FileManager.default.removeItem(at: resources.appendingPathComponent("AppIcon.png"))
try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)

struct Style {
    let gradient: [NSColor]      // cloud fill, bottom → top (iCloud-style vertical blue)
    let arrows: NSColor          // sync arrows inside the cloud
    let shadow: NSColor
    let background: NSColor      // only used for the flattened preview
}

func srgb(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

let light = Style(
    gradient: [srgb(0x1A6FEF), srgb(0x2F8AF7), srgb(0x52AEFC), srgb(0x86D3FF)],
    arrows: .white,
    shadow: srgb(0x1A6FEF, 0.25),
    background: srgb(0xFFFFFF))

let dark = Style(
    gradient: [srgb(0xC9D1DB), srgb(0xD8DEE6), srgb(0xE6EAF0), srgb(0xF4F6F9)],
    arrows: srgb(0x15161A),
    shadow: srgb(0x000000, 0.0),
    background: srgb(0x0B0B0D))

func bitmap(_ size: Int, draw: (CGContext, CGFloat) -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw(NSGraphicsContext.current!.cgContext, CGFloat(size) / 1024)
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func symbolMask(_ name: String, pointSize: CGFloat, weight: NSFont.Weight) -> NSImage {
    let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        .applying(.init(paletteColors: [.black]))
    return NSImage(systemSymbolName: name, accessibilityDescription: nil)!.withSymbolConfiguration(config)!
}

/// The foreground layer: gradient cloud with sync arrows, on transparent background (1024 canvas).
func drawCloud(_ ctx: CGContext, _ s: CGFloat, _ style: Style) {
    let size = 1024 * s
    let cloud = symbolMask("cloud.fill", pointSize: 620 * s, weight: .regular)
    let cw = cloud.size.width, ch = cloud.size.height
    let rect = CGRect(x: (size - cw) / 2, y: (size - ch) / 2 - 12 * s, width: cw, height: ch)
    let cgCloud = cloud.cgImage(forProposedRect: nil, context: nil, hints: nil)!

    // Soft coloured shadow under the cloud.
    if style.shadow.alphaComponent > 0 {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -18 * s), blur: 40 * s, color: style.shadow.cgColor)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.clip(to: rect, mask: cgCloud)
        ctx.setFillColor(style.gradient[1].cgColor)
        ctx.fill(rect)
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    // Gradient fill clipped to the cloud shape.
    ctx.saveGState()
    ctx.clip(to: rect, mask: cgCloud)
    let colors = style.gradient.map(\.cgColor) as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors,
                              locations: [0, 0.35, 0.7, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: rect.midX, y: rect.minY + ch * 0.08),
                           end: CGPoint(x: rect.midX, y: rect.maxY - ch * 0.05), options: [])
    // Gentle top highlight for depth.
    let shine = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                           colors: [NSColor.white.withAlphaComponent(0.20).cgColor,
                                    NSColor.white.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(shine, start: CGPoint(x: 0, y: rect.maxY), end: CGPoint(x: 0, y: rect.midY), options: [])
    ctx.restoreGState()

    // Sync arrows.
    let arrows = symbolMask("arrow.triangle.2.circlepath", pointSize: 255 * s, weight: .bold)
    let aw = arrows.size.width, ah = arrows.size.height
    let arect = CGRect(x: (size - aw) / 2, y: rect.minY + ch * 0.17, width: aw, height: ah)
    ctx.saveGState()
    ctx.clip(to: arect, mask: arrows.cgImage(forProposedRect: nil, context: nil, hints: nil)!)
    ctx.setFillColor(style.arrows.cgColor)
    ctx.fill(arect)
    ctx.restoreGState()
}

func png(_ rep: NSBitmapImageRep, _ url: URL) throws {
    try rep.representation(using: .png, properties: [:])!.write(to: url)
}

// Layer images for Icon Composer.
try png(bitmap(1024) { ctx, s in drawCloud(ctx, s, light) }, assets.appendingPathComponent("light.png"))
try png(bitmap(1024) { ctx, s in drawCloud(ctx, s, dark) }, assets.appendingPathComponent("dark.png"))

// Flattened previews (rounded plate + layer), handy for README / older tooling.
for (name, style) in [("light", light), ("dark", dark)] {
    let rep = bitmap(1024) { ctx, s in
        let plate = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
        let path = CGPath(roundedRect: plate, cornerWidth: 185 * s, cornerHeight: 185 * s, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -8 * s), blur: 24 * s, color: NSColor.black.withAlphaComponent(0.3).cgColor)
        ctx.addPath(path); ctx.setFillColor(style.background.cgColor); ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(path); ctx.clip()
        // The layer is authored for the full 1024 canvas; the system shrinks it onto the 824 plate.
        ctx.translateBy(x: 100 * s, y: 100 * s)
        ctx.scaleBy(x: 824.0 / 1024, y: 824.0 / 1024)
        drawCloud(ctx, s, style)
        ctx.restoreGState()
    }
    try png(rep, resources.appendingPathComponent("AppIcon-\(name).png"))
}

let json = """
{
  "fill-specializations" : [
    { "value" : { "solid" : "srgb:1.00000,1.00000,1.00000,1.00000" } },
    { "appearance" : "dark", "value" : { "solid" : "srgb:0.04314,0.04314,0.05098,1.00000" } }
  ],
  "groups" : [
    {
      "layers" : [
        {
          "glass" : false,
          "image-name-specializations" : [
            { "value" : "light.png" },
            { "appearance" : "dark", "value" : "dark.png" }
          ],
          "name" : "Cloud"
        }
      ],
      "shadow" : { "kind" : "neutral", "opacity" : 0 },
      "specular" : false,
      "translucency" : { "enabled" : false, "value" : 0 }
    }
  ],
  "supported-platforms" : { "squares" : "shared" }
}
"""
try json.write(to: iconDoc.appendingPathComponent("icon.json"), atomically: true, encoding: .utf8)
print("Wrote Resources/AppIcon.icon and previews")
