import Foundation
import PikoKit
import RealityKit
import Testing
import UIKit
@testable import Piko

@Suite("Native companion interactions", .serialized)
@MainActor
struct PikoCompanionInteractionTests {
    private func withPet(
        reduceMotion: Bool = false,
        _ body: @MainActor (PikoPetSurface) async throws -> Void
    ) async throws {
        let scene = try #require(UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        window.rootViewController = controller
        let pet = PikoPetSurface(frame: CGRect(x: 0, y: 0, width: 172, height: 215))
        controller.view.addSubview(pet)
        window.isHidden = false
        defer {
            pet.shutdown()
            window.isHidden = true
        }
        pet.configure(activity: .idle, loudness: 0, isActive: true,
                      room: .clear, reduceMotion: reduceMotion, onPat: {})
        try await body(pet)
    }

    @Test("An idle pat gives brief accessibility feedback, including with Reduce Motion",
          arguments: [false, true])
    func patFeedback(reduceMotion: Bool) async throws {
        try await withPet(reduceMotion: reduceMotion) { pet in
            #expect(pet.accessibilityValue == "Quietly here")
            #expect(pet.accessibilityActivate())
            #expect(pet.accessibilityValue == "Enjoying a pat")
            for _ in 0..<30 where pet.accessibilityValue != "Quietly here" {
                try await Task.sleep(for: .milliseconds(100))
            }
            #expect(pet.accessibilityValue == "Quietly here")
        }
    }

    @Test("Listening, thinking, speech and completion retain priority over a pat",
          arguments: [PikoPetActivity.listening, .thinking, .speaking, .happy])
    func busyStatesKeepPriority(_ activity: PikoPetActivity) async throws {
        try await withPet { pet in
            pet.configure(activity: activity, loudness: 0.5, isActive: true,
                          room: .clear, reduceMotion: false, onPat: {})
            let status = pet.accessibilityValue
            #expect(pet.accessibilityActivate())
            #expect(pet.accessibilityValue == status)
        }
    }

    @Test("Offscreen rendering tears down and reactivation restores interaction")
    func visibilityAndTeardown() async throws {
        try await withPet { pet in
            #expect(pet.subviews.contains { $0 is ARView })
            #expect(pet.accessibilityActivate())
            #expect(pet.accessibilityValue == "Enjoying a pat")
            pet.configure(activity: .idle, loudness: 0.1, isActive: true,
                          room: .clear, reduceMotion: false, onPat: {})
            #expect(pet.accessibilityValue == "Enjoying a pat")
            var pats = 0
            pet.configure(activity: .idle, loudness: 0, isActive: false,
                          room: .clear, reduceMotion: false, onPat: { pats += 1 })
            #expect(!pet.subviews.contains { $0 is ARView })
            #expect(!pet.accessibilityActivate())
            #expect(pats == 0)
            #expect(pet.accessibilityValue == "Quietly here")
            pet.configure(activity: .idle, loudness: 0, isActive: true,
                          room: .clear, reduceMotion: false, onPat: { pats += 1 })
            #expect(pet.subviews.contains { $0 is ARView })
            #expect(pet.accessibilityValue == "Quietly here")
            #expect(pet.accessibilityActivate())
            #expect(pats == 1)
            pet.shutdown()
            #expect(!pet.subviews.contains { $0 is ARView })
            #expect(!pet.accessibilityActivate())
            #expect(pats == 1)
        }
    }

    #if targetEnvironment(simulator)
    @Test("Enabling Quiet stops an active celebration without hiding the real outcome")
    func quietStopsCelebration() async throws {
        guard case .success(let app) = AppComposition.shared else {
            Issue.record("The real app composition did not start")
            return
        }
        let defaults = UserDefaults.standard
        let stored = defaults.object(forKey: PikoCompanionStore.preferencesKey)
        let model = HomeViewModel(app: app)
        defer {
            model.setCompanionActive(false)
            if let stored {
                defaults.set(stored, forKey: PikoCompanionStore.preferencesKey)
            } else {
                defaults.removeObject(forKey: PikoCompanionStore.preferencesKey)
            }
        }
        model.setQuietMode(false)
        model.resetCompanionLearning()
        model.setCompanionActive(true)
        let marker = "companion interaction \(UUID().uuidString)"
        #expect(await model.submitTypedRequest("Make a note \(marker)"))
        #expect(model.isCelebrating)
        let outcome = model.assistant
        model.setQuietMode(true)
        #expect(!model.isCelebrating)
        #expect(model.assistant == outcome)
        #expect(model.phase != .capturing)
        for result in await app.memory.search(marker, limit: 5)
        where result.raw == "Make a note \(marker)" {
            await app.memory.delete(result.id)
        }
    }
    #endif
}
