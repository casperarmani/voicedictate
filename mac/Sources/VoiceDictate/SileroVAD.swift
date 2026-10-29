import CoreML
import Foundation

/// Silero VAD v6 (Core ML). Feed 512-sample (32 ms) chunks of 16 kHz mono audio;
/// returns the probability that the chunk contains speech.
final class SileroVAD {
    static let chunkSamples = 512
    private static let contextSamples = 64

    private let model: MLModel
    private let input: MLMultiArray
    private var hidden: MLMultiArray
    private var cell: MLMultiArray
    private var context = [Float](repeating: 0, count: contextSamples)

    init(modelURL: URL) throws {
        let config = MLModelConfiguration()
        config.computeUnits = .cpuOnly  // tiny model: CPU avoids accelerator scheduling latency
        model = try MLModel(contentsOf: modelURL, configuration: config)
        input = try MLMultiArray(shape: [1, NSNumber(value: Self.contextSamples + Self.chunkSamples)], dataType: .float32)
        hidden = try Self.zeros()
        cell = try Self.zeros()
    }

    static func bundledModelURL() -> URL? {
        if let url = Bundle.main.url(forResource: "silero_vad", withExtension: "mlmodelc") {
            return url
        }
        // Running from `swift run`: fall back to the repo copy next to the package.
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        var dir = exe.deletingLastPathComponent()
        for _ in 0..<6 {
            let candidate = dir.appendingPathComponent("Resources/silero_vad.mlmodelc")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    private static func zeros() throws -> MLMultiArray {
        let a = try MLMultiArray(shape: [1, 128], dataType: .float32)
        a.withUnsafeMutableBufferPointer(ofType: Float.self) { p, _ in p.update(repeating: 0) }
        return a
    }

    func reset() {
        hidden = (try? Self.zeros()) ?? hidden
        cell = (try? Self.zeros()) ?? cell
        context = [Float](repeating: 0, count: Self.contextSamples)
    }

    func process(_ chunk: ArraySlice<Float>) -> Float {
        precondition(chunk.count == Self.chunkSamples)
        input.withUnsafeMutableBufferPointer(ofType: Float.self) { p, _ in
            for i in 0..<Self.contextSamples { p[i] = context[i] }
            var j = Self.contextSamples
            for v in chunk { p[j] = v; j += 1 }
        }
        context = Array(chunk.suffix(Self.contextSamples))
        do {
            let features = try MLDictionaryFeatureProvider(dictionary: [
                "audio_input": input, "hidden_state": hidden, "cell_state": cell,
            ])
            let out = try model.prediction(from: features)
            if let h = out.featureValue(for: "new_hidden_state")?.multiArrayValue { hidden = h }
            if let c = out.featureValue(for: "new_cell_state")?.multiArrayValue { cell = c }
            return out.featureValue(for: "vad_output")?.multiArrayValue?[0].floatValue ?? 0
        } catch {
            Log.error("[VAD] prediction failed: \(error)")
            return 0
        }
    }
}
