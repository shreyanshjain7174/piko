import Foundation
#if os(iOS)
import Security
import PikoKit

/// Small, focused wrapper over the App Group Keychain for secrets that must not
/// touch UserDefaults, Info.plist, or the repo. Read/write from the container app
/// only; extensions never need these values (the keyboard is a remote control, and
/// the widgets only render).
///
/// This is intentionally not a general-purpose Keychain library — it stores strings
/// keyed by an item name, scoped to Piko's App Group so container-app + main-app
/// installs on the same device see the same value.
public enum KeychainStore {

    public enum Item: String, Sendable {
        /// The user-provided Sarvam API key. Present only when the user has opted
        /// into cloud transcription and entered a key in Settings.
        case sarvamAPIKey = "dev.piko.sarvam.apiKey"
    }

    public enum KeychainError: Error, Sendable, Equatable {
        case unavailable
        case osStatus(Int32)
    }

    /// Read a stored string, or nil if the item does not exist.
    public static func read(_ item: Item) -> Result<String?, KeychainError> {
        let query = baseQuery(item, forRead: true)
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        switch status {
        case errSecSuccess:
            guard let data = out as? Data,
                  let value = String(data: data, encoding: .utf8) else {
                return .success(nil)
            }
            return .success(value)
        case errSecItemNotFound:
            return .success(nil)
        default:
            return .failure(.osStatus(status))
        }
    }

    /// Write or overwrite a stored string. Passing an empty string is treated as
    /// a delete — a paste-in field that was cleared should not leave a phantom
    /// entry behind.
    @discardableResult
    public static func write(_ value: String, to item: Item) -> Result<Void, KeychainError> {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return delete(item) }
        guard let data = trimmed.data(using: .utf8) else {
            return .failure(.osStatus(errSecParam))
        }

        let updateQuery = baseQuery(item, forRead: false)
        let attributes: [CFString: Any] = [kSecValueData: data]
        let updateStatus = SecItemUpdate(updateQuery as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return .success(()) }
        if updateStatus != errSecItemNotFound {
            return .failure(.osStatus(updateStatus))
        }

        var addQuery = baseQuery(item, forRead: false)
        addQuery[kSecValueData] = data
        addQuery[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        return addStatus == errSecSuccess ? .success(()) : .failure(.osStatus(addStatus))
    }

    /// Remove a stored item. Returns success even when the item was already absent.
    @discardableResult
    public static func delete(_ item: Item) -> Result<Void, KeychainError> {
        let query = baseQuery(item, forRead: false)
        let status = SecItemDelete(query as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound {
            return .success(())
        }
        return .failure(.osStatus(status))
    }

    private static func baseQuery(_ item: Item, forRead: Bool) -> [CFString: Any] {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: item.rawValue,
            kSecAttrAccount: item.rawValue,
        ]
        // Access group binds this item to Piko's App Group Keychain, so a future
        // extension needing the same secret would see it — today only the container
        // app writes or reads.
        query[kSecAttrAccessGroup] = AppGroup.identifier as CFString
        if forRead {
            query[kSecReturnData] = kCFBooleanTrue as CFTypeRef
            query[kSecMatchLimit] = kSecMatchLimitOne
        }
        return query
    }
}
#endif
