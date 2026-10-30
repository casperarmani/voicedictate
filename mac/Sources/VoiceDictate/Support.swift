import Foundation
import Security

/// Monotonic clock in seconds.
@inline(__always) func now() -> Double {
    Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
}

// MARK: - Logging

/// File log at ~/Library/Logs/VoiceDictate/VoiceDictate.log (rotated at 2 MB), mirrored to stdout.
enum Log {
    private static let queue = DispatchQueue(label: "vd.log")
    private static let maxBytes = 2_000_000
    static let url: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/VoiceDictate", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("VoiceDictate.log")
    }()
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func info(_ msg: String) { write("INFO ", msg) }
    static func warn(_ msg: String) { write("WARN ", msg) }
    static func error(_ msg: String) { write("ERROR", msg) }
    static func debug(_ msg: String) { write("DEBUG", msg) }

    private static func write(_ level: String, _ msg: String) {
        let date = Date()
        queue.async {
            let line = "\(formatter.string(from: date)) \(level) \(msg)\n"
            FileHandle.standardOutput.write(line.data(using: .utf8)!)
            rotateIfNeeded()
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile()
                h.write(line.data(using: .utf8)!)
                try? h.close()
            } else {
                try? line.data(using: .utf8)!.write(to: url)
            }
        }
    }

    private static func rotateIfNeeded() {
        let fm = FileManager.default
        guard let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int,
              size > maxBytes else { return }
        let old = url.appendingPathExtension("1")
        try? fm.removeItem(at: old)
        try? fm.moveItem(at: url, to: old)
    }
}

// MARK: - Keychain

/// Stores the OpenAI API key in the login keychain.
enum Keychain {
    static let service = "VoiceDictate"
    static let account = "OPENAI_API_KEY"

    static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data,
              let key = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty else { return nil }
        return key
    }

    @discardableResult
    static func save(_ key: String) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let data = Data(key.utf8)
        let status = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return true }
        var add = base
        add[kSecValueData as String] = data
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        if addStatus != errSecSuccess { Log.error("[Keychain] Could not save key (\(status)/\(addStatus))") }
        return addStatus == errSecSuccess
    }

    /// Key from the environment (handy for command-line tests) or the keychain.
    static func apiKey() -> String? {
        if let env = ProcessInfo.processInfo.environment["OPENAI_API_KEY"], !env.isEmpty {
            return env
        }
        return load()
    }
}

// MARK: - Settings

struct DictationSettings: Equatable {
    var model = "gpt-live-transcribe"
    var delay = "low"                 // gpt-live-transcribe speed/accuracy: minimal, low, medium, high, xhigh
    var language = "en"
    var prompt = ""
    var vadThreshold: Float = 0.5     // Silero speech probability needed to start speech
    var silenceMs = 250               // trailing silence that ends an utterance
    var minSpeechMs = 200             // shorter blips (coughs, clicks) are discarded
    var prefixMs = 500                // audio kept from before speech started
    var autoPaste = true
    var restoreClipboard = true
    var sendCommand = true            // saying just "send" presses Enter
    var preferBuiltInMic = true
    // OpenAI's noise reduction clips "s" sounds on short words ("send" -> "and"), and our own
    // speech detector already keeps background noise from being sent, so it's off by default.
    var noiseReduction = "off"        // auto, far_field, near_field, off

    static let models = ["gpt-live-transcribe", "gpt-transcribe", "gpt-4o-mini-transcribe"]
    static let delays = ["minimal", "low", "medium", "high", "xhigh"]

    enum Key {
        static let model = "model", delay = "delay", language = "language", prompt = "prompt"
        static let vadThreshold = "vadThreshold", silenceMs = "silenceMs", minSpeechMs = "minSpeechMs"
        static let prefixMs = "prefixMs", autoPaste = "autoPaste", restoreClipboard = "restoreClipboard"
        static let sendCommand = "sendCommand"
        static let preferBuiltInMic = "preferBuiltInMic", noiseReduction = "noiseReduction"
    }

    static func load(_ d: UserDefaults = .standard) -> DictationSettings {
        var s = DictationSettings()
        if let v = d.string(forKey: Key.model), models.contains(v) { s.model = v }
        if let v = d.string(forKey: Key.delay), delays.contains(v) { s.delay = v }
        if let v = d.string(forKey: Key.language) { s.language = v }
        if let v = d.string(forKey: Key.prompt) { s.prompt = v }
        if d.object(forKey: Key.vadThreshold) != nil { s.vadThreshold = d.float(forKey: Key.vadThreshold) }
        if d.object(forKey: Key.silenceMs) != nil { s.silenceMs = d.integer(forKey: Key.silenceMs) }
        if d.object(forKey: Key.minSpeechMs) != nil { s.minSpeechMs = d.integer(forKey: Key.minSpeechMs) }
        if d.object(forKey: Key.prefixMs) != nil { s.prefixMs = d.integer(forKey: Key.prefixMs) }
        if d.object(forKey: Key.autoPaste) != nil { s.autoPaste = d.bool(forKey: Key.autoPaste) }
        if d.object(forKey: Key.restoreClipboard) != nil { s.restoreClipboard = d.bool(forKey: Key.restoreClipboard) }
        if d.object(forKey: Key.sendCommand) != nil { s.sendCommand = d.bool(forKey: Key.sendCommand) }
        if d.object(forKey: Key.preferBuiltInMic) != nil { s.preferBuiltInMic = d.bool(forKey: Key.preferBuiltInMic) }
        if let v = d.string(forKey: Key.noiseReduction) { s.noiseReduction = v }
        s.vadThreshold = min(max(s.vadThreshold, 0.1), 0.95)
        s.silenceMs = min(max(s.silenceMs, 100), 3000)
        s.minSpeechMs = min(max(s.minSpeechMs, 0), 2000)
        s.prefixMs = min(max(s.prefixMs, 0), 1500)
        return s
    }

    /// True when a whole utterance is just "send" (or a common mishearing of it).
    /// "Send me the logs" doesn't count: only the word on its own.
    static func isSendCommand(_ text: String) -> Bool {
        let letters = String(text.lowercased().map { $0.isLetter ? $0 : " " })
        let words = letters.split(separator: " ").joined(separator: " ")
        return ["send", "sent", "sand", "send it", "sent it", "end"].contains(words)
    }

    /// ISO-639-1 code to send, or nil for auto-detect (blank or not a 2-letter code).
    var languageCode: String? {
        let l = language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return l.count == 2 && l.allSatisfy({ $0.isLetter && $0.isASCII }) ? l : nil
    }

    /// Settings that require a new OpenAI session when changed.
    func sessionDiffers(from o: DictationSettings) -> Bool {
        model != o.model || delay != o.delay || languageCode != o.languageCode
            || prompt != o.prompt || noiseReduction != o.noiseReduction
    }
}
