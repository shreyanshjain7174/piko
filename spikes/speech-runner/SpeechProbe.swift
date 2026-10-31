import Foundation
import Speech

@main
struct SpeechProbe {
    static func main() async {
        let status = SFSpeechRecognizer.authorizationStatus()
        let statusName: String
        switch status {
        case .notDetermined: statusName = "notDetermined"
        case .denied: statusName = "denied"
        case .restricted: statusName = "restricted"
        case .authorized: statusName = "authorized"
        @unknown default: statusName = "unknown(\(status.rawValue))"
        }
        print("authorizationStatus=\(statusName)")
        print("authorizationRequest=not attempted (non-interactive; request behavior cannot be determined)")
        for identifier in ["en-US", "en-IN"] {
            let recognizer = SFSpeechRecognizer(locale: Locale(identifier: identifier))
            print("\(identifier) recognizerExists=\(recognizer != nil) supportsOnDeviceRecognition=\(recognizer.map { String($0.supportsOnDeviceRecognition) } ?? "not determined")")
        }
        if #available(macOS 26.0, iOS 26.0, *) {
            print("SpeechTranscriber.isAvailable=\(SpeechTranscriber.isAvailable)")
            for identifier in ["en-US", "en-IN"] {
                let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: identifier))
                print("\(identifier) SpeechTranscriber.supportedLocale=\(locale?.identifier ?? "none")")
            }
        } else {
            print("SpeechTranscriber=unavailable on this OS")
        }
    }
}
