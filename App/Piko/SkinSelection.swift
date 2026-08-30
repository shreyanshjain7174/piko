import PikoKit

enum SkinSelection {
    static func apply(_ skin: Skin, via channel: any SessionChannel) {
        var state = channel.readState() ?? SessionState()
        state.skin = skin
        channel.writeState(state)
    }
}
