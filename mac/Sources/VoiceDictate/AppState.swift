import AVFoundation
import AppKit
import ServiceManagement
import SwiftUI

struct TranscriptEntry: Identifiable {
    let id = UUID()
    let text: String
    let latencyMs: Double?
    let date = Date()
}

@MainActor
final class AppState: ObservableObject {
    @Published var status: EngineStatus = .stopped
    @Published var wantsListening = false
    @Published var speaking = false
    @Published var recent: [TranscriptEntry] = []
    @Published var hasAPIKey = false
    @Published var usesOpenAI = DictationSettings.load().engine == "openai"
    /// An API key is only required when transcribing with OpenAI.
    var needsAPIKey: Bool { usesOpenAI && !hasAPIKey }
    @Published var micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    @Published var accessibilityGranted = Permissions.accessibility
    @Published var micKeyActive = false
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var launchNeedsApproval = SMAppService.mainApp.status == .requiresApproval
    @Published var keySaveFailed = false
    @Published var fatalMessage: String?

    private var engine: DictationEngine?
    private let paster = Paster()
    private let micKey = MicKeyMonitor()
    private var settings = DictationSettings.load()
    private var pollTimer: Timer?
    private var settingsDebounce: DispatchWorkItem?
    private var apiKey: String?

    init() {
        micKey.onPress = { [weak self] in self?.toggle() }

        // build.sh passes the key from .env at launch; keep a copy in the Keychain so later
        // launches (Dock, login) have it. Items the app writes itself never prompt.
        let stored = Keychain.load()
        if let env = ProcessInfo.processInfo.environment["OPENAI_API_KEY"], !env.isEmpty {
            if env != stored { Keychain.save(env) }
            apiKey = env
        } else {
            apiKey = stored
        }
        hasAPIKey = apiKey != nil

        guard let url = SileroVAD.bundledModelURL(), let vad = try? SileroVAD(modelURL: url) else {
            fatalMessage = "The speech detector model is missing from the app bundle. Rebuild with mac/build.sh."
            return
        }
        let engine = DictationEngine(apiKey: apiKey ?? "", settings: settings, vad: vad)
        engine.onStatus = { [weak self] s in self?.status = s }
        engine.onSpeaking = { [weak self] s in self?.speaking = s }
        engine.onTranscript = { [weak self] text, latency in self?.deliver(text, latency) }
        self.engine = engine

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.engine?.handleWake() }
        }
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.scheduleSettingsCheck() }
        }

        if !accessibilityGranted { Permissions.promptAccessibility() }
        startMicKeyIfPossible()
        // Permissions can be granted while the app runs; pick that up without a relaunch.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshPermissions() }
        }

        // Like the old script: opening the app starts listening.
        start()
    }

    // MARK: - Controls

    func toggle() { wantsListening ? stop() : start() }

    func start() {
        guard let engine else { return }
        guard !needsAPIKey else { wantsListening = false; return }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            micGranted = true
            wantsListening = true
            engine.start()
            NSSound(named: "Pop")?.play()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Task { @MainActor in
                    self.micGranted = granted
                    if granted { self.start() }
                }
            }
        default:
            micGranted = false
            wantsListening = false
        }
    }

    func stop() {
        wantsListening = false
        engine?.stop()
        NSSound(named: "Pop")?.play()
    }

    func saveAPIKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        keySaveFailed = !Keychain.save(trimmed)
        apiKey = trimmed
        hasAPIKey = true
        engine?.update(settings: settings, apiKey: trimmed)
        if !wantsListening { start() }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            Log.warn("[Login] \(error.localizedDescription)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
        launchNeedsApproval = SMAppService.mainApp.status == .requiresApproval
        if launchNeedsApproval { SMAppService.openSystemSettingsLoginItems() }
    }

    // MARK: - Internals

    private func deliver(_ text: String, _ latency: Double?) {
        let isSend = settings.sendCommand && settings.autoPaste && DictationSettings.isSendCommand(text)
        recent.insert(TranscriptEntry(text: isSend ? "⏎ Enter" : text, latencyMs: latency), at: 0)
        if recent.count > 30 { recent.removeLast(recent.count - 30) }
        if isSend {
            Log.info("[Paste] Heard \"\(text)\" → pressing Enter")
            paster.pressEnter()
        } else {
            paster.deliver(text, autoPaste: settings.autoPaste, restoreClipboard: settings.restoreClipboard)
        }
    }

    /// Text fields write on every keystroke; wait until typing pauses before applying.
    private func scheduleSettingsCheck() {
        settingsDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.settingsChanged() }
        settingsDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    private func settingsChanged() {
        let new = DictationSettings.load()
        guard new != settings else { return }
        settings = new
        usesOpenAI = new.engine == "openai"
        engine?.update(settings: new, apiKey: apiKey ?? "")
    }

    private func refreshPermissions() {
        let wasGranted = accessibilityGranted
        accessibilityGranted = Permissions.accessibility
        if wasGranted && !accessibilityGranted { micKey.stop() }
        launchAtLogin = SMAppService.mainApp.status == .enabled
        launchNeedsApproval = SMAppService.mainApp.status == .requiresApproval
        micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        startMicKeyIfPossible()
        micKeyActive = micKey.isActive
    }

    private func startMicKeyIfPossible() {
        if accessibilityGranted { micKey.start() }
        micKeyActive = micKey.isActive
    }
}
