//
//  TranscriptionManager.swift
//  Aksera-WhisperKit
//
//  Created by Alifa Reppawali on 27/10/25.
//

import Foundation
import AVFoundation
import WhisperKit
import Accelerate

// MARK: - Audio Ring Buffer (mono float32)
final class AudioRingBuffer {
    private let queue = DispatchQueue(label: "AudioRingBuffer.queue")
    private var samples: [Float] = []
    private var maxSamples: Int
    private(set) var sampleRate: Double

    init(sampleRate: Double, maxSeconds: Double) {
        self.sampleRate = sampleRate
        self.maxSamples = Int(sampleRate * maxSeconds)
        self.samples.reserveCapacity(self.maxSamples)
    }

    func append(buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        let channelCount = Int(buffer.format.channelCount)
        let frameCount = Int(buffer.frameLength)
        if frameCount == 0 { return }

        // Mix to mono
        var mixed = [Float](repeating: 0, count: frameCount)
        if channelCount == 1 {
            mixed.withUnsafeMutableBufferPointer { dest in
                dest.baseAddress!.assign(from: channelData[0], count: frameCount)
            }
        } else {
            for ch in 0..<channelCount {
                let src = channelData[ch]
                vDSP_vadd(mixed, 1, src, 1, &mixed, 1, vDSP_Length(frameCount))
            }
            var divisor = Float(channelCount)
            vDSP_vsdiv(mixed, 1, &divisor, &mixed, 1, vDSP_Length(frameCount))
        }

        queue.sync {
            samples.append(contentsOf: mixed)
            if samples.count > maxSamples {
                samples.removeFirst(samples.count - maxSamples)
            }
        }
    }

    func latest(seconds: Double) -> [Float] {
        let need = Int(seconds * sampleRate)
        return queue.sync {
            if need >= samples.count { return samples }
            return Array(samples.suffix(need))
        }
    }
}

// MARK: - WAV Writer (16-bit PCM)
enum WavWriter {
    static func writePCM16(samples: [Float], sampleRate: Double, to url: URL) throws {
        // Convert float [-1,1] -> Int16
        var int16 = [Int16](repeating: 0, count: samples.count)
        for i in 0..<samples.count {
            let clipped = max(-1.0, min(1.0, Double(samples[i])))
            int16[i] = Int16(clipped * Double(Int16.max))
        }

        let byteRate = UInt32(sampleRate) * 2 // mono, 16-bit
        let blockAlign: UInt16 = 2
        let subchunk2Size = UInt32(int16.count * MemoryLayout<Int16>.size)
        let chunkSize = 36 + subchunk2Size

        var data = Data()
        // RIFF header
        data.append("RIFF".data(using: .ascii)!)
        data.append(UInt32(chunkSize).littleEndianData)
        data.append("WAVE".data(using: .ascii)!)
        // fmt
        data.append("fmt ".data(using: .ascii)!)
        data.append(UInt32(16).littleEndianData)               // PCM chunk size
        data.append(UInt16(1).littleEndianData)                // PCM format
        data.append(UInt16(1).littleEndianData)                // mono
        data.append(UInt32(sampleRate).littleEndianData)       // sample rate
        data.append(UInt32(byteRate).littleEndianData)         // byte rate
        data.append(blockAlign.littleEndianData)               // block align
        data.append(UInt16(16).littleEndianData)               // bits per sample
        // data
        data.append("data".data(using: .ascii)!)
        data.append(UInt32(subchunk2Size).littleEndianData)
        int16.withUnsafeBytes { rawBuffer in data.append(contentsOf: rawBuffer) }

        try data.write(to: url, options: .atomic)
    }
}

private extension UInt16 {
    var littleEndianData: Data {
        var val = self.littleEndian
        return Data(bytes: &val, count: MemoryLayout<UInt16>.size)
    }
}
private extension UInt32 {
    var littleEndianData: Data {
        var val = self.littleEndian
        return Data(bytes: &val, count: MemoryLayout<UInt32>.size)
    }
}

// MARK: - Transcription Manager
actor TranscriptionManager {
    // Tuning
    private let chunkSeconds: Double = 5.0     // window length
    private let hopSeconds: Double = 0.75      // how often to run
    private let maxBufferSeconds: Double = 30  // rolling audio
    //SILENCE THRESHOLD
    // Lower = more sensitive (detects quieter speech as silence)
    // Higher = less sensitive (needs louder silence) -> For noisy environments
    private let silenceThreshold: Float = 0.02 // amplitude threshold for silence
    
    //SILENCE DURATION: How many seconds of silence before creating new bubble
    // Lower = splits more frequently
    // Higher = more forgiving of pauses
    private let silenceDurationForSplit: Double = 2.0 // seconds of silence to trigger new bubble

    // Whisper
    private var pipe: WhisperKit?

    // Audio
    private let engine = AVAudioEngine()
    private var ring: AudioRingBuffer?
    private var inputSampleRate: Double = 16000

    // State
    private var running = false
    private var tickingTask: Task<Void, Never>?
    private var isTranscribing = false
    private var lastSpeechTime: Date = Date()
    private var silenceDetected: Bool = false

    // Text
    private var finalizedText: String = ""
    private var lastDeltaCandidate: String = ""
    private var stableCount: Int = 0
    private let punctuationSet = CharacterSet(charactersIn: ".?!,;：、。？！")

    // Callbacks
    private let onLiveUpdate: (String, String) -> Void
    private let onError: (Error) -> Void
    private let onSilenceDetected: () -> Void

    init(
        onLiveUpdate: @escaping (String, String) -> Void,
        onError: @escaping (Error) -> Void,
        onSilenceDetected: @escaping () -> Void
    ) {
        self.onLiveUpdate = onLiveUpdate
        self.onError = onError
        self.onSilenceDetected = onSilenceDetected
    }

    func start() async throws {
        guard !running else { return }
        running = true

        // Initialize WhisperKit with remote "medium" model
        self.pipe = try await WhisperKit(WhisperKitConfig(model: "medium"))

        // Prepare audio engine
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        self.inputSampleRate = format.sampleRate
        self.ring = AudioRingBuffer(sampleRate: inputSampleRate, maxSeconds: maxBufferSeconds)

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            Task { [weak self] in
                guard let self else { return }
                await self.ring?.append(buffer: buffer)
            }
        }

        try engine.start()

        // Periodic transcription loop
        tickingTask = Task { [weak self] in
            guard let self else { return }
            while await self.running {
                try? await Task.sleep(nanoseconds: UInt64(hopSeconds * 1_000_000_000))
                await self.tick()
            }
        }
    }

    func stop() async {
        running = false
        
        // Wait for any in-progress transcription to complete
        while isTranscribing {
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
        }
        
        tickingTask?.cancel()
        tickingTask = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
    
    func reset() {
        finalizedText = ""
        lastDeltaCandidate = ""
        stableCount = 0
        lastSpeechTime = Date()
        silenceDetected = false
    }

    private func tick() async {
        guard running, !isTranscribing, let pipe, let ring else { return }
        isTranscribing = true
        defer { isTranscribing = false }

        let samples = ring.latest(seconds: chunkSeconds)
        guard !samples.isEmpty else { return }
        
        // Check for silence by analyzing audio amplitude
        let isSilent = detectSilence(in: samples)
        
        if isSilent {
            let silenceDuration = Date().timeIntervalSince(lastSpeechTime)
            
            // If silence duration exceeds threshold and we have text, trigger new bubble
            if silenceDuration >= silenceDurationForSplit && !finalizedText.isEmpty && !silenceDetected {
                silenceDetected = true
                onSilenceDetected()
                // Reset for next bubble
                finalizedText = ""
                lastDeltaCandidate = ""
                stableCount = 0
                return
            }
            return // Skip transcription during silence
        } else {
            // Speech detected
            lastSpeechTime = Date()
            silenceDetected = false
        }

        // Write chunk to temp WAV and transcribe
        let tmpURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")

        do {
            try WavWriter.writePCM16(samples: samples, sampleRate: inputSampleRate, to: tmpURL)

            let results = try await pipe.transcribe(audioPath: tmpURL.path)
            
            // Check if we're still running (not cancelled)
            guard running else {
                try? FileManager.default.removeItem(at: tmpURL)
                return
            }
            
            let windowText = results.map(\.text).joined(separator: " ")

            // Merge with finalized using overlap heuristic
            let delta = computeDelta(prior: finalizedText, latestWindow: windowText)

            // Update live immediately
            let combined = finalizedText + delta
            onLiveUpdate(combined, finalizedText)

            // Heuristic to finalize
            if endsWithPunctuation(delta) {
                finalizedText = combined.appending(" ")
                lastDeltaCandidate = ""
                stableCount = 0
                onLiveUpdate(finalizedText, finalizedText)
            } else {
                if delta == lastDeltaCandidate {
                    stableCount += 1
                } else {
                    lastDeltaCandidate = delta
                    stableCount = 1
                }
                if stableCount >= 3 {
                    finalizedText = combined.appending(" ")
                    lastDeltaCandidate = ""
                    stableCount = 0
                    onLiveUpdate(finalizedText, finalizedText)
                }
            }
        } catch is CancellationError {
            // Silently ignore cancellation errors - this is expected when stopping
            try? FileManager.default.removeItem(at: tmpURL)
            return
        } catch {
            // Only report non-cancellation errors
            onError(error)
        }

        // Cleanup
        try? FileManager.default.removeItem(at: tmpURL)
    }

    private func endsWithPunctuation(_ s: String) -> Bool {
        guard let last = s.unicodeScalars.last else { return false }
        return punctuationSet.contains(last)
    }

    private func computeDelta(prior: String, latestWindow: String) -> String {
        if prior.isEmpty { return latestWindow }

        let context = String(prior.suffix(200))
        let lowerContext = context.lowercased()
        let lowerWindow = latestWindow.lowercased()

        // Search the longest suffix of context that appears in the window
        let ctxChars = Array(lowerContext)
        var bestSuffixLen = 0
        var bestPosInWindow: Int = -1

        let minMatch = 10
        let maxLen = ctxChars.count
        for len in stride(from: min(maxLen, 200), through: minMatch, by: -1) {
            let suffix = String(ctxChars.suffix(len))
            if let range = lowerWindow.range(of: suffix) {
                bestSuffixLen = len
                bestPosInWindow = lowerWindow.distance(from: lowerWindow.startIndex, to: range.upperBound)
                break
            }
        }

        if bestPosInWindow >= 0 {
            let idx = latestWindow.index(latestWindow.startIndex, offsetBy: bestPosInWindow)
            return String(latestWindow[idx...])
        } else {
            return latestWindow
        }
    }
    
    // Detect silence by checking if audio amplitude is below threshold
    private func detectSilence(in samples: [Float]) -> Bool {
        guard !samples.isEmpty else { return true }
        
        // Calculate RMS (Root Mean Square) amplitude
        var sumSquares: Float = 0
        vDSP_svesq(samples, 1, &sumSquares, vDSP_Length(samples.count))
        let rms = sqrt(sumSquares / Float(samples.count))
        
        return rms < silenceThreshold
    }
}
