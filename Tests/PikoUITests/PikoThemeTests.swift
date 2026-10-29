import Testing
import SwiftUI
@testable import PikoUI
import PikoKit

private func luminance(_ color: Color) -> Double {
    let resolved = color.resolve(in: EnvironmentValues())
    func channel(_ value: Float) -> Double {
        let c = Double(value)
        return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * channel(resolved.red) + 0.7152 * channel(resolved.green) + 0.0722 * channel(resolved.blue)
}

private func contrast(_ a: Color, _ b: Color) -> Double {
    let la = luminance(a), lb = luminance(b)
    return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
}

@Suite("Skin themes stay legible")
struct PikoThemeTests {

    @Test("running text reads on the ground and in bubbles", arguments: Skin.allCases, [ColorScheme.light, .dark])
    func inkIsLegible(skin: Skin, scheme: ColorScheme) {
        let theme = skin.theme(for: scheme)
        #expect(contrast(theme.ink, theme.ground) >= 7)
        #expect(contrast(theme.ink, theme.wash) >= 7)
        #expect(contrast(theme.ink2, theme.card) >= 4.5)
    }

    @Test("the primary button's label reads on Piko's body colour", arguments: Skin.allCases, [ColorScheme.light, .dark])
    func onPikoIsLegible(skin: Skin, scheme: ColorScheme) {
        let theme = skin.theme(for: scheme)
        #expect(contrast(theme.onPiko, theme.piko) >= 4.5)
    }

    @Test("accent text and ticks read on the ground", arguments: Skin.allCases, [ColorScheme.light, .dark])
    func accentIsLegible(skin: Skin, scheme: ColorScheme) {
        let theme = skin.theme(for: scheme)
        #expect(contrast(theme.accent, theme.ground) >= 4.5, "\(skin) \(scheme)")
    }

    @Test("each skin paints a different room")
    func skinsDiffer() {
        let grounds = Skin.allCases.map { luminance($0.theme(for: .light).ground) }
        #expect(Set(Skin.allCases.map { "\($0.theme(for: .light).ground)" }).count == Skin.allCases.count)
        #expect(grounds.allSatisfy { $0 > 0.8 })
    }
}
