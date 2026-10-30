import AVFoundation
import Foundation

// `VoiceDictate --test <wav>...` runs the full pipeline (VAD + OpenAI) on audio files
// in real time without the microphone or pasting, printing transcripts and latency.
let args = CommandLine.arguments
if let i = args.firstIndex(of: "--test") {
    runFileTest(Array(args[(i + 1)...]).filter { !$0.hasPrefix("--") })
} else {
    VoiceDictateApp.main()
}

func runFileTest(_ paths: [String]) -> Never {
    guard let key = Keychain.apiKey() else { print("No API key (set OPENAI_API_KEY)"); exit(1) }
    guard let url = SileroVAD.bundledModelURL(), let vad = try? SileroVAD(modelURL: url) else {
        print("VAD model not found"); exit(1)
    }
    let engine = DictationEngine(apiKey: key, settings: DictationSettings.load(), vad: vad)
    engine.disableMicrophone()
    var latencies: [Double] = []
    engine.onTranscript = { text, ms in
        if let ms { latencies.append(ms) }
        let enter = DictationSettings.isSendCommand(text) ? "   ⏎ would press Enter" : ""
        print(String(format: "  → %5.0f ms  %@%@", ms ?? -1, text, enter))
    }
    engine.onStatus = { print("  [status] \($0)") }
    engine.start()

    DispatchQueue.global().async {
        let rate = 16000.0
        let block = 160  // 10 ms, like a real mic
        func pace(_ samples: [Float]) {
            let t0 = now()
            var i = 0
            while i < samples.count {
                let end = min(i + block, samples.count)
                engine.feed(Array(samples[i..<end]), rate: rate)
                i = end
                let target = t0 + Double(i) / rate
                let wait = target - now()
                if wait > 0 { Thread.sleep(forTimeInterval: wait) }
            }
        }
        pace([Float](repeating: 0, count: 16000))  // let the session connect
        let dropMidway = args.contains("--drop")
        for (n, p) in paths.enumerated() {
            guard let samples = loadMono16k(p) else { print("cannot read \(p)"); continue }
            print("▶︎ \(URL(fileURLWithPath: p).lastPathComponent)")
            if dropMidway && n % 2 == 1 {
                // Simulate the socket dying mid-sentence: the utterance must still come out.
                pace(Array(samples[0..<samples.count / 2]))
                print("  ✂︎ dropping connection mid-sentence")
                engine.handleWake()
                pace(Array(samples[(samples.count / 2)...]))
            } else {
                pace(samples)
            }
            pace([Float](repeating: 0, count: 32000))
        }
        pace([Float](repeating: 0, count: 48000))
        DispatchQueue.main.async {
            let sorted = latencies.sorted()
            if !sorted.isEmpty {
                print(String(format: "\nmedian %.0f ms, max %.0f ms over %d utterances (end of speech → text)",
                             sorted[sorted.count / 2], sorted.last!, sorted.count))
            }
            exit(0)
        }
    }
    dispatchMain()
}

func loadMono16k(_ path: String) -> [Float]? {
    guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)) else { return nil }
    let fmt = file.processingFormat
    guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(file.length)),
          (try? file.read(into: buf)) != nil, let ch = buf.floatChannelData else { return nil }
    let mono = Array(UnsafeBufferPointer(start: ch[0], count: Int(buf.frameLength)))
    return Resampler().to16k(mono, rate: fmt.sampleRate)
}
