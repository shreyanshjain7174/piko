// Generates the notch pet: numbered PNG frames per PikoMood, drawn from PikoFace's own
// geometry (same rule as make-icon.swift — change PikoFace, re-run this).
// Run from the repo root:  swift scripts/make-pet-frames.swift
//
// WidgetKit has no per-frame code path (~1–2 updates/sec) and actool SILENTLY DROPS
// APNG imagesets (verified with xcrun actool — no error, no output), so the frames ship
// as plain numbered PNGs in the widget bundle and animate through
// UIImage.animatedImage(with:duration:), which iOS 17+ widgets play locally at zero
// update budget. The mood only changes rarely, so the Activity swaps images rarely.

import AppKit

let canvasW = 176
let canvasH = 184
let outRoot = "App/PikoWidgets/PetFrames"

struct MoodSpec {
    let name: String
    let frames: Int
    let bobAmplitude: CGFloat
    let blinkFrame: Int?       // frame index where the eyes blink
    let happy: Bool            // happy-arc eyes + open mouth
    let sleepy: Bool           // droopy lids + dimmer fill
}

let moods: [MoodSpec] = [
    MoodSpec(name: "fresh",  frames: 10, bobAmplitude: 5, blinkFrame: nil, happy: false, sleepy: false),
    MoodSpec(name: "happy",  frames: 10, bobAmplitude: 7, blinkFrame: nil, happy: true,  sleepy: false),
    MoodSpec(name: "calm",   frames: 10, bobAmplitude: 3, blinkFrame: 7,   happy: false, sleepy: false),
    MoodSpec(name: "sleepy", frames: 8,  bobAmplitude: 2, blinkFrame: nil, happy: false, sleepy: true),
]

func drawFrame(_ spec: MoodSpec, index: Int, cg: CGContext) {
    let t = Double(index) / Double(spec.frames)
    let bob = CGFloat(sin(t * 2 * .pi) * Double(spec.bobAmplitude))

    cg.setAllowsAntialiasing(true)

    // Soft glow behind the character so it reads on the Island's black pill.
    let glowCenter = CGPoint(x: CGFloat(canvasW) / 2, y: CGFloat(canvasH) / 2 + 8)
    let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: [CGColor(red: 1, green: 0.81, blue: 0.36, alpha: spec.sleepy ? 0.10 : 0.16),
                                   CGColor(red: 1, green: 0.81, blue: 0.36, alpha: 0)] as CFArray,
                          locations: [0, 1])!
    cg.drawRadialGradient(glow, startCenter: glowCenter, startRadius: 0,
                          endCenter: glowCenter, endRadius: 92, options: [])

    // The character, in PikoFace's 140×148 viewBox space, y flipped to CG's y-up.
    // Translate places the viewBox origin so the face center (70, 74) lands on the
    // canvas center, then the negative y-scale flips SVG's y-down to CG's y-up.
    let scale: CGFloat = 1.12
    let squash: CGFloat = spec.sleepy ? 0.97 : 1
    cg.translateBy(x: CGFloat(canvasW) / 2 - 70 * scale,
                   y: CGFloat(canvasH) / 2 + 74 * scale * squash + bob)
    cg.scaleBy(x: scale, y: -scale * squash)

    func path(_ build: (CGMutablePath) -> Void) -> CGPath {
        let p = CGMutablePath()
        build(p)
        return p
    }
    let bodyAlpha: CGFloat = spec.sleepy ? 0.88 : 1
    let yellow = CGColor(red: 1.0, green: 0.81, blue: 0.36, alpha: bodyAlpha)
    let stroke = CGColor(red: 0.94, green: 0.68, blue: 0.20, alpha: 1)
    let ink = CGColor(red: 0.16, green: 0.12, blue: 0.0, alpha: 1)

    // Body.
    let body = path { p in
        p.move(to: CGPoint(x: 70, y: 30))
        p.addCurve(to: CGPoint(x: 118, y: 78), control1: CGPoint(x: 104, y: 30), control2: CGPoint(x: 118, y: 52))
        p.addCurve(to: CGPoint(x: 70, y: 122), control1: CGPoint(x: 118, y: 106), control2: CGPoint(x: 98, y: 122))
        p.addCurve(to: CGPoint(x: 22, y: 78), control1: CGPoint(x: 42, y: 122), control2: CGPoint(x: 22, y: 106))
        p.addCurve(to: CGPoint(x: 70, y: 30), control1: CGPoint(x: 22, y: 52), control2: CGPoint(x: 36, y: 30))
        p.closeSubpath()
    }
    cg.setFillColor(yellow)
    cg.addPath(body); cg.fillPath()
    cg.setLineWidth(2.5 * 1.4)
    cg.setStrokeColor(stroke)
    cg.addPath(body); cg.strokePath()

    // Antenna + tip.
    let antenna = path { p in
        p.move(to: CGPoint(x: 70, y: 30))
        p.addQuadCurve(to: CGPoint(x: 76, y: 12), control: CGPoint(x: 70, y: 18))
    }
    cg.setLineWidth(3)
    cg.setLineCap(.round)
    cg.setStrokeColor(stroke)
    cg.addPath(antenna); cg.strokePath()
    cg.setFillColor(CGColor(red: 0.49, green: 0.80, blue: 0.89, alpha: 1))
    cg.fillEllipse(in: CGRect(x: 77 - 5, y: 10 - 5, width: 10, height: 10))

    // Blush.
    cg.setFillColor(CGColor(red: 1.0, green: 0.55, blue: 0.42, alpha: 0.5))
    cg.fillEllipse(in: CGRect(x: 41 - 9, y: 88 - 6, width: 18, height: 12))
    cg.fillEllipse(in: CGRect(x: 99 - 9, y: 88 - 6, width: 18, height: 12))

    // Eyes.
    let blinking = spec.blinkFrame == index
    if spec.sleepy {
        // Half-lidded: eye ellipses then a body-colored lid over the top half.
        for cx in [55.0, 85.0] {
            cg.setFillColor(ink)
            cg.fillEllipse(in: CGRect(x: cx - 6, y: 74 - 7.5, width: 12, height: 15))
            cg.setFillColor(yellow)
            cg.fill(CGRect(x: cx - 8, y: 74, width: 16, height: 10))
            cg.setFillColor(ink)
            cg.fill(CGRect(x: cx - 6, y: 74 - 3, width: 12, height: 3))
        }
    } else if spec.happy {
        cg.setStrokeColor(ink)
        cg.setLineWidth(3.4)
        for left in [48.0, 78.0] {
            let arc = path { p in
                p.move(to: CGPoint(x: left, y: 77))
                p.addQuadCurve(to: CGPoint(x: left + 14, y: 77), control: CGPoint(x: left + 7, y: 67))
            }
            cg.addPath(arc); cg.strokePath()
        }
    } else if blinking {
        cg.setStrokeColor(ink)
        cg.setLineWidth(3)
        for cx in [55.0, 85.0] {
            let lid = path { p in
                p.move(to: CGPoint(x: cx - 6, y: 74))
                p.addQuadCurve(to: CGPoint(x: cx + 6, y: 74), control: CGPoint(x: cx, y: 70))
            }
            cg.addPath(lid); cg.strokePath()
        }
    } else {
        cg.setFillColor(ink)
        cg.fillEllipse(in: CGRect(x: 55 - 6, y: 74 - 7.5, width: 12, height: 15))
        cg.fillEllipse(in: CGRect(x: 85 - 6, y: 74 - 7.5, width: 12, height: 15))
    }

    // Mouth.
    cg.setFillColor(ink)
    if spec.happy {
        cg.fillEllipse(in: CGRect(x: 70 - 8, y: 95 - 8, width: 16, height: 14))
    } else {
        let mouth = path { p in
            p.move(to: CGPoint(x: 62, y: 95))
            p.addQuadCurve(to: CGPoint(x: 78, y: 95), control: CGPoint(x: 70, y: 103))
            p.addQuadCurve(to: CGPoint(x: 62, y: 95), control: CGPoint(x: 70, y: 99))
            p.closeSubpath()
        }
        cg.addPath(mouth); cg.fillPath()
    }
}

try? FileManager.default.createDirectory(atPath: outRoot, withIntermediateDirectories: true)
for spec in moods {
    for index in 0..<spec.frames {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: canvasW, pixelsHigh: canvasH,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
            fatalError("bitmap context failed")
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        drawFrame(spec, index: index, cg: ctx.cgContext)
        NSGraphicsContext.restoreGraphicsState()
        guard let image = rep.cgImage,
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            fatalError("png encode failed")
        }
        try! png.write(to: URL(fileURLWithPath: "\(outRoot)/pet-\(spec.name)\(index).png"))
    }
    print("wrote \(spec.frames) frames for \(spec.name)")
}
