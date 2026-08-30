import Testing
import SwiftUI
@testable import PikoUI
import PikoKit

@Test("PikoFace init wires phase and skin")
func targetIsWired() {
    let face = PikoFace(phase: .idle, skin: .cute)
    #expect(face.phase == .idle)
    #expect(face.skin == .cute)
}

/// Resolves a `Color` to sRGB components so hex-table values can be compared exactly.
private func rgba(_ color: Color) -> (r: Double, g: Double, b: Double) {
    let resolved = color.resolve(in: .init())
    return (Double(resolved.red), Double(resolved.green), Double(resolved.blue))
}

private func expectHex(_ color: Color, _ hex: (UInt8, UInt8, UInt8), epsilon: Double = 0.004) {
    let (r, g, b) = rgba(color)
    let expected = (Double(hex.0) / 255.0, Double(hex.1) / 255.0, Double(hex.2) / 255.0)
    #expect(abs(r - expected.0) < epsilon)
    #expect(abs(g - expected.1) < epsilon)
    #expect(abs(b - expected.2) < epsilon)
}

@Test("Skin.palette matches web/index.html's exact per-skin hex table")
func paletteMatchesHexTable() {
    expectHex(Skin.cute.palette.bodyFill, (0xFF, 0xCF, 0x5C))
    expectHex(Skin.cute.palette.bodyStroke, (0xF0, 0xAE, 0x33))
    expectHex(Skin.cute.palette.blush, (0xFF, 0x8D, 0x6B))
    expectHex(Skin.cute.palette.spark, (0x7C, 0xCB, 0xE2))
    expectHex(Skin.cute.palette.onPiko, (0x2A, 0x1F, 0x00))

    expectHex(Skin.cool.palette.bodyFill, (0x6B, 0x8C, 0xFF))
    expectHex(Skin.cool.palette.bodyStroke, (0x3D, 0x5F, 0xE0))
    expectHex(Skin.cool.palette.blush, (0x22, 0xD3, 0xEE))
    expectHex(Skin.cool.palette.spark, (0x22, 0xD3, 0xEE))
    expectHex(Skin.cool.palette.onPiko, (0x08, 0x12, 0x2E))

    expectHex(Skin.hero.palette.bodyFill, (0xF5, 0xC5, 0x42))
    expectHex(Skin.hero.palette.bodyStroke, (0xC9, 0x92, 0x2A))
    expectHex(Skin.hero.palette.blush, (0xE4, 0x52, 0x3E))
    expectHex(Skin.hero.palette.spark, (0x5B, 0x4B, 0xD6))
    expectHex(Skin.hero.palette.onPiko, (0x2A, 0x1C, 0x00))

    expectHex(Skin.sparkle.palette.bodyFill, (0xFF, 0xB4, 0xD4))
    expectHex(Skin.sparkle.palette.bodyStroke, (0xF1, 0x77, 0xAC))
    expectHex(Skin.sparkle.palette.blush, (0xFF, 0x6F, 0xA8))
    expectHex(Skin.sparkle.palette.spark, (0xC6, 0xA6, 0xFF))
    expectHex(Skin.sparkle.palette.onPiko, (0x3A, 0x0A, 0x22))
}

@Test("SessionPhase.faceState matches the plan's eye/mouth mapping table")
func faceStateMapping() {
    #expect(SessionPhase.idle.faceState.eye == .open)
    #expect(SessionPhase.idle.faceState.mouth == .idle)

    #expect(SessionPhase.armed.faceState.eye == .wide)
    #expect(SessionPhase.armed.faceState.mouth == .idle)

    #expect(SessionPhase.capturing.faceState.eye == .wide)
    #expect(SessionPhase.capturing.faceState.mouth == .open)

    #expect(SessionPhase.tidying.faceState.eye == .open)
    #expect(SessionPhase.tidying.faceState.mouth == .think)
}

@Test("Only the cool skin suppresses eyes")
func coolSkinSuppressesEyes() {
    #expect(Skin.cute.showsEyes)
    #expect(!Skin.cool.showsEyes)
    #expect(Skin.hero.showsEyes)
    #expect(Skin.sparkle.showsEyes)
}
