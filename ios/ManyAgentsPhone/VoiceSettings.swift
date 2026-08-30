import Foundation
import Combine
import os

/// Which voice reads replies aloud, and the credentials for it.
///
/// The API key lives in the Keychain rather than UserDefaults — it's a
/// billable credential, and defaults land in unencrypted backups. Only the
/// voice choice, which is not a secret, is stored in defaults.
///
/// The key normally arrives from the paired Mac over the same sealed
/// channel as everything else, so there's nothing to type on a phone
/// keyboard. Pasting one in by hand still works, and a hand-typed key is
/// never overwritten by the Mac's.
@MainActor
final class VoiceSettings: ObservableObject {
    static let shared = VoiceSettings()

    enum Engine: String, CaseIterable, Identifiable {
        case onDevice, elevenLabs
        var id: String { rawValue }
        var label: String {
            switch self {
            case .onDevice:   return "This iPhone"
            case .elevenLabs: return "ElevenLabs"
            }
        }
    }

    /// Where a key came from. A key you pasted yourself outranks the Mac's,
    /// so a Mac that hasn't been given one can't wipe yours.
    enum KeySource: String { case none, mac, manual }

    private enum Keys {
        static let engine    = "voice.engine"
        static let voiceID   = "voice.elevenVoiceID"
        static let voiceName = "voice.elevenVoiceName"
        static let source    = "voice.keySource"
        static let account   = "elevenlabs.apiKey"      // Keychain account
        static let chat      = "anthropic.apiKey"       // Keychain account
    }

    /// ElevenLabs' own default voice ("Rachel"), so a key alone is enough
    /// to start talking.
    static let fallbackVoiceID = "21m00Tcm4TlvDq8ikWAM"
    /// Flash is the model for conversation: roughly a quarter the latency
    /// of Turbo at the same quality, which is the difference between a
    /// reply that lands and one you talk over.
    static let model = "eleven_flash_v2_5"

    @Published var engine: Engine {
        didSet { UserDefaults.standard.set(engine.rawValue, forKey: Keys.engine) }
    }
    @Published var voiceID: String {
        didSet { UserDefaults.standard.set(voiceID, forKey: Keys.voiceID) }
    }
    @Published var voiceName: String {
        didSet { UserDefaults.standard.set(voiceName, forKey: Keys.voiceName) }
    }
    /// Published so the settings screen reflects a key that arrived from
    /// the Mac while it was open.
    @Published private(set) var hasKey: Bool
    private(set) var keySource: KeySource

    private init() {
        let d = UserDefaults.standard
        engine = Engine(rawValue: d.string(forKey: Keys.engine) ?? "") ?? .elevenLabs
        voiceID = d.string(forKey: Keys.voiceID) ?? Self.fallbackVoiceID
        voiceName = d.string(forKey: Keys.voiceName) ?? "Default voice"
        keySource = KeySource(rawValue: d.string(forKey: Keys.source) ?? "") ?? .none
        hasKey = Keychain.string(Keys.account)?.isEmpty == false
    }

    var apiKey: String { Keychain.string(Keys.account) ?? "" }

    /// The key the on-phone companion thinks with. Same delivery as the
    /// voice key: typed once on the Mac, handed over sealed, kept in the
    /// Keychain here.
    var chatKey: String { Keychain.string(Keys.chat) ?? "" }
    @Published private(set) var hasChatKey: Bool = Keychain.string(Keys.chat)?.isEmpty == false

    func setChatKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        Keychain.set(trimmed.isEmpty ? nil : trimmed, for: Keys.chat)
        hasChatKey = !chatKey.isEmpty
    }

    private static let log = Logger(subsystem: "co.ailogy.manyagents.phone", category: "voice")

    /// Everything the speaker needs, or nil when we should use the phone's
    /// own voice — no key, or you asked for on-device.
    var elevenConfig: ElevenLabsSpeaker.Config? {
        guard engine == .elevenLabs else { return nil }
        let key = apiKey
        guard !key.isEmpty else { return nil }
        return .init(apiKey: key,
                     voiceID: voiceID.isEmpty ? Self.fallbackVoiceID : voiceID,
                     model: Self.model)
    }

    func setKeyManually(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        Keychain.set(trimmed.isEmpty ? nil : trimmed, for: Keys.account)
        keySource = trimmed.isEmpty ? .none : .manual
        UserDefaults.standard.set(keySource.rawValue, forKey: Keys.source)
        // Read back rather than assume. A Keychain write can be refused,
        // and reporting a key we haven't got means the app looks
        // configured and stays silent, which is the worst of both.
        hasKey = !apiKey.isEmpty
        Self.log.info("key set by hand: stored=\(self.hasKey)")
    }

    /// The Mac pushed its configuration. Takes it only when there's nothing
    /// here or when what's here also came from a Mac, so this stays a
    /// convenience and never a surprise overwrite.
    func adoptFromMac(key: String, voiceID id: String?, voiceName name: String?,
                      chatKey: String? = nil) {
        if let chatKey, !chatKey.isEmpty, chatKey != self.chatKey {
            Keychain.set(chatKey, for: Keys.chat)
            hasChatKey = !self.chatKey.isEmpty
            Self.log.info("chat key from Mac: stored=\(self.hasChatKey)")
        }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, keySource != .manual else { return }
        if trimmed != apiKey {
            Keychain.set(trimmed, for: Keys.account)
            hasKey = !apiKey.isEmpty
            Self.log.info("key from Mac: \(trimmed.count) chars, stored=\(self.hasKey)")
        }
        keySource = .mac
        UserDefaults.standard.set(keySource.rawValue, forKey: Keys.source)
        if let id, !id.isEmpty, id != voiceID { voiceID = id }
        if let name, !name.isEmpty { voiceName = name }
    }

    func forgetKey() {
        Keychain.set(nil, for: Keys.account)
        keySource = .none
        UserDefaults.standard.set(keySource.rawValue, forKey: Keys.source)
        hasKey = false
    }
}

/// Four lines of Security framework, wrapped so the call sites read as
/// what they mean.
enum Keychain {
    private static let service = "co.ailogy.manyagents.phone"

    static func string(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func set(_ value: String?, for account: String) -> OSStatus {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard let value, let data = value.data(using: .utf8) else { return errSecSuccess }
        var add = base
        add[kSecValueData as String] = data
        // Needs to be readable when the phone is locked in a pocket while
        // it reads a reply out over CarPlay.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(add as CFDictionary, nil)
        if status != errSecSuccess {
            Logger(subsystem: "co.ailogy.manyagents.phone", category: "voice")
                .error("keychain write failed: \(status)")
        }
        return status
    }
}
