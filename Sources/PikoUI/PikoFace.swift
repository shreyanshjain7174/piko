import SwiftUI
import PikoKit

/// The character. One view, one state enum, four skins — never four views.
/// Used by the app, the keyboard accessory row and the Live Activity, so it must stay cheap:
/// the keyboard renders this inside a ~60 MB ceiling.
public struct PikoFace: View {
    public var phase: SessionPhase
    public var skin: Skin

    public init(phase: SessionPhase, skin: Skin = .cute) {
        self.phase = phase
        self.skin = skin
    }

    public var body: some View {
        // TODO: port the SVG character from web/index.html to SwiftUI shapes.
        // Body is a squircle; eyes/mouth swap by phase; skin controls colour plus one accessory
        // (antenna / shades / mask+cape / bow).
        Circle()
            .fill(skin.body)
            .overlay(alignment: .center) { Text(phase.glyph).font(.system(size: 22, weight: .bold)) }
            .animation(.spring(duration: 0.35), value: phase)
    }
}

extension Skin {
    var body: Color {
        switch self {
        case .cute:    Color(red: 1.00, green: 0.81, blue: 0.36)
        case .cool:    Color(red: 0.42, green: 0.55, blue: 1.00)
        case .hero:    Color(red: 0.96, green: 0.77, blue: 0.26)
        case .sparkle: Color(red: 1.00, green: 0.71, blue: 0.83)
        }
    }
}

extension SessionPhase {
    var glyph: String {
        switch self {
        case .idle: "-  -"
        case .armed: "o  o"
        case .capturing: "O  O"
        case .tidying: "•••"
        }
    }
}
