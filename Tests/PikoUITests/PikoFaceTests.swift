import Testing
@testable import PikoUI
import PikoKit

@Test("PikoUITests target compiles and runs")
func targetIsWired() {
    let face = PikoFace(phase: .idle, skin: .cute)
    #expect(face.phase == .idle)
    #expect(face.skin == .cute)
}
