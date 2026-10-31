import Testing
@testable import PikoBrain

@Suite struct FollowUpPolicyTests {
    private func take(
        _ policy: inout FollowUpPolicy,
        voice: Bool = true,
        quiet: Bool = false,
        foreground: Bool = true,
        current: Bool = true,
        succeeded: Bool = true,
        executing: Bool = false
    ) -> Bool {
        policy.takeAutomaticListen(
            voiceInitiated: voice, isQuiet: quiet, isForeground: foreground,
            isCurrent: current, succeeded: succeeded, isExecutingTools: executing
        )
    }

    @Test func onlyCurrentSuccessfulForegroundVoiceCanContinue() {
        var policy = FollowUpPolicy()
        #expect(!take(&policy))
        policy.beginVoiceTurn()
        #expect(!take(&policy, voice: false))
        #expect(!take(&policy, quiet: true))
        #expect(!take(&policy, foreground: false))
        #expect(!take(&policy, current: false))
        #expect(!take(&policy, succeeded: false))
        #expect(!take(&policy, executing: true))
        #expect(policy.automaticListensUsed == 0)
        #expect(take(&policy))
        policy.endVoiceTurn()
        #expect(!take(&policy))
        #expect(policy.automaticListensUsed == 1)
    }

    @Test func clarificationConfirmationAndAnswersShareThreeAllowances() {
        var policy = FollowUpPolicy()
        policy.beginVoiceTurn()
        // These are the three Home endings that request the SAME automatic-listen gate.
        let clarification = take(&policy)
        let confirmation = take(&policy)
        let answer = take(&policy)
        #expect(clarification && confirmation && answer)
        #expect(policy.automaticListensUsed == 3)
        #expect(!take(&policy))
        #expect(policy.automaticListensUsed == 3)
        policy.beginVoiceTurn() // Only an explicit new voice initiation resets the count.
        #expect(policy.automaticListensUsed == 0)
        #expect(take(&policy))
    }

    @Test func typedRequestsEndVoiceEligibilityWithoutResettingOrSpending() {
        var policy = FollowUpPolicy()
        policy.beginVoiceTurn()
        #expect(take(&policy))
        policy.endVoiceTurn() // A typed request must not replenish the voice allowance.
        #expect(!take(&policy, voice: false))
        #expect(!take(&policy))
        #expect(policy.automaticListensUsed == 1)
        policy.beginVoiceTurn()
        #expect(policy.automaticListensUsed == 0)
    }

    @Test(arguments: [
        "That’s all.", "that's all!", "thats all", "nothing else", "No, thanks.",
        "Thanks!", "thank you", "Bye.", "goodbye", "STOP!", "done",
        "Okay, Piko, that’s all!", "ok, no thanks, piko", "Piko, bye, okay.",
    ])
    func shortClosings(_ text: String) {
        #expect(FollowUpPolicy.isClosing(text))
    }

    @Test(arguments: [
        "", "Piko", "okay", "stop the timer", "thanks for reminding me to call Riya",
        "nothing else but the reminder", "bye, remind me tomorrow", "don't stop",
        "done with the calendar, now call Riya", "no thanks for the reminder, set a timer",
    ])
    func substantiveRequestsAndWrappersAloneAreNotClosings(_ text: String) {
        #expect(!FollowUpPolicy.isClosing(text))
    }
}
