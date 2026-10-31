import Foundation

/// One allowance per explicit voice initiation. Home is the sole caller of `takeAutomaticListen`;
/// questions, confirmations and completed answers/actions all spend from this same budget.
public struct FollowUpPolicy: Sendable {
    public static let maxAutomaticListens = 3
    public private(set) var automaticListensUsed = 0
    private var voiceTurnActive = false
    public var isVoiceTurnActive: Bool { voiceTurnActive }

    public init() {}

    public mutating func beginVoiceTurn() {
        automaticListensUsed = 0
        voiceTurnActive = true
    }

    /// Stop automatic capture without replenishing the allowance (e.g. typed input or Stop).
    public mutating func endVoiceTurn() {
        voiceTurnActive = false
    }

    /// Called once, immediately before *each* automatic listen, never for a manual listen.
    @discardableResult
    public mutating func takeAutomaticListen(
        voiceInitiated: Bool, isQuiet: Bool, isForeground: Bool, isCurrent: Bool,
        succeeded: Bool, isExecutingTools: Bool
    ) -> Bool {
        guard voiceTurnActive, voiceInitiated, !isQuiet, isForeground, isCurrent,
              succeeded, !isExecutingTools, automaticListensUsed < Self.maxAutomaticListens else { return false }
        automaticListensUsed += 1
        return true
    }

    /// Only complete short farewells close an *unprompted* follow-up. Never match substrings.
    public static func isClosing(_ text: String) -> Bool {
        let stripped = text.lowercased()
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\u{2019}", with: "")
        var words = stripped.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        let wrappers: Set<String> = ["piko", "ok", "okay"]
        while let first = words.first, wrappers.contains(first) { words.removeFirst() }
        while let last = words.last, wrappers.contains(last) { words.removeLast() }
        let closings: Set<String> = [
            "thats all", "thats it", "nothing else", "no thanks", "no thank you",
            "thanks", "thank you", "bye", "goodbye", "stop", "done", "all done",
        ]
        return closings.contains(words.joined(separator: " "))
    }
}
