// Generates the Piko app icon (1024×1024) from the character's own geometry.
// Run from the repo root:  swift scripts/make-icon.swift
// Everything here mirrors Sources/PikoUI/PikoFace.swift's cute-skin paths — do not
// diverge: change PikoFace, then re-run this.

import AppKit

let side = 1024
guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
    let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
    fatalError("could not create bitmap context")
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = ctx
let cg = ctx.cgContext

// Deep-space background.
cg.setFillColor(CGColor(red: 0.02, green: 0.04, blue: 0.09, alpha: 1))
cg.fill(CGRect(x: 0, y: 0, width: side, height: side))

func radial(_ colors: [(CGFloat, CGColor)], center: CGPoint, radius: CGFloat) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
               colors: colors.map { $0.1 } as CFArray,
               locations: colors.map { $0.0 })!
}

// Soft aurora glow behind the orb.
let glowCenter = CGPoint(x: 340, y: 700)
cg.drawRadialGradient(
    radial([(0, CGColor(red: 0.11, green: 0.55, blue: 0.65, alpha: 0.55)),
            (1, CGColor(red: 0.11, green: 0.55, blue: 0.65, alpha: 0))],
           center: glowCenter, radius: 620),
    startCenter: glowCenter, startRadius: 0, endCenter: glowCenter, endRadius: 620, options: [])

// The orb: translucent glass ball with a lit core and dark limb.
let orbCenter = CGPoint(x: 512, y: 470)
let orbRadius: CGFloat = 348
cg.drawRadialGradient(
    radial([(0, CGColor(red: 0.36, green: 0.75, blue: 0.85, alpha: 0.62)),
            (0.55, CGColor(red: 0.10, green: 0.30, blue: 0.42, alpha: 0.55)),
            (1, CGColor(red: 0.03, green: 0.06, blue: 0.14, alpha: 0.95))],
           center: CGPoint(x: orbCenter.x - 90, y: orbCenter.y + 110), radius: orbRadius * 1.35),
    startCenter: orbCenter, startRadius: 0, endCenter: orbCenter, endRadius: orbRadius * 1.35, options: [])
cg.setLineWidth(7)
cg.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.32))
cg.strokeEllipse(in: CGRect(x: orbCenter.x - orbRadius, y: orbCenter.y - orbRadius,
                            width: orbRadius * 2, height: orbRadius * 2))

// Specular highlight, upper-left.
let specCenter = CGPoint(x: orbCenter.x - 150, y: orbCenter.y + 190)
cg.drawRadialGradient(
    radial([(0, CGColor(red: 1, green: 1, blue: 1, alpha: 0.35)),
            (1, CGColor(red: 1, green: 1, blue: 1, alpha: 0))],
           center: specCenter, radius: 220),
    startCenter: specCenter, startRadius: 0, endCenter: specCenter, endRadius: 220, options: [])

// The character, drawn in PikoFace's 140×148 viewBox space. The viewBox is y-down
// (SVG) while this canvas is y-up, so the transform flips vertically.
let scale: CGFloat = 3.45
cg.translateBy(x: orbCenter.x - 70 * scale, y: orbCenter.y + 76 * scale)
cg.scaleBy(x: scale, y: -scale)

func path(_ build: (CGMutablePath) -> Void) -> CGPath {
    let p = CGMutablePath()
    build(p)
    return p
}

// Body (matches PikoFace.bodyPath).
let body = path { p in
    p.move(to: CGPoint(x: 70, y: 30))
    p.addCurve(to: CGPoint(x: 118, y: 78), control1: CGPoint(x: 104, y: 30), control2: CGPoint(x: 118, y: 52))
    p.addCurve(to: CGPoint(x: 70, y: 122), control1: CGPoint(x: 118, y: 106), control2: CGPoint(x: 98, y: 122))
    p.addCurve(to: CGPoint(x: 22, y: 78), control1: CGPoint(x: 42, y: 122), control2: CGPoint(x: 22, y: 106))
    p.addCurve(to: CGPoint(x: 70, y: 30), control1: CGPoint(x: 22, y: 52), control2: CGPoint(x: 36, y: 30))
    p.closeSubpath()
}
cg.setFillColor(CGColor(red: 1.0, green: 0.81, blue: 0.36, alpha: 1))
cg.addPath(body); cg.fillPath()
cg.setLineWidth(2.5 * 1.4)
cg.setStrokeColor(CGColor(red: 0.94, green: 0.68, blue: 0.20, alpha: 1))
cg.addPath(body); cg.strokePath()

// Antenna + tip.
let antenna = path { p in
    p.move(to: CGPoint(x: 70, y: 30))
    p.addQuadCurve(to: CGPoint(x: 76, y: 12), control: CGPoint(x: 70, y: 18))
}
cg.setLineWidth(3)
cg.setLineCap(.round)
cg.setStrokeColor(CGColor(red: 0.94, green: 0.68, blue: 0.20, alpha: 1))
cg.addPath(antenna); cg.strokePath()
cg.setFillColor(CGColor(red: 0.49, green: 0.80, blue: 0.89, alpha: 1))
cg.fillEllipse(in: CGRect(x: 77 - 5, y: 10 - 5, width: 10, height: 10))

// Blush.
cg.setFillColor(CGColor(red: 1.0, green: 0.55, blue: 0.42, alpha: 0.5))
cg.fillEllipse(in: CGRect(x: 41 - 9, y: 88 - 6, width: 18, height: 12))
cg.fillEllipse(in: CGRect(x: 99 - 9, y: 88 - 6, width: 18, height: 12))

// Eyes (open) and smile (idle mouth), dark on yellow.
let ink = CGColor(red: 0.16, green: 0.12, blue: 0.0, alpha: 1)
cg.setFillColor(ink)
cg.fillEllipse(in: CGRect(x: 55 - 6, y: 74 - 7.5, width: 12, height: 15))
cg.fillEllipse(in: CGRect(x: 85 - 6, y: 74 - 7.5, width: 12, height: 15))
let mouth = path { p in
    p.move(to: CGPoint(x: 62, y: 95))
    p.addQuadCurve(to: CGPoint(x: 78, y: 95), control: CGPoint(x: 70, y: 103))
    p.addQuadCurve(to: CGPoint(x: 62, y: 95), control: CGPoint(x: 70, y: 99))
    p.closeSubpath()
}
cg.addPath(mouth); cg.fillPath()

NSGraphicsContext.restoreGraphicsState()

let out = URL(fileURLWithPath: "App/Assets.xcassets/AppIcon.appiconset/icon-1024.png")
guard let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("png encoding failed")
}
try! png.write(to: out)
print("wrote \(out.path)")
