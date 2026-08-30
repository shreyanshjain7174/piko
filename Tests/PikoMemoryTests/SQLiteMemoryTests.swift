import Testing
import Foundation
@testable import PikoMemory
import PikoKit

@Test("PikoMemoryTests target compiles and runs")
func targetIsWired() {
    #expect(EphemeralMemory.self is (any Memory.Type))
}
