import Testing
import Foundation
import SwiftUI
@testable import PikoUI
import PikoKit

private func relativeLuminance(_ resolved: Color.Resolved) -> Double {
    func channel(_ value: Float) -> Double {
        let c = Double(value)
        return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * channel(resolved.red)
        + 0.7152 * channel(resolved.green)
        + 0.0722 * channel(resolved.blue)
}

private func contrastRatio(_ a: Color, _ b: Color, scheme: ColorScheme) -> Double {
    var environment = EnvironmentValues()
    environment.colorScheme = scheme
    let la = relativeLuminance(a.resolve(in: environment))
    let lb = relativeLuminance(b.resolve(in: environment))
    return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
}

@Suite("Phase appearance contrast")
struct PhaseAppearanceContrastTests {

    @Test("every phase's status colour clears 4.5:1 on the badge fill in both appearances",
          arguments: SessionPhase.allCases, [ColorScheme.light, .dark])
    func statusColourIsLegibleOnBadgeFill(phase: SessionPhase, scheme: ColorScheme) {
        let ratio = contrastRatio(phase.statusColor, PikoColor.badgeFill, scheme: scheme)
        #expect(ratio >= 4.5, "\(phase) in \(scheme) measured \(ratio):1")
    }

    @Test("white on every skin's filled-control tint clears 4.5:1",
          arguments: Skin.allCases, [ColorScheme.light, .dark])
    func whiteOnControlTintIsLegible(skin: Skin, scheme: ColorScheme) {
        let ratio = contrastRatio(.white, skin.controlTint, scheme: scheme)
        #expect(ratio >= 4.5, "\(skin) in \(scheme) measured \(ratio):1")
    }

    @Test("white on the recording fill clears 4.5:1",
          arguments: [ColorScheme.light, .dark])
    func whiteOnRecordingFillIsLegible(scheme: ColorScheme) {
        let ratio = contrastRatio(.white, SessionPhase.capturing.filledControlBackground(skin: .cute),
                                  scheme: scheme)
        #expect(ratio >= 4.5, "recording fill in \(scheme) measured \(ratio):1")
    }
}

@Suite("Phase appearance never relies on colour alone")
struct PhaseAppearanceShapeTests {

    @Test("each phase has a distinct symbol")
    func symbolsAreDistinct() {
        let symbols = SessionPhase.allCases.map(\.symbolName)
        #expect(Set(symbols).count == symbols.count)
    }

    @Test("each phase has a distinct debug name and a spoken status")
    func namesAreDistinct() {
        let names = SessionPhase.allCases.map(\.debugName)
        #expect(Set(names).count == names.count)
        let calm = SessionPhase.allCases.map(\.calmStatus)
        #expect(Set(calm).count == calm.count)
        for phase in SessionPhase.allCases {
            #expect(!phase.spokenStatus.isEmpty)
            #expect(!phase.spokenStatus.contains("…"))
        }
    }

    @Test("armed and idle do not share a symbol, so the mic button is not colour-only")
    func armedAndIdleDiffer() {
        #expect(SessionPhase.armed.symbolName != SessionPhase.idle.symbolName)
    }

    @Test("every skin has a display name distinct from its raw value casing")
    func skinNamesAreCapitalised() {
        for skin in Skin.allCases {
            #expect(skin.displayName == skin.rawValue.capitalized)
        }
    }
}
