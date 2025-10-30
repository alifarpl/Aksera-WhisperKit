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

// MARK: - Audio Ring Buffer
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
        
        var mixed = [Float](repeating: 0, count: frameCount)
        if channelCount == 1 {
            mixed.withUnsafeMutableBufferPointer { dest in
                dest.baseAddress!.update(from: channelData[0], count: frameCount)
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
    
    func allSamples() -> [Float] {
        return queue.sync { samples }
    }
    
    func sampleCount() -> Int {
        return queue.sync { samples.count }
    }
}

// MARK: - Transcription Manager - WhisperAX Implementation
actor TranscriptionManager {
    // WhisperAX @AppStorage equivalents
    private let selectedTask: String = "transcribe"
    private let selectedLanguage: String = "english"
    private let enableTimestamps: Bool = true
    private let enablePromptPrefill: Bool = true
    private let enableCachePrefill: Bool = true
    private let enableSpecialCharacters: Bool = false
    private let temperatureStart: Double = 0
    private let fallbackCount: Double = 5
    private let compressionCheckWindow: Double = 60
    private let sampleLength: Double = 224
    private let tokenConfirmationsNeeded: Double = 2
    
    // Audio
    private let engine = AVAudioEngine()
    private var ring: AudioRingBuffer?
    private var inputSampleRate: Double = 16000
    
    // WhisperKit
    private var whisperKit: WhisperKit?
    
    // State
    private var running = false
    private var tickingTask: Task<Void, Never>?
    private var isTranscribing = false
    
    // WhisperAX eager mode properties
    private var eagerResults: [TranscriptionResult?] = []
    private var prevResult: TranscriptionResult?
    private var lastAgreedSeconds: Float = 0.0
    private var prevWords: [WordTiming] = []
    private var lastAgreedWords: [WordTiming] = []
    private var confirmedWords: [WordTiming] = []
    private var confirmedText: String = ""
    private var hypothesisWords: [WordTiming] = []
    private var hypothesisText: String = ""
    
    // UI update properties
    private var currentText: String = ""
    private var currentFallbacks: Int = 0
    private var currentDecodingLoops: Int = 0
    
    // Performance metrics (optional)
    private var tokensPerSecond: TimeInterval = 0
    private var firstTokenTime: TimeInterval = 0
    private var effectiveRealTimeFactor: TimeInterval = 0
    
    // Silence detection for bubble creation
    private let silenceThreshold: Double = 0.3
    private let silenceDurationForSplit: Double = 1.5
    private var lastSpeechTime: Date = Date()
    private var silenceDetected: Bool = false
    
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
        
        // WhisperKit initialization from WhisperAX
        let config = WhisperKitConfig(
            model: "medium",
            computeOptions: ModelComputeOptions(
                audioEncoderCompute: .cpuAndNeuralEngine,
                textDecoderCompute: .cpuAndNeuralEngine
            ),
            verbose: true,
            logLevel: .debug,
            prewarm: false,
            load: true,
            download: true
        )
        
        self.whisperKit = try await WhisperKit(config)
        
        guard whisperKit?.textDecoder.supportsWordTimestamps == true else {
            throw NSError(
                domain: "TranscriptionManager",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Eager mode requires word timestamps, which are not supported by the current model"]
            )
        }
        
        // Setup audio engine
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        self.inputSampleRate = format.sampleRate
        self.ring = AudioRingBuffer(sampleRate: inputSampleRate, maxSeconds: 30)
        
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            Task { [weak self] in
                guard let self else { return }
                await self.ring?.append(buffer: buffer)
            }
        }
        
        try engine.start()
        
        // Start transcription loop
        tickingTask = Task { [weak self] in
            guard let self else { return }
            while await self.running {
                try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second (realtimeDelayInterval)
                await self.tick()
            }
        }
    }
    
    func stop() async {
        running = false
        
        while isTranscribing {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        
        tickingTask?.cancel()
        tickingTask = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
    
    func reset() {
        // WhisperAX reset
        eagerResults = []
        prevResult = nil
        lastAgreedSeconds = 0.0
        prevWords = []
        lastAgreedWords = []
        confirmedWords = []
        confirmedText = ""
        hypothesisWords = []
        hypothesisText = ""
        currentText = ""
        currentFallbacks = 0
        currentDecodingLoops = 0
        lastSpeechTime = Date()
        silenceDetected = false
    }
    
    private func tick() async {
        guard running, !isTranscribing, let whisperKit, let ring else { return }
        isTranscribing = true
        defer { isTranscribing = false }
        
        let samples = ring.allSamples()
        guard !samples.isEmpty else { return }
        
        // Silence detection
        let isSilent = detectSilence(in: samples)
        if isSilent {
            let silenceDuration = Date().timeIntervalSince(lastSpeechTime)
            if silenceDuration >= silenceDurationForSplit && !confirmedText.isEmpty && !silenceDetected {
                silenceDetected = true
                onSilenceDetected()
                reset()
                return
            }
            return
        } else {
            lastSpeechTime = Date()
            silenceDetected = false
        }
        
        // Transcribe
        do {
            try await transcribeEagerMode(samples: samples, whisperKit: whisperKit)
        } catch is CancellationError {
            return
        } catch {
            onError(error)
        }
    }
    
    // transcribeEagerMode from WhisperAX ContentView.swift lines 642-731
    private func transcribeEagerMode(samples: [Float], whisperKit: WhisperKit) async throws {
        let languageCode = Constants.languages[selectedLanguage, default: Constants.defaultLanguageCode]
        let task: DecodingTask = selectedTask == "transcribe" ? .transcribe : .translate
        
        let options = DecodingOptions(
            verbose: true,
            task: task,
            language: languageCode,
            temperature: Float(temperatureStart),
            temperatureFallbackCount: Int(fallbackCount),
            sampleLength: Int(sampleLength),
            usePrefillPrompt: enablePromptPrefill,
            usePrefillCache: enableCachePrefill,
            skipSpecialTokens: !enableSpecialCharacters,
            withoutTimestamps: !enableTimestamps,
            wordTimestamps: true,
            firstTokenLogProbThreshold: -1.5,
            chunkingStrategy: .none
        )
        
        // early stopping checks from WhisperAX lines 586-615
        let decodingCallback: ((TranscriptionProgress) -> Bool?) = { progress in
            DispatchQueue.main.async {
                let fallbacks = Int(progress.timings.totalDecodingFallbacks)
                if progress.text.count < self.currentText.count {
                    if fallbacks == self.currentFallbacks {
                        // New window
                    } else {
                        print("Fallback occurred: \(fallbacks)")
                    }
                }
                self.currentText = progress.text
                self.currentFallbacks = fallbacks
                self.currentDecodingLoops += 1
            }
            
            // Check early stopping
            let currentTokens = progress.tokens
            let checkWindow = Int(self.compressionCheckWindow)
            if currentTokens.count > checkWindow {
                let checkTokens: [Int] = currentTokens.suffix(checkWindow)
                let compressionRatio = TextUtilities.compressionRatio(of: checkTokens)
                if compressionRatio > options.compressionRatioThreshold! {
                    print("[EagerMode] Early stopping due to compression threshold")
                    return false
                }
            }
            if progress.avgLogprob! < options.logProbThreshold! {
                print("[EagerMode] Early stopping due to logprob threshold")
                return false
            }
            
            return nil
        }
        
        // segment callback from WhisperAX
        whisperKit.segmentDiscoveryCallback = { segments in
            for segment in segments {
                print("[EagerMode] Discovered segment: \(segment.id) (\(segment.seek)): \(segment.start) -> \(segment.end)")
            }
        }
        
        print("[EagerMode] \(lastAgreedSeconds)-\(Double(samples.count) / 16000.0) seconds")
        
        let streamingAudio = samples
        var streamOptions = options
        streamOptions.clipTimestamps = [lastAgreedSeconds]
        let lastAgreedTokens = lastAgreedWords.flatMap { $0.tokens }
        streamOptions.prefixTokens = lastAgreedTokens
        
        // transcribe call
        let transcription: TranscriptionResult? = try await whisperKit.transcribe(
            audioArray: streamingAudio,
            decodeOptions: streamOptions,
            callback: decodingCallback
        ).first
        
        // result processing from WhisperAX lines 677-712
        var skipAppend = false
        if let result = transcription {
            hypothesisWords = result.allWords.filter { $0.start >= lastAgreedSeconds }
            
            if let prevResult = prevResult {
                prevWords = prevResult.allWords.filter { $0.start >= lastAgreedSeconds }
                let commonPrefix = TranscriptionUtilities.findLongestCommonPrefix(prevWords, hypothesisWords)
                
                print("[EagerMode] Prev \"\((prevWords.map { $0.word }).joined())\"")
                print("[EagerMode] Next \"\((hypothesisWords.map { $0.word }).joined())\"")
                print("[EagerMode] Found common prefix \"\((commonPrefix.map { $0.word }).joined())\"")
                
                if commonPrefix.count >= Int(tokenConfirmationsNeeded) {
                    lastAgreedWords = Array(commonPrefix.suffix(Int(tokenConfirmationsNeeded)))
                    lastAgreedSeconds = lastAgreedWords.first!.start
                    print("[EagerMode] Found new last agreed word \"\(lastAgreedWords.first!.word)\" at \(lastAgreedSeconds) seconds")
                    
                    confirmedWords.append(contentsOf: commonPrefix.prefix(commonPrefix.count - Int(tokenConfirmationsNeeded)))
                    let currentWords = confirmedWords.map { $0.word }.joined()
                    print("[EagerMode] Current: \(lastAgreedSeconds) -> \(Double(samples.count) / 16000.0) \(currentWords)")
                } else {
                    print("[EagerMode] Using same last agreed time \(lastAgreedSeconds)")
                    skipAppend = true
                }
            }
            prevResult = result
        }
        
        if !skipAppend {
            eagerResults.append(transcription)
        }
        
        // final text assembly from WhisperAX lines 715-727
        let finalWords = confirmedWords.map { $0.word }.joined()
        confirmedText = finalWords
        
        // Accept the final hypothesis because it is the last of the available audio
        let lastHypothesis = lastAgreedWords + TranscriptionUtilities.findLongestDifferentSuffix(prevWords, hypothesisWords)
        hypothesisText = lastHypothesis.map { $0.word }.joined()
        
        // Update callbacks
        let combinedText = confirmedText + hypothesisText
        onLiveUpdate(combinedText, confirmedText)
        
        // Update metrics
        if let result = transcription {
            tokensPerSecond = result.timings.tokensPerSecond
            firstTokenTime = result.timings.firstTokenTime
            let totalAudio = Double(samples.count) / 16000.0
            let totalInferenceTime = result.timings.fullPipeline
            effectiveRealTimeFactor = totalInferenceTime / totalAudio
        }
    }
    
    private func detectSilence(in samples: [Float]) -> Bool {
        guard !samples.isEmpty else { return true }
        
        let recentSampleCount = Int(inputSampleRate * 0.5)
        let recentSamples = Array(samples.suffix(recentSampleCount))
        
        var sumSquares: Float = 0
        vDSP_svesq(recentSamples, 1, &sumSquares, vDSP_Length(recentSamples.count))
        let rms = sqrt(sumSquares / Float(recentSamples.count))
        
        return rms < Float(silenceThreshold)
    }
}
