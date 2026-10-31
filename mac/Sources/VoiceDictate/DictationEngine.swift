import Foundation

enum EngineStatus: Equatable {
    case stopped
    case connecting
    case loadingModel
    case listening
    case reconnecting(String)
    case error(String)
}

/// Always-on dictation pipeline:
///   mic (16 kHz) -> Silero VAD endpointer -> transcription -> ordered transcripts.
///
/// Transcription runs either on this Mac (Parakeet via FluidAudio, the default) or on
/// OpenAI Realtime (manual commit). For OpenAI, only speech (plus a short pre-roll) is sent, and each utterance's audio is kept
/// until its transcript arrives, so if the socket drops or rotates, unfinished utterances
/// are replayed into the next session instead of being lost.
///
/// Everything below runs on `queue`.
final class DictationEngine {
    // Reliability tuning (carried over from the Python version).
    static let sessionRecycleSec = 20.0 * 60    // rotate at this age when idle
    static let sessionMaxAgeSec = 28.0 * 60     // rotate even when busy (replay makes it lossless)
    static let idleQuietSec = 2.0
    static let configureTimeoutSec = 15.0
    static let staleTranscriptSec = 20.0        // give up on an utterance with no transcript
    static let staleReplaySec = 20.0            // don't replay speech older than this after an outage
    static let backoffInitial = 0.5
    static let backoffMax = 8.0                 // stays well inside staleReplaySec
    static let pausedDisconnectSec = 120.0      // drop the idle socket this long after pausing

    let queue = DispatchQueue(label: "vd.engine", qos: .userInteractive)

    // Callbacks are delivered on the main queue.
    var onStatus: ((EngineStatus) -> Void)?
    var onTranscript: ((String, Double?) -> Void)?   // text, ms from end of speech to text
    var onSpeaking: ((Bool) -> Void)?

    private var settings: DictationSettings
    private var apiKey: String
    private let vad: SileroVAD
    private let resampler = Resampler()
    private let capture = AudioCapture()
    let local = LocalTranscriber()
    private var useLocal: Bool { settings.engine == "local" }
    private var captureEnabled = true

    // Endpointer state
    private var listening = false
    private var residual: [Float] = []
    private var preroll: [(pcm: Data, raw: [Float])] = []
    private var inSpeech = false
    private var speechChunks = 0
    private var silenceChunks = 0
    private var lastSpeechAt = 0.0
    private var stoppedAt = 0.0

    // Self-healing: restart the mic if it goes quiet, and report if the engine queue hangs.
    static let audioStallSec = 3.0              // no samples at all for this long -> restart mic
    static let engineStallSec = 5.0             // engine queue unresponsive this long -> log it
    private var lastAudioAt = 0.0
    private var lastBadAudioWarn = -Double.infinity
    private let beatLock = NSLock()
    private var lastBeat = now()                // updated by tick(); guarded by beatLock
    private var watchdog: DispatchSourceTimer?

    // Utterances
    private final class Utterance {
        let seq: Int
        var audio = Data()              // 24 kHz PCM16, for OpenAI (and replay)
        var samples: [Float] = []       // 16 kHz float, for the local model
        var lastAudioAt = now()
        var committedAt: Double?
        var speechEndAt: Double?
        var itemId: String?
        var commitEventId: String?
        var transcript: String?
        var failed = false
        init(seq: Int) { self.seq = seq }
    }
    private var nextSeq = 1
    private var current: Utterance?
    private var pending: [Utterance] = []       // committed, in order, waiting for transcripts
    private var awaitingAck: [Utterance] = []   // commits sent on this session, oldest first

    // Session state
    private var conn: RealtimeConnection?
    private var connReady = false
    private var sessionStartedAt = 0.0
    private var generation = 0
    private var backoff = DictationEngine.backoffInitial
    private var reconnectScheduled = false
    private var fatal = false
    private var configError: String?            // OpenAI rejected our session settings
    private var reconnectToken = 0
    private var restartPending = false
    private var timer: DispatchSourceTimer?
    private var lastStatus: EngineStatus = .stopped

    init(apiKey: String, settings: DictationSettings, vad: SileroVAD) {
        self.apiKey = apiKey
        self.settings = settings
        self.vad = vad
        capture.onSamples = { [weak self] samples, rate in
            self?.queue.async { self?.ingest(samples, rate: rate) }
        }
        capture.onConfigurationChange = { [weak self] in
            self?.queue.async { self?.restartCapture(reason: "device change") }
        }
        local.onState = { [weak self] _ in
            self?.queue.async {
                guard let self else { return }
                self.drainLocalQueue()
                self.refreshStatus()
            }
        }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.5, repeating: 0.5)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t

        // Runs off the engine queue, so it still fires if that queue is stuck.
        let w = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        var stallReported = false
        w.schedule(deadline: .now() + 2, repeating: 2)
        w.setEventHandler { [weak self] in
            guard let self else { return }
            let age = self.beatLock.withLock { now() - self.lastBeat }
            if age > Self.engineStallSec && !stallReported {
                stallReported = true
                Log.warn("[Engine] Audio processing has been stuck for \(Int(age)) s")
            } else if age < 2 && stallReported {
                stallReported = false
                Log.info("[Engine] Audio processing recovered")
            }
        }
        w.resume()
        watchdog = w
    }

    /// For tests: feed audio yourself instead of using the microphone.
    func disableMicrophone() { queue.sync { captureEnabled = false } }

    // MARK: - Public controls (thread-safe)

    func start() { queue.async { self.startLocked() } }
    func stop() { queue.async { self.stopLocked() } }

    func update(settings new: DictationSettings, apiKey key: String) {
        queue.async {
            let old = self.settings
            let keyChanged = key != self.apiKey
            self.settings = new
            self.apiKey = key
            if keyChanged { self.fatal = false }
            if new.sessionDiffers(from: old) || keyChanged { self.configError = nil }
            if new.preferBuiltInMic != old.preferBuiltInMic { self.restartCapture(reason: "mic setting changed") }
            if new.engine != old.engine {
                Log.info("Transcription engine: \(new.engine == "local" ? "on this Mac (Parakeet)" : "OpenAI")")
                if self.useLocal {
                    self.dropSession()
                    self.reconnectToken += 1
                    self.reconnectScheduled = false
                    if self.listening || !self.pending.isEmpty { self.local.prepare() }
                    self.drainLocalQueue()
                } else {
                    self.fatal = false  // retry the key once; a rejection shows again if it's still bad
                    if self.wantsConnection { self.ensureConnected() }
                }
                self.refreshStatus()
                return
            }
            if self.useLocal { self.refreshStatus(); return }
            if (new.sessionDiffers(from: old) || keyChanged), self.conn != nil {
                Log.info("[Realtime] Settings changed; opening a new session")
                self.rotate(reason: "settings changed")
            } else if self.listening {
                self.ensureConnected()
                self.refreshStatus()
            }
        }
    }

    /// Mac woke from sleep: the socket is almost certainly dead; replace it now.
    func handleWake() {
        queue.async {
            guard self.conn != nil || self.listening else { return }
            if self.useLocal {
                if self.listening { self.restartCapture(reason: "wake from sleep") }
                return
            }
            Log.info("[Realtime] Mac woke from sleep; reconnecting")
            self.backoff = Self.backoffInitial
            self.rotate(reason: "wake from sleep")
            if self.listening { self.restartCapture(reason: "wake from sleep") }
        }
    }

    /// For tests: push audio at any sample rate.
    func feed(_ samples: [Float], rate: Double) { queue.async { self.ingest(samples, rate: rate) } }

    // MARK: - Start / stop

    private func startLocked() {
        guard !listening else { return }
        listening = true
        fatal = false
        residual.removeAll()
        preroll.removeAll()
        resampler.reset()
        vad.reset()   // a bad state in the speech detector must not survive pause/resume
        lastAudioAt = now()
        if captureEnabled {
            do {
                try capture.start(preferBuiltIn: settings.preferBuiltInMic)
            } catch {
                Log.error("[Audio] Could not start microphone: \(error.localizedDescription)")
                listening = false
                setStatus(.error("Microphone unavailable: \(error.localizedDescription)"))
                return
            }
        }
        if useLocal {
            Log.info("Listening (on this Mac: Parakeet, silence \(settings.silenceMs) ms)")
            local.prepare()
        } else {
            Log.info("Listening (OpenAI \(settings.model), delay \(settings.delay), silence \(settings.silenceMs) ms)")
        }
        ensureConnected()
        refreshStatus()
    }

    private func stopLocked() {
        guard listening else { return }
        listening = false
        restartPending = false
        micError = nil
        stoppedAt = now()
        capture.stop()
        if inSpeech { endUtterance() }
        Log.info("Paused listening")
        refreshStatus()
    }

    private func restartCapture(reason: String, isRetry: Bool = false) {
        guard listening, captureEnabled else { return }
        if restartPending && !isRetry { return }  // a retry chain is already running
        restartPending = false
        Log.info("[Audio] Restarting microphone (\(reason))")
        if inSpeech { endUtterance() }
        residual.removeAll()
        resampler.reset()
        vad.reset()
        lastAudioAt = now()
        let wasBuiltIn = capture.isBuiltIn
        do {
            try capture.start(preferBuiltIn: settings.preferBuiltInMic)
            micError = nil
            refreshStatus()
            // Noise reduction "auto" depends on the mic type; re-apply it if that changed.
            if settings.noiseReduction == "auto", capture.isBuiltIn != wasBuiltIn, conn != nil {
                rotate(reason: "input device changed")
            }
        } catch {
            Log.error("[Audio] Restart failed: \(error.localizedDescription); retrying in 2s")
            micError = "Microphone unavailable: \(error.localizedDescription)"
            refreshStatus()
            restartPending = true
            queue.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.restartCapture(reason: "retry", isRetry: true)
            }
        }
    }

    private var micError: String?

    // MARK: - Audio -> VAD -> utterances

    private func ingest(_ samples: [Float], rate: Double) {
        guard listening else { return }
        lastAudioAt = now()
        var samples = samples
        if samples.contains(where: { !$0.isFinite }) {
            if now() - lastBadAudioWarn > 10 {
                lastBadAudioWarn = now()
                Log.warn("[Audio] Microphone sent invalid samples; replacing them with silence")
            }
            samples = samples.map { $0.isFinite ? $0 : 0 }
        }
        residual += resampler.to16k(samples, rate: rate)
        let n = SileroVAD.chunkSamples
        var offset = 0
        while residual.count - offset >= n {
            processChunk(residual[offset..<offset + n])
            offset += n
        }
        residual.removeFirst(offset)
    }

    private func processChunk(_ chunk: ArraySlice<Float>) {
        let p = vad.process(chunk)
        guard p.isFinite else {
            // Once the detector's memory holds NaN it reports "no speech" forever.
            Log.warn("[VAD] Invalid speech score (\(p)); resetting the speech detector")
            vad.reset()
            if inSpeech { endUtterance() }
            return
        }
        let pcm = Self.pcm24k(chunk)
        let chunkMs = 32
        if !inSpeech {
            preroll.append((pcm, Array(chunk)))
            let maxPre = max(1, settings.prefixMs / chunkMs)
            if preroll.count > maxPre { preroll.removeFirst(preroll.count - maxPre) }
            if p >= settings.vadThreshold {
                inSpeech = true
                speechChunks = 1
                silenceChunks = 0
                let u = Utterance(seq: nextSeq)
                nextSeq += 1
                current = u
                for d in preroll { appendAudio(d.pcm, raw: d.raw) }
                preroll.removeAll()
                lastSpeechAt = now()
                connectNowIfWaiting()
                Log.debug("[VAD] Speech started")
                main { self.onSpeaking?(true) }
            }
            return
        }

        appendAudio(pcm, raw: Array(chunk))
        // Hysteresis as in Silero's reference: stay in speech until p drops 0.15 below threshold.
        if p >= settings.vadThreshold - 0.15 {
            silenceChunks = 0
            speechChunks += 1
            lastSpeechAt = now()
        } else {
            silenceChunks += 1
        }
        if silenceChunks * chunkMs >= settings.silenceMs {
            endUtterance()
        }
    }

    /// Speech ended (or capture stopped): commit or discard the current utterance.
    private func endUtterance() {
        guard let u = current else { inSpeech = false; return }
        inSpeech = false
        current = nil
        let speechMs = speechChunks * 32
        silenceChunks = 0
        main { self.onSpeaking?(false) }
        if speechMs < settings.minSpeechMs {
            Log.debug("[VAD] Ignored \(speechMs) ms blip")
            if connReady && !useLocal { conn?.send(["type": "input_audio_buffer.clear"]) }
            return
        }
        u.speechEndAt = lastSpeechAt
        u.committedAt = now()
        pending.append(u)
        Log.debug("[VAD] Speech ended (\(speechMs) ms); committing #\(u.seq)")
        if useLocal { transcribeLocally(u) }
        else if connReady { sendCommit(u) } else { connectNowIfWaiting() }
    }

    private func appendAudio(_ pcm: Data, raw: [Float]) {
        guard let u = current else { return }
        u.audio.append(pcm)
        u.samples += raw
        u.lastAudioAt = now()
        if useLocal { return }
        if connReady { sendAppend(pcm) }
        else { ensureConnected() }
    }

    // MARK: - Local transcription

    private var localInFlight = Set<Int>()

    /// Runs Parakeet on a finished utterance. If the model is still loading, the utterance
    /// waits in `pending` and is picked up by drainLocalQueue() once it's ready.
    private func transcribeLocally(_ u: Utterance) {
        guard local.isReady else { local.prepare(); return }
        guard !localInFlight.contains(u.seq) else { return }
        localInFlight.insert(u.seq)
        let samples = u.samples
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let result: Result<String, Error>
            do { result = .success(try await self.local.transcribe(samples)) }
            catch { result = .failure(error) }
            self.queue.async {
                self.localInFlight.remove(u.seq)
                switch result {
                case .success(let text): u.transcript = LocalTranscriber.tidy(text)
                case .failure(let error):
                    Log.warn("[Local] Transcription failed: \(error.localizedDescription)")
                    u.failed = true
                }
                self.flush()
            }
        }
    }

    private func drainLocalQueue() {
        guard useLocal, local.isReady else { return }
        // Speech captured while the model was loading (e.g. first-time download) is only
        // worth pasting if it's recent.
        let t = now()
        let before = pending.count
        pending.removeAll { $0.transcript == nil && !$0.failed && !localInFlight.contains($0.seq)
            && t - $0.lastAudioAt > Self.staleReplaySec }
        if pending.count < before { Log.warn("[Local] Dropped \(before - pending.count) old utterance(s) spoken while the model loaded") }
        for u in pending where u.transcript == nil && !u.failed { transcribeLocally(u) }
    }

    private func sendAppend(_ pcm: Data) {
        conn?.send(["type": "input_audio_buffer.append", "audio": pcm.base64EncodedString()])
    }

    private func sendCommit(_ u: Utterance) {
        let id = "commit_\(generation)_\(u.seq)"
        u.commitEventId = id
        u.itemId = nil
        awaitingAck.append(u)
        conn?.send(["type": "input_audio_buffer.commit", "event_id": id])
    }

    /// 16 kHz float -> 24 kHz PCM16 little-endian (linear interpolation, as before).
    static func pcm24k(_ x: ArraySlice<Float>) -> Data {
        let src = Array(x)
        let n = src.count
        let m = n * 3 / 2
        var out = [Int16](repeating: 0, count: m)
        for k in 0..<m {
            let pos = Float(k) * Float(n - 1) / Float(m - 1)
            let i = Int(pos)
            let f = pos - Float(i)
            let a = src[i]
            let b = i + 1 < n ? src[i + 1] : a
            let v = max(-1, min(1, a + (b - a) * f))
            out[k] = Int16(v * 32767)
        }
        return out.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    // MARK: - Session lifecycle

    private var wantsConnection: Bool {
        !useLocal && (listening || current != nil || !pending.isEmpty)
    }

    private func ensureConnected() {
        guard !useLocal, conn == nil, !reconnectScheduled, !fatal, configError == nil, !apiKey.isEmpty else { return }
        connect()
    }

    /// Someone is talking while we wait out a reconnect backoff: try again right away
    /// so their speech isn't held long enough to go stale.
    private func connectNowIfWaiting() {
        if conn == nil && reconnectScheduled {
            reconnectToken += 1
            reconnectScheduled = false
            backoff = Self.backoffInitial
        }
        ensureConnected()
    }

    /// Forget the current socket and everything tied to it. Pending utterances stay
    /// and are replayed into the next session.
    private func dropSession() {
        conn?.close()
        conn = nil
        connReady = false
        awaitingAck.removeAll()
        for u in pending { u.itemId = nil }
    }

    private func connect() {
        generation += 1
        let c = RealtimeConnection(apiKey: apiKey, queue: queue, generation: generation)
        c.onEvent = { [weak self, weak c] ev in
            guard let self, let c, c === self.conn else { return }
            self.handle(ev)
        }
        c.onClose = { [weak self, weak c] reason, fatal in
            guard let self, let c, c === self.conn else { return }
            self.connectionLost(reason: reason, fatal: fatal)
        }
        conn = c
        connReady = false
        refreshStatus()
        c.open(sessionConfig: sessionConfig())
    }

    private func sessionConfig() -> [String: Any] {
        let s = settings
        let newStyle = s.model == "gpt-live-transcribe" || s.model == "gpt-transcribe"
        var tr: [String: Any] = ["model": s.model]
        if let lang = s.languageCode {
            if newStyle { tr["languages"] = [lang] } else { tr["language"] = lang }
        }
        let prompt = s.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !prompt.isEmpty { tr["prompt"] = String(prompt.prefix(1000)) }
        if s.model == "gpt-live-transcribe", !s.delay.isEmpty { tr["delay"] = s.delay }
        var input: [String: Any] = [
            "format": ["type": "audio/pcm", "rate": 24000],
            "transcription": tr,
            "turn_detection": NSNull(),   // our own VAD decides when an utterance ends
        ]
        var nr = s.noiseReduction
        if nr == "auto" { nr = capture.isBuiltIn || !captureEnabled ? "far_field" : "near_field" }
        if nr != "off" { input["noise_reduction"] = ["type": nr] }
        return ["type": "transcription", "audio": ["input": input]]
    }

    private func sessionReady() {
        connReady = true
        sessionStartedAt = now()
        Log.info("[Realtime] Session #\(generation) ready")
        replayUnfinished()
        refreshStatus()
    }

    /// Re-send utterances the previous session never transcribed, in order.
    private func replayUnfinished() {
        let t = now()
        var dropped = 0
        pending.removeAll { u in
            let stale = u.transcript == nil && !u.failed && t - u.lastAudioAt > Self.staleReplaySec
            if stale { dropped += 1 }
            return stale
        }
        if dropped > 0 { Log.warn("[Realtime] Dropped \(dropped) utterance(s) older than \(Int(Self.staleReplaySec))s after the outage") }
        var replayed = 0
        for u in pending where u.transcript == nil && !u.failed {
            sendAudioInPieces(u.audio)
            sendCommit(u)
            replayed += 1
        }
        if let u = current {
            sendAudioInPieces(u.audio)
            replayed += 1
        }
        if replayed > 0 { Log.info("[Realtime] Replayed \(replayed) unfinished utterance(s) into the new session") }
        flush()
    }

    private func sendAudioInPieces(_ audio: Data) {
        let piece = 48_000  // 1 s of 24 kHz PCM16
        var i = 0
        while i < audio.count {
            sendAppend(audio.subdata(in: i..<min(i + piece, audio.count)))
            i += piece
        }
    }

    private func connectionLost(reason: String, fatal isFatal: Bool) {
        let wasReady = connReady
        dropSession()
        if isFatal {
            fatal = true
            Log.error("[Realtime] OpenAI rejected the API key: \(reason)")
            setStatus(.error("OpenAI rejected the API key. Check it in Settings."))
            return
        }
        Log.warn("[Realtime] Connection lost: \(reason)")
        // Only a session that actually worked for a while resets the backoff.
        if wasReady && t(sessionStartedAt) > 60 { backoff = Self.backoffInitial }
        scheduleReconnect(after: backoff)
        backoff = min(backoff * 2, Self.backoffMax)
        refreshStatus(reason: reason)
    }

    private func t(_ since: Double) -> Double { now() - since }

    private func scheduleReconnect(after delay: Double) {
        guard !reconnectScheduled else { return }
        reconnectScheduled = true
        let token = reconnectToken
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, token == self.reconnectToken else { return }
            self.reconnectScheduled = false
            if self.conn == nil && self.wantsConnection && !self.fatal && self.configError == nil { self.connect() }
            else { self.refreshStatus() }
        }
    }

    /// Planned replacement of the session. Unfinished utterances are replayed.
    private func rotate(reason: String) {
        Log.info("[Realtime] Rotating session (\(reason))")
        dropSession()
        reconnectToken += 1
        reconnectScheduled = false
        if wantsConnection && !fatal && configError == nil { connect() } else { refreshStatus() }
    }

    // MARK: - Events

    private func handle(_ ev: [String: Any]) {
        guard let type = ev["type"] as? String else { return }
        switch type {
        case "session.created":
            Log.debug("[Realtime] Session created")
        case "session.updated":
            if !connReady { sessionReady() }
        case "input_audio_buffer.committed":
            guard let item = ev["item_id"] as? String else { return }
            if !awaitingAck.isEmpty {
                let u = awaitingAck.removeFirst()
                u.itemId = item
            }
        case "conversation.item.input_audio_transcription.completed":
            guard let item = ev["item_id"] as? String else { return }
            if let u = pending.first(where: { $0.itemId == item }) {
                u.transcript = (ev["transcript"] as? String) ?? ""
                flush()
            }
        case "conversation.item.input_audio_transcription.failed":
            let item = ev["item_id"] as? String
            Log.warn("[Realtime] Transcription failed: \(ev["error"] ?? "")")
            if let u = pending.first(where: { $0.itemId == item }) { u.failed = true; flush() }
        case "error":
            let err = ev["error"] as? [String: Any] ?? [:]
            let code = err["code"] as? String ?? ""
            let message = err["message"] as? String ?? "\(err)"
            let eventId = err["event_id"] as? String
            Log.warn("[Realtime] Server error (\(code)): \(message)")
            let param = err["param"] as? String ?? ""
            let transient = code.contains("server") || code.contains("rate_limit")
                || (err["type"] as? String) == "server_error"
            if !transient && (!connReady || param.hasPrefix("session")) {
                // OpenAI refused our session settings; retrying the same settings won't help.
                configError = message
                dropSession()
                Log.error("[Realtime] Session settings rejected: \(message)")
                setStatus(.error("OpenAI rejected the settings: \(message)"))
                return
            }
            if let eventId, let i = awaitingAck.firstIndex(where: { $0.commitEventId == eventId }) {
                let u = awaitingAck.remove(at: i)
                u.failed = true
                flush()
            }
            if code == "session_expired" || code == "session_not_found" {
                rotate(reason: code)
            }
        default:
            break
        }
    }

    /// Emit finished transcripts strictly in speaking order.
    private func flush() {
        let t = now()
        while let u = pending.first {
            if let text = u.transcript {
                pending.removeFirst()
                emit(text, u)
            } else if u.failed {
                pending.removeFirst()
            } else if let c = u.committedAt, t - c > Self.staleTranscriptSec, !localInFlight.contains(u.seq),
                      connReady || useLocal {
                Log.warn("[Realtime] No transcript for utterance #\(u.seq) after \(Int(Self.staleTranscriptSec))s; skipping it")
                pending.removeFirst()
                if awaitingAck.contains(where: { $0 === u }) {
                    // Its commit was never acknowledged, so commit/item pairing can't be trusted.
                    rotate(reason: "lost commit acknowledgement")
                    return
                }
            } else {
                break
            }
        }
    }

    private func emit(_ raw: String, _ u: Utterance) {
        let text = raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !text.isEmpty else { Log.debug("[Realtime] Empty transcript"); return }
        let latency = u.speechEndAt.map { (now() - $0) * 1000 }
        Log.info("[Text] \(text)" + (latency.map { String(format: "  (%.0f ms after speech)", $0) } ?? ""))
        main { self.onTranscript?(text, latency) }
    }

    // MARK: - Maintenance

    private func tick() {
        beatLock.withLock { lastBeat = now() }
        if listening && captureEnabled && !restartPending && t(lastAudioAt) > Self.audioStallSec {
            Log.warn(String(format: "[Audio] No audio from the microphone for %.0f s; restarting it", t(lastAudioAt)))
            restartCapture(reason: "no audio")
        }
        flush()
        if let c = conn {
            if !connReady {
                if t(c.openedAt) > Self.configureTimeoutSec {
                    c.close()
                    connectionLost(reason: "session setup timed out", fatal: false)
                }
                return
            }
            c.keepalive()
            let age = t(sessionStartedAt)
            let idle = current == nil && pending.isEmpty && t(lastSpeechAt) > Self.idleQuietSec
            if age > Self.sessionMaxAgeSec {
                rotate(reason: "hard age cap \(Int(age / 60)) min")
            } else if age > Self.sessionRecycleSec && idle {
                rotate(reason: "proactive refresh \(Int(age / 60)) min")
            } else if !listening && idle && t(stoppedAt) > Self.pausedDisconnectSec {
                Log.info("[Realtime] Paused for a while; closing the idle session")
                dropSession()
                refreshStatus()
            }
        }
    }

    // MARK: - Status

    private func refreshStatus(reason: String? = nil) {
        if fatal && !useLocal {
            setStatus(.error("OpenAI rejected the API key. Check it in Settings."))
            return
        }
        let s: EngineStatus
        if !listening {
            s = .stopped
        } else if useLocal {
            if let e = micError { s = .error(e) }
            else {
                switch local.currentState {
                case .ready: s = .listening
                case .failed(let e): s = .error("Couldn't load the speech model: \(e)")
                default: s = .loadingModel
                }
            }
        } else if let e = configError {
            s = .error("OpenAI rejected the settings: \(e)")
        } else if let e = micError {
            s = .error(e)
        } else if connReady || (conn != nil && lastStatus == .listening) {
            s = .listening  // planned rotations are invisible: audio is buffered and replayed
        } else if generation <= 1 && reason == nil {
            s = .connecting
        } else {
            s = .reconnecting(reason ?? "reconnecting")
        }
        setStatus(s)
    }

    private func setStatus(_ s: EngineStatus) {
        guard s != lastStatus else { return }
        lastStatus = s
        main { self.onStatus?(s) }
    }

    private func main(_ block: @escaping () -> Void) { DispatchQueue.main.async(execute: block) }
}
