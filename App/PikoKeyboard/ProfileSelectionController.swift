import PikoKit

/// Mutates only `SessionState.profile` on a live channel. Does not invent phase
/// or heartbeat when no state exists — profile belongs to a known session.
struct ProfileSelectionController: Sendable {
    /// Picker source of truth. KeyboardView iterates the same `Profile.allCases`.
    static var pickerProfiles: [Profile] { Array(Profile.allCases) }

    private let channel: any SessionChannel

    init(channel: any SessionChannel) {
        self.channel = channel
    }

    func select(_ profile: Profile) {
        guard var state = channel.readState() else { return }
        state.profile = profile
        channel.writeState(state)
    }
}
