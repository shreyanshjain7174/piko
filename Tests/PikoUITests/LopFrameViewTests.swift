import CoreGraphics
import SwiftUI
import Testing
import PikoUI

@Suite("Lop still-frame rendering")
@MainActor
struct LopFrameViewTests {
    private static let presets: [(String, LopPose)] = [
        ("rest", .rest), ("blink", .blink), ("earTwitch", .earTwitch),
        ("glanceLeft", .glanceLeft), ("glanceRight", .glanceRight),
        ("nose", .nose), ("flop", .flop),
        ("earsUp(0)", .earsUp(level: 0)), ("earsUp(0.5)", .earsUp(level: 0.5)),
        ("earsUp(1)", .earsUp(level: 1)), ("thump", .thump), ("tilt", .tilt),
        ("swivelLeft", .swivelLeft), ("swivelRight", .swivelRight),
        ("binky1", .binky1), ("binky2", .binky2),
    ]

    @Test("every preset has cream fur, ink and transparency, and renders deterministically",
          arguments: [22, 26, 48, 58], [LopFrameStyle.flat, .soft])
    func everyPreset(size: Int, style: LopFrameStyle) throws {
        for (name, pose) in Self.presets {
            let image = try render(pose, style: style, size: size)
            let pixels = image.pixels
            #expect(pixels.filter { $0.a > 200 }.count > pixels.count / 25, "\(name)")
            #expect(pixels.filter { $0.a == 0 }.count > pixels.count / 4, "\(name)")
            #expect(pixels.filter(\.isCream).count > pixels.count / 50, "\(name)")
            #expect(pixels.contains { $0.a > 200 && $0.r < 90 && $0.g < 90 && $0.b < 90 }, "\(name)")
            let repeated = try render(pose, style: style, size: size)
            let changed = image.pixels.indices.filter { image.pixels[$0] != repeated.pixels[$0] }
            #expect(changed.isEmpty, "\(name): \(changed.count) pixels differ; \(changed.prefix(3).map { "\(image.pixels[$0]) -> \(repeated.pixels[$0])" })")
        }
    }

    @Test("caller ink changes actual strokes but not the cream fur",
          arguments: [22, 26, 48, 58], [LopFrameStyle.flat, .soft])
    func customInk(size: Int, style: LopFrameStyle) throws {
        let dark = try render(.rest, style: style, size: size)
        let blue = try render(.rest, style: style, size: size,
                              ink: Color(red: 0.1, green: 0.3, blue: 0.85))
        #expect(dark != blue)
        #expect(blue.pixels.contains { $0.a > 200 && $0.r < 100 && $0.g < 150 && $0.b > 160 })
        // Exclude antialiased ink boundaries: changing ink must tint those blended pixels,
        // but must leave the fully interior fur exactly unchanged.
        let cream = dark.interiorCreamIndices
        #expect(cream.count > dark.pixels.count / 100)
        let unchanged = cream.filter { dark.pixels[$0] == blue.pixels[$0] }
        #expect(unchanged.count == cream.count)
    }

    @Test("meaningful poses produce different pixels",
          arguments: [22, 26, 48, 58], [LopFrameStyle.flat, .soft])
    func posesDiffer(size: Int, style: LopFrameStyle) throws {
        let pairs: [(LopPose, LopPose)] = [
            (.rest, .blink), (.earsUp(level: 0), .earsUp(level: 1)),
            (.glanceLeft, .glanceRight), (.binky1, .binky2), (.rest, .nose),
            (.rest, .earTwitch), (.rest, .flop), (.rest, .thump), (.rest, .tilt),
            (.swivelLeft, .swivelRight),
        ]
        for (a, b) in pairs {
            #expect(try render(a, style: style, size: size) != render(b, style: style, size: size))
        }
    }

    @Test("earsUp consumes normalized levels, clamps bounds and stays on each side")
    func normalizedEars() {
        #expect(LopPose.earsUp(level: -1) == .earsUp(level: 0))
        #expect(LopPose.earsUp(level: 2) == .earsUp(level: 1))
        #expect(LopPose.earsUp(level: .nan) == .earsUp(level: 0))
        for level in [0.0, 0.25, 0.5, 0.75, 1] {
            let pose = LopPose.earsUp(level: level)
            #expect(abs(pose.earLeft - (-40 + 36 * level)) < 0.0001)
            #expect(abs(pose.foldRight - (55 - 49 * level)) < 0.0001)
            #expect(pose.earLeft < 0 && pose.earRight > 0)
        }
    }

    private func render(_ pose: LopPose, style: LopFrameStyle, size: Int,
                        ink: Color = Color(red: 0.12, green: 0.10, blue: 0.09)) throws -> Bitmap {
        let renderer = ImageRenderer(content: LopFrameView(pose: pose, style: style, ink: ink)
            .frame(width: CGFloat(size), height: CGFloat(size))
            .environment(\.colorScheme, .light))
        renderer.scale = 3
        renderer.isOpaque = false
        // Render directly into explicit sRGB, premultiplied RGBA8 rather than letting an
        // intermediate image choose a color space/format and quantize it a second time.
        let width = size * 3
        var bytes = [UInt8](repeating: 0, count: width * width * 4)
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try #require(CGContext(
                data: buffer.baseAddress, width: width, height: width,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.scaleBy(x: 3, y: 3)
            renderer.render(rasterizationScale: 3) { renderedSize, draw in
                #expect(renderedSize == CGSize(width: size, height: size))
                draw(context)
            }
            let image = try #require(context.makeImage())
            #expect(image.width == width && image.height == width)
        }
        return Bitmap(width: width, pixels: stride(from: 0, to: bytes.count, by: 4).map {
            Pixel(r: bytes[$0], g: bytes[$0 + 1], b: bytes[$0 + 2], a: bytes[$0 + 3])
        })
    }
}

private struct Bitmap: Equatable {
    let width: Int
    let pixels: [Pixel]

    var interiorCreamIndices: [Int] {
        pixels.indices.filter { index in
            guard index >= width, index < pixels.count - width,
                  index % width > 0, index % width < width - 1 else { return false }
            return (-1...1).allSatisfy { y in
                (-1...1).allSatisfy { x in pixels[index + y * width + x].isCream }
            }
        }
    }
}

private struct Pixel: Equatable {
    let r: UInt8
    let g: UInt8
    let b: UInt8
    let a: UInt8

    var isCream: Bool {
        a > 240 && r > 220 && g > 200 && b > 180 && r > g && g > b
    }
}
