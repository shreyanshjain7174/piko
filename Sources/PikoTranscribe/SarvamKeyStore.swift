import Foundation
#if os(iOS)
import PikoKit

/// Typed facade over `KeychainStore.Item.sarvamAPIKey`. All callers go through here —
/// no other file ever spells the storage key. This is what Settings writes to,
/// what `AppComposition` reads at engine-construction time, and what a
/// "clear key" tap in Settings destroys.
public enum SarvamKeyStore {

    /// Returns the currently stored key, or nil when absent. Keychain failures
    /// degrade to nil — the caller is expected to treat "no key" and "key
    /// unreachable" the same way at the user-visible layer.
    public static func read() -> String? {
        switch KeychainStore.read(.sarvamAPIKey) {
        case .success(let value): return value?.isEmpty == true ? nil : value
        case .failure: return nil
        }
    }

    /// Writes a new key, or clears the stored value when `key` is empty. The
    /// return value is the effective state after the write ("key present" /
    /// "cleared") so the UI can react without a second read.
    @discardableResult
    public static func write(_ key: String) -> WriteOutcome {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            _ = KeychainStore.delete(.sarvamAPIKey)
            return .cleared
        }
        switch KeychainStore.write(trimmed, to: .sarvamAPIKey) {
        case .success: return .stored
        case .failure(let error): return .failed(error)
        }
    }

    public enum WriteOutcome: Sendable, Equatable {
        case stored
        case cleared
        case failed(KeychainStore.KeychainError)
    }
}
#endif
