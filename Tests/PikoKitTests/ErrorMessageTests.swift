import Testing
import Foundation
import PikoKit

@Suite("PikoError user-facing messages")
struct ErrorMessageTests {

    private static let allCases: [PikoError] = [
        .notForeground,
        .notArmed,
        .sessionInterrupted,
        .microphoneDenied,
        .audioUnavailable,
        .brainUnavailable("Apple Intelligence off"),
        .brainBudgetExceeded(milliseconds: 900),
    ]

    @Test("every case has a message that reads as a sentence", arguments: Self.allCases)
    func messagesAreSentences(error: PikoError) {
        let message = error.userMessage
        #expect(!message.isEmpty)
        #expect(message.hasSuffix(".") || message.hasSuffix("!"))
        #expect(message.first?.isUppercase == true)
    }

    @Test("no message leaks an enum case name or Swift type syntax",
          arguments: Self.allCases)
    func messagesDoNotLeakInternals(error: PikoError) {
        let message = error.userMessage
        for leak in ["PikoError", "milliseconds:", "Optional(", "Error("] {
            #expect(!message.contains(leak), "\(message) leaked \(leak)")
        }
    }

    @Test("messages are distinct, so two different failures never read the same")
    func messagesAreDistinct() {
        let messages = Self.allCases.map(\.userMessage)
        #expect(Set(messages).count == messages.count)
    }

    @Test("a non-PikoError falls back to a message rather than an interpolated error")
    func fallbackForForeignError() {
        struct Opaque: Error {}
        let message = PikoError.userMessage(for: Opaque())
        #expect(!message.contains("Opaque"))
        #expect(message.hasSuffix("."))
    }

    @Test("a PikoError routed through the fallback keeps its specific message")
    func fallbackPrefersSpecificMessage() {
        #expect(PikoError.userMessage(for: PikoError.microphoneDenied)
                == PikoError.microphoneDenied.userMessage)
    }
}
