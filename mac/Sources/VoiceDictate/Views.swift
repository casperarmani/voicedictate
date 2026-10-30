import ServiceManagement
import SwiftUI

struct VoiceDictateApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        Window("Voice Dictate", id: "main") {
            MainView()
                .environmentObject(state)
                .frame(minWidth: 460, minHeight: 560)
        }
        .windowResizability(.contentMinSize)

        MenuBarExtra {
            MenuContent().environmentObject(state)
        } label: {
            Image(systemName: state.wantsListening ? "mic.fill" : "mic.slash")
        }
    }
}

struct MenuContent: View {
    @EnvironmentObject var state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(statusTitle(state))
        Button(state.wantsListening ? "Pause Listening" : "Start Listening") { state.toggle() }
        Divider()
        Button("Open Voice Dictate") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Quit") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

@MainActor func statusTitle(_ state: AppState) -> String {
    if let m = state.fatalMessage { return m }
    if !state.hasAPIKey { return "Add your OpenAI API key" }
    if state.wantsListening && !state.micGranted { return "Microphone access needed" }
    switch state.status {
    case .stopped: return "Paused"
    case .connecting: return "Connecting…"
    case .listening: return state.speaking ? "Hearing you…" : "Listening"
    case .reconnecting: return "Reconnecting…"
    case .error(let e): return e
    }
}

struct MainView: View {
    @EnvironmentObject var state: AppState
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if needsSetup { setup; Divider() }
            transcripts
            Divider()
            DisclosureGroup("Settings", isExpanded: $showSettings) { SettingsView() }
                .padding(14)
        }
    }

    private var needsSetup: Bool {
        !state.hasAPIKey || !state.micGranted || !state.accessibilityGranted || !state.micKeyActive
    }

    private var color: Color {
        guard state.wantsListening else { return .secondary }
        switch state.status {
        case .listening: return .red
        case .connecting, .reconnecting: return .orange
        case .error: return .yellow
        case .stopped: return .secondary
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle().fill(color.opacity(0.18)).frame(width: 64, height: 64)
                    .scaleEffect(state.speaking ? 1.15 : 1)
                    .animation(.easeOut(duration: 0.2), value: state.speaking)
                Image(systemName: state.wantsListening ? "mic.fill" : "mic.slash.fill")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(color)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(statusTitle(state)).font(.title2.weight(.semibold)).lineLimit(2)
                Text(state.wantsListening ? "Speak anywhere — text is typed where your cursor is."
                                          : "Press F5 or the button to start.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button(state.wantsListening ? "Pause" : "Start") { state.toggle() }
                .controlSize(.large)
                .disabled(!state.hasAPIKey)
        }
        .padding(18)
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !state.hasAPIKey { APIKeyField() }
            if !state.micGranted {
                SetupRow(ok: false, title: "Microphone access", detail: "Needed to hear you.",
                         action: "Open Settings") { Permissions.openMicrophoneSettings() }
            }
            if !state.accessibilityGranted {
                SetupRow(ok: false, title: "Accessibility access",
                         detail: "Needed to paste text and use the F5 key. Turn on Voice Dictate in the list.",
                         action: "Open Settings") { Permissions.openAccessibilitySettings() }
            } else if !state.micKeyActive {
                SetupRow(ok: false, title: "F5 key not active",
                         detail: "Quit and reopen Voice Dictate after granting Accessibility.",
                         action: nil, perform: {})
            }
        }
        .padding(14)
        .background(Color.yellow.opacity(0.08))
    }

    private var transcripts: some View {
        Group {
            if state.recent.isEmpty {
                VStack(spacing: 6) {
                    Spacer()
                    Text("Nothing dictated yet").foregroundStyle(.secondary)
                    Text("Tip: turn off Apple's Dictation shortcut in Keyboard settings so only Voice Dictate uses F5.")
                        .font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center)
                        .padding(.horizontal, 30)
                    Button("Keyboard Settings…") { Permissions.openKeyboardSettings() }
                        .buttonStyle(.link).font(.caption)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                List(state.recent) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.text).textSelection(.enabled)
                        HStack(spacing: 8) {
                            Text(entry.date, style: .time)
                            if let ms = entry.latencyMs { Text("\(Int(ms)) ms") }
                        }
                        .font(.caption2).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
                .listStyle(.inset)
            }
        }
        .frame(maxHeight: .infinity)
    }
}

struct SetupRow: View {
    let ok: Bool
    let title: String
    let detail: String
    let action: String?
    let perform: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(ok ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let action { Button(action, action: perform) }
        }
    }
}

struct APIKeyField: View {
    @EnvironmentObject var state: AppState
    @State private var key = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(state.hasAPIKey ? "Replace OpenAI API key" : "OpenAI API key").fontWeight(.medium)
            HStack {
                SecureField("sk-…", text: $key).textFieldStyle(.roundedBorder)
                Button("Save") { state.saveAPIKey(key); key = "" }.disabled(key.isEmpty)
            }
            Text(state.keySaveFailed ? "Couldn't save to the Keychain; it will be forgotten when the app quits."
                                     : "Stored in your macOS Keychain.")
                .font(.caption).foregroundStyle(state.keySaveFailed ? .orange : .secondary)
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var state: AppState
    typealias K = DictationSettings.Key
    private static let d = DictationSettings()

    @AppStorage(K.model) private var model = d.model
    @AppStorage(K.delay) private var delay = d.delay
    @AppStorage(K.language) private var language = d.language
    @AppStorage(K.prompt) private var prompt = d.prompt
    @AppStorage(K.vadThreshold) private var threshold = Double(d.vadThreshold)
    @AppStorage(K.silenceMs) private var silenceMs = d.silenceMs
    @AppStorage(K.autoPaste) private var autoPaste = d.autoPaste
    @AppStorage(K.restoreClipboard) private var restoreClipboard = d.restoreClipboard
    @AppStorage(K.sendCommand) private var sendCommand = d.sendCommand
    @AppStorage(K.noiseReduction) private var noiseReduction = d.noiseReduction
    @AppStorage(K.preferBuiltInMic) private var builtIn = d.preferBuiltInMic

    var body: some View {
        Form {
            Picker("Model", selection: $model) {
                ForEach(DictationSettings.models, id: \.self) { Text($0) }
            }
            if model == "gpt-live-transcribe" {
                Picker("Speed vs accuracy", selection: $delay) {
                    ForEach(DictationSettings.delays, id: \.self) { Text($0) }
                }
            }
            TextField("Language (blank = auto)", text: $language)
            TextField("Vocabulary hint (optional)", text: $prompt)
            Stepper("Pause before sending: \(silenceMs) ms", value: $silenceMs, in: 100...2000, step: 50)
            HStack {
                Text("Speech sensitivity")
                Slider(value: $threshold, in: 0.2...0.9)
                Text(String(format: "%.2f", threshold)).monospacedDigit().frame(width: 36)
            }
            Toggle("Use built-in microphone", isOn: $builtIn)
            Toggle("OpenAI noise reduction (can drop \"s\" sounds on short words)", isOn: Binding(
                get: { noiseReduction != "off" }, set: { noiseReduction = $0 ? "auto" : "off" }))
            Toggle("Paste automatically", isOn: $autoPaste)
            Toggle("Restore my clipboard after pasting", isOn: $restoreClipboard)
            Toggle("Say \"send\" on its own to press Enter", isOn: $sendCommand)
            Toggle("Open at login", isOn: Binding(
                get: { state.launchAtLogin }, set: { state.setLaunchAtLogin($0) }))
            if state.launchNeedsApproval {
                Button("Approve in Login Items settings…") { SMAppService.openSystemSettingsLoginItems() }
                    .buttonStyle(.link).font(.caption)
            }
            if state.hasAPIKey { APIKeyField() }
            Button("Show log file") { NSWorkspace.shared.activateFileViewerSelecting([Log.url]) }
                .buttonStyle(.link)
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }
}
