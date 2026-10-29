#if os(iOS)
import AVFAudio
import PikoKit

@MainActor
public struct AudioSessionAccess {
    let activate: () throws -> Void
    let deactivate: () throws -> Void

    public init(activate: @escaping () throws -> Void, deactivate: @escaping () throws -> Void) {
        self.activate = activate
        self.deactivate = deactivate
    }

    public static var system: AudioSessionAccess {
        AudioSessionAccess(
            activate: {
                guard AVAudioApplication.shared.recordPermission == .granted else {
                    throw PikoError.microphoneDenied
                }
                let session = AVAudioSession.sharedInstance()
                do {
                    try session.setCategory(.playAndRecord, options: [.allowBluetoothHFP, .defaultToSpeaker])
                    try session.setActive(true)
                } catch {
                    throw PikoError.audioUnavailable
                }
            },
            deactivate: { try AVAudioSession.sharedInstance().setActive(false) }
        )
    }
}
#endif
