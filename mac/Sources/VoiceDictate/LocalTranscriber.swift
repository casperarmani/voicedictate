import FluidAudio
import Foundation

/// On-device speech-to-text with NVIDIA Parakeet TDT 0.6B v2 (Core ML, Neural Engine) via
/// FluidAudio. One finished utterance in (16 kHz mono floats), text out in ~40 ms.
/// The model (~440 MB) downloads once to ~/Library/Application Support/FluidAudio/Models.
final class LocalTranscriber {
    enum State: Equatable { case idle, loading, ready, failed(String) }

    /// Called on the main queue whenever the state changes.
    var onState: ((State) -> Void)?
    private(set) var state: State = .idle {
        didSet { let s = state; DispatchQueue.main.async { self.onState?(s) } }
    }

    private var asr: AsrManager?
    private var decoderLayers = 0
    private let lock = NSLock()

    var isReady: Bool { lock.withLock { state == .ready } }
    var currentState: State { lock.withLock { state } }
    private var lastAttemptAt = -Double.infinity

    /// Loads the model (downloading it the first time). Safe to call repeatedly.
    func prepare() {
        let shouldLoad: Bool = lock.withLock {
            switch state {
            case .idle: break
            // After a failure (e.g. offline first launch), retry at most every 30 s
            // instead of on every sentence.
            case .failed where now() - lastAttemptAt > 30: break
            default: return false
            }
            state = .loading
            lastAttemptAt = now()
            return true
        }
        guard shouldLoad else { return }
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let t0 = now()
            do {
                Log.info("[Local] Loading Parakeet model (downloads ~440 MB the first time)…")
                let models = try await AsrModels.downloadAndLoad(version: .v2)
                let asr = AsrManager(config: .default)
                try await asr.loadModels(models)
                let layers = await asr.decoderLayerCount
                // Warm-up so the first real sentence isn't slow.
                var st = TdtDecoderState.make(decoderLayers: layers)
                _ = try? await asr.transcribe([Float](repeating: 0, count: 16000), decoderState: &st)
                self.lock.withLock {
                    self.asr = asr
                    self.decoderLayers = layers
                    self.state = .ready
                }
                Log.info(String(format: "[Local] Parakeet ready in %.1f s", now() - t0))
            } catch {
                Log.error("[Local] Could not load Parakeet: \(error.localizedDescription)")
                self.lock.withLock { self.state = .failed(error.localizedDescription) }
            }
        }
    }

    /// Transcribes one utterance. Throws if the model isn't loaded.
    func transcribe(_ samples: [Float]) async throws -> String {
        let (asr, layers): (AsrManager?, Int) = lock.withLock { (self.asr, self.decoderLayers) }
        guard let asr else {
            throw NSError(domain: "VoiceDictate", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Speech model not loaded"])
        }
        // Very short clips (a lone "send") are more reliable with a little trailing silence.
        var audio = samples
        if audio.count < 16000 { audio += [Float](repeating: 0, count: 16000 - audio.count) }
        var st = TdtDecoderState.make(decoderLayers: layers)
        return try await asr.transcribe(audio, decoderState: &st).text
    }

    /// Parakeet sometimes starts lowercase or skips the final period; tidy that up so pasted
    /// text looks like OpenAI's output did.
    static func tidy(_ raw: String) -> String {
        var text = raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard let first = text.first else { return text }
        if first.isLowercase { text = first.uppercased() + text.dropFirst() }
        if let last = text.last, last.isLetter || last.isNumber { text += "." }
        return text
    }
}
