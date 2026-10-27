import SwiftUI
import PikoKit

/// The room Piko lives in. Every surface takes a small share of the chosen skin's hue, the same
/// recipe `web/index.html` uses (`color-mix(in srgb, var(--hue) N%, base)`), so picking a skin
/// repaints the whole app, the keyboard and the Live Activity together.
///
/// Plain colours resolved for one colour scheme: cheap enough for the keyboard's memory ceiling
/// and testable without a trait environment.
public struct PikoTheme: Equatable, Sendable {
    /// The skin this room was painted from, so any view can draw the right Piko.
    public let skin: Skin
    /// The page behind everything.
    public let ground: Color
    /// A bubble or row sitting on the ground: one tone step up.
    public let card: Color
    /// A second step, for a bubble inside a bubble or a pressed control.
    public let cardRaised: Color
    /// The user's own words: a stronger wash of the hue.
    public let wash: Color
    /// Running text.
    public let ink: Color
    /// Secondary text.
    public let ink2: Color
    /// Hints and dates. Never for anything that must be read to proceed.
    public let ink3: Color
    /// Piko's body colour: the one filled action on a screen.
    public let piko: Color
    /// Text and glyphs on `piko`.
    public let onPiko: Color
    /// Links, ticks and tab selection: legible on `ground`.
    public let accent: Color
    /// Gentle warnings: a failed step, a missing permission.
    public let blush: Color
    /// The listening wave and other live marks.
    public let spark: Color

    public init(skin: Skin, scheme: ColorScheme) {
        self.skin = skin
        let hue = skin.hue
        let palette = skin.palette
        let body = skin.bodyRGB
        if scheme == .dark {
            ground = RGB(0x101215).mixed(with: hue, 0.10).color
            card = RGB(0x191C1F).mixed(with: hue, 0.09).color
            cardRaised = RGB(0x1E2126).mixed(with: hue, 0.13).color
            wash = RGB(0x1E2126).mixed(with: hue, 0.26).color
            ink = RGB(0xEFF1EC).mixed(with: hue, 0.08).color
            ink2 = RGB(0xA6A9A3).mixed(with: hue, 0.14).color
            ink3 = RGB(0x757973).mixed(with: hue, 0.16).color
            accent = body.fill.color
        } else {
            ground = RGB(0xFCFCFA).mixed(with: hue, 0.13).color
            card = RGB(0xFFFFFF).mixed(with: hue, 0.04).color
            cardRaised = RGB(0xFFFFFF).mixed(with: hue, 0.09).color
            wash = RGB(0xFFFFFF).mixed(with: hue, 0.30).color
            ink = RGB(0x1A1B18).mixed(with: hue, 0.10).color
            ink2 = RGB(0x5A5C56).mixed(with: hue, 0.12).color
            ink3 = RGB(0x8E9089).mixed(with: hue, 0.14).color
            accent = RGB(0x1A1B18).mixed(with: body.stroke, 0.5).color
        }
        piko = palette.bodyFill
        onPiko = palette.onPiko
        blush = palette.blush
        spark = palette.spark
    }
}

extension Skin {
    /// The hue each skin washes its room with (`--hue` in `web/index.html`).
    var hue: RGB {
        switch self {
        case .cute:    RGB(0x8FBF6E)
        case .cool:    RGB(0x4C7CF0)
        case .hero:    RGB(0xC4922A)
        case .sparkle: RGB(0xEE85B5)
        }
    }

    /// `palette.bodyFill` / `bodyStroke` as raw components, for mixing.
    var bodyRGB: (fill: RGB, stroke: RGB) {
        switch self {
        case .cute:    (RGB(0xFFCF5C), RGB(0xF0AE33))
        case .cool:    (RGB(0x6B8CFF), RGB(0x3D5FE0))
        case .hero:    (RGB(0xF5C542), RGB(0xC9922A))
        case .sparkle: (RGB(0xFFB4D4), RGB(0xF177AC))
        }
    }

    public func theme(for scheme: ColorScheme) -> PikoTheme {
        PikoTheme(skin: self, scheme: scheme)
    }

    /// One line about each look, shown where people choose.
    public var tagline: String {
        switch self {
        case .cute:    "Sunny and soft"
        case .cool:    "Calm in blue"
        case .hero:    "Caped and bold"
        case .sparkle: "Pink, with a bow"
        }
    }
}

/// sRGB components, mixed the way CSS `color-mix(in srgb, …)` does.
struct RGB: Equatable, Sendable {
    let r: Double, g: Double, b: Double

    init(_ hex: UInt32) {
        r = Double((hex >> 16) & 0xFF) / 255
        g = Double((hex >> 8) & 0xFF) / 255
        b = Double(hex & 0xFF) / 255
    }

    private init(r: Double, g: Double, b: Double) {
        self.r = r; self.g = g; self.b = b
    }

    /// `amount` of `other` over `self`.
    func mixed(with other: RGB, _ amount: Double) -> RGB {
        RGB(r: r + (other.r - r) * amount,
            g: g + (other.g - g) * amount,
            b: b + (other.b - b) * amount)
    }

    var color: Color { Color(red: r, green: g, blue: b) }
}

private struct PikoThemeKey: EnvironmentKey {
    static let defaultValue = PikoTheme(skin: .cute, scheme: .light)
}

extension EnvironmentValues {
    public var pikoTheme: PikoTheme {
        get { self[PikoThemeKey.self] }
        set { self[PikoThemeKey.self] = newValue }
    }
}

private struct PikoThemed: ViewModifier {
    let skin: Skin
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let theme = skin.theme(for: scheme)
        content
            .environment(\.pikoTheme, theme)
            .tint(theme.accent)
            .fontDesign(.rounded)
    }
}

extension View {
    /// Paints this subtree in the skin's room and sets the rounded voice Piko speaks in.
    public func pikoThemed(_ skin: Skin) -> some View {
        modifier(PikoThemed(skin: skin))
    }
}

/// The app's one button shape: a full capsule. Primary is Piko's own body colour.
public struct PikoButtonStyle: ButtonStyle {
    public enum Kind: Sendable { case primary, quiet }
    let kind: Kind
    @Environment(\.pikoTheme) private var theme
    @Environment(\.isEnabled) private var isEnabled

    public init(_ kind: Kind = .primary) {
        self.kind = kind
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(kind == .primary ? theme.onPiko : theme.ink)
            .padding(.horizontal, 20)
            .frame(minHeight: 50)
            .background(kind == .primary ? theme.piko : theme.cardRaised, in: Capsule())
            .opacity(isEnabled ? 1 : 0.5)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(duration: 0.2), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PikoButtonStyle {
    public static var piko: PikoButtonStyle { PikoButtonStyle(.primary) }
    public static var pikoQuiet: PikoButtonStyle { PikoButtonStyle(.quiet) }
}

/// An empty list, said by Piko: the character, one line in the room's ink, one line of help.
public struct PikoEmptyState: View {
    let title: String
    let message: String
    @Environment(\.pikoTheme) private var theme

    public init(_ title: String, message: String) {
        self.title = title
        self.message = message
    }

    public var body: some View {
        VStack(spacing: 14) {
            PikoFace(phase: .idle, skin: theme.skin)
                .frame(width: 96, height: 102)
            Text(title)
                .font(.title2.weight(.semibold))
                .foregroundStyle(theme.ink)
            Text(message)
                .font(.body)
                .foregroundStyle(theme.ink2)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}
