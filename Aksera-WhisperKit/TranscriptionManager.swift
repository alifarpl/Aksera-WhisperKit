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

// MARK: - Transcription Manager - TRUE WhisperAX Implementation
actor TranscriptionManager {
    // EXACT WhisperAX @AppStorage equivalents
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
    private let realtimeDelayInterval: Double = 1.0
    
    // WhisperKit - EXACT like WhisperAX
    private var whisperKit: WhisperKit?
    
    // State
    private var running = false
    private var tickingTask: Task<Void, Never>?
    private var isTranscribing = false
    
    // EXACT WhisperAX eager mode properties
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
    
    // Performance metrics
    private var tokensPerSecond: TimeInterval = 0
    private var firstTokenTime: TimeInterval = 0
    private var effectiveRealTimeFactor: TimeInterval = 0
    
    // Silence detection for bubble creation
    private let silenceThreshold: Double = 0.3  // EXACT WhisperAX value
    private let silenceDurationForSplit: Double = 1.5
    private var lastSpeechTime: Date = Date()
    private var silenceDetected: Bool = false
    
    // Audio state tracking (like WhisperAX bufferEnergy/bufferSeconds)
    private var bufferEnergy: [Float] = []
    private var bufferSeconds: Double = 0
    
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
        
        print("[TranscriptionManager] Starting...")
        
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
        
        print("[TranscriptionManager] Initializing WhisperKit...")
        self.whisperKit = try await WhisperKit(config)
        print("[TranscriptionManager] WhisperKit initialized successfully")
        
        guard whisperKit?.textDecoder.supportsWordTimestamps == true else {
            throw NSError(
                domain: "TranscriptionManager",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Eager mode requires word timestamps"]
            )
        }
        
        print("[TranscriptionManager] Word timestamps supported ✓")
        
        // CRITICAL: Initialize WhisperKit's AudioProcessor (WhisperAX pattern)
        whisperKit?.audioProcessor = AudioProcessor()
        
        guard let audioProcessor = whisperKit?.audioProcessor else {
            throw NSError(domain: "TranscriptionManager", code: 2,
                         userInfo: [NSLocalizedDescriptionKey: "Failed to initialize AudioProcessor"])
        }
        
        // Request microphone permission
        guard await AudioProcessor.requestRecordPermission() else {
            throw NSError(domain: "TranscriptionManager", code: 3,
                         userInfo: [NSLocalizedDescriptionKey: "Microphone access denied"])
        }
        
        // WhisperAX audio recording start (lines ~620-630)
        #if os(macOS)
        var deviceId: DeviceID? = nil
        // On macOS, you might want to allow device selection
        // For now, use default device (nil)
        #else
        let deviceId: DeviceID? = nil
        #endif
        
        // Start recording with WhisperKit's AudioProcessor
        try audioProcessor.startRecordingLive(inputDeviceID: deviceId) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                // Update buffer state (WhisperAX pattern)
                await self.updateBufferState()
            }
        }
        
        print("[TranscriptionManager] Audio recording started")
        
        running = true
        
        // WhisperAX transcription loop (lines ~551-561)
        tickingTask = Task { [weak self] in
            guard let self else { return }
            while await self.running {
                try? await Task.sleep(nanoseconds: UInt64(await self.realtimeDelayInterval * 1_000_000_000))
                await self.realtimeLoop()
            }
        }
        
        print("[TranscriptionManager] Transcription loop started")
    }
    
    func stop() async {
        print("[TranscriptionManager] Stopping...")
        running = false
        
        while isTranscribing {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        
        tickingTask?.cancel()
        tickingTask = nil
        
        // Stop WhisperKit's audio processor
        whisperKit?.audioProcessor.stopRecording()
        
        reset()
        
        print("[TranscriptionManager] Stopped")
    }
    
    func reset() {
        print("[TranscriptionManager] Resetting state")
        // WhisperAX resetState() from lines ~281-314
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
        bufferEnergy = []
        bufferSeconds = 0
    }
    
    // Update buffer state from AudioProcessor (WhisperAX pattern)
    private func updateBufferState() {
        bufferEnergy = whisperKit?.audioProcessor.relativeEnergy ?? []
        bufferSeconds = Double(whisperKit?.audioProcessor.audioSamples.count ?? 0) / Double(WhisperKit.sampleRate)
    }
    
    // WhisperAX realtimeLoop() from lines ~547-561
    private func realtimeLoop() async {
        guard running, !isTranscribing else { return }
        
        do {
            try await transcribeCurrentBuffer()
        } catch {
            print("[TranscriptionManager] Error: \(error.localizedDescription)")
            onError(error)
        }
    }
    
    // WhisperAX transcribeCurrentBuffer() from lines ~563-640
    private func transcribeCurrentBuffer() async throws {
        guard let whisperKit = whisperKit else { return }
        
        isTranscribing = true
        defer { isTranscribing = false }
        
        // Get current audio buffer from WhisperKit's AudioProcessor
        let currentBuffer = whisperKit.audioProcessor.audioSamples
        
        print("[TranscriptionManager] Buffer size: \(currentBuffer.count) samples (\(Double(currentBuffer.count)/16000.0)s)")
        
        // Check for silence using WhisperAX's method
        let voiceDetected = AudioProcessor.isVoiceDetected(
            in: whisperKit.audioProcessor.relativeEnergy,
            nextBufferInSeconds: Float(bufferSeconds),
            silenceThreshold: Float(silenceThreshold)
        )
        
        guard voiceDetected else {
            print("[TranscriptionManager] No voice detected, waiting...")
//            if currentText.isEmpty {
//                    currentText = "Waiting for speech..."
//            }
            
            // Check for long silence to create new bubble
            let silenceDuration = Date().timeIntervalSince(lastSpeechTime)
            
            // Check if we have ANY text (confirmed OR hypothesis)
            let hasAnyText = !confirmedText.isEmpty || !hypothesisText.isEmpty
            
            let hasSpokenBefore = !confirmedText.isEmpty || !prevWords.isEmpty
            if silenceDuration >= silenceDurationForSplit && hasSpokenBefore && !silenceDetected  {
                print("[TranscriptionManager] Long silence detected (\(silenceDuration)s), creating new bubble")
                silenceDetected = true
                onSilenceDetected()
                // After onSilenceDetected()
                silenceDetected = true
                onSilenceDetected()

                Task {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    whisperKit.audioProcessor.stopRecording()
                    whisperKit.audioProcessor = AudioProcessor()
                    try? whisperKit.audioProcessor.startRecordingLive(inputDeviceID: nil) { [weak self] _ in
                        guard let self else { return }
                        Task { await self.updateBufferState() }
                    }
                    self.reset()
                    self.lastSpeechTime = Date()
                    print("[TranscriptionManager] ✅ Reset complete, ready for new audio")
                }
                
                reset()
            }
            
            try await Task.sleep(nanoseconds: 100_000_000)
            return
        }
        
        lastSpeechTime = Date()
        silenceDetected = false
        
        print("[TranscriptionManager] Voice detected, transcribing...")
        
        // Transcribe using eager mode
        try await transcribeEagerMode(samples: Array(currentBuffer), whisperKit: whisperKit)
    }
    
    // transcribeEagerMode from WhisperAX ContentView.swift lines 642-731
    private func transcribeEagerMode(samples: [Float], whisperKit: WhisperKit) async throws {
        print("[EagerMode] Starting transcription")
        
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
        
        // early stopping checks from WhisperAX
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
        
        whisperKit.segmentDiscoveryCallback = { segments in
            for segment in segments {
                print("[EagerMode] Discovered segment: \(segment.id): \(segment.start)->\(segment.end)")
            }
        }
        
        print("[EagerMode] Transcribing \(lastAgreedSeconds)-\(Double(samples.count) / 16000.0) seconds")
        
        let streamingAudio = samples
        var streamOptions = options
        streamOptions.clipTimestamps = [lastAgreedSeconds]
        let lastAgreedTokens = lastAgreedWords.flatMap { $0.tokens }
        streamOptions.prefixTokens = lastAgreedTokens
        
        print("[EagerMode] Calling transcribe...")
        let transcription: TranscriptionResult? = try await whisperKit.transcribe(
            audioArray: streamingAudio,
            decodeOptions: streamOptions,
            callback: decodingCallback
        ).first
        
        print("[EagerMode] Transcription complete")
        
        // result processing from WhisperAX
        var skipAppend = false
        if let result = transcription {
            hypothesisWords = result.allWords.filter { $0.start >= lastAgreedSeconds }
            
            if let prevResult = prevResult {
                prevWords = prevResult.allWords.filter { $0.start >= lastAgreedSeconds }
                let commonPrefix = TranscriptionUtilities.findLongestCommonPrefix(prevWords, hypothesisWords)
                
                print("[EagerMode] Prev: \"\((prevWords.map { $0.word }).joined())\"")
                print("[EagerMode] Next: \"\((hypothesisWords.map { $0.word }).joined())\"")
                print("[EagerMode] Common prefix: \"\((commonPrefix.map { $0.word }).joined())\"")
                
                if commonPrefix.count >= Int(tokenConfirmationsNeeded) {
                    lastAgreedWords = Array(commonPrefix.suffix(Int(tokenConfirmationsNeeded)))
                    lastAgreedSeconds = lastAgreedWords.first!.start
                    print("[EagerMode] New last agreed word: \"\(lastAgreedWords.first!.word)\" at \(lastAgreedSeconds)s")
                    
                    confirmedWords.append(contentsOf: commonPrefix.prefix(commonPrefix.count - Int(tokenConfirmationsNeeded)))
                    let currentWords = confirmedWords.map { $0.word }.joined()
                    print("[EagerMode] Current confirmed: \(currentWords)")
                } else {
                    print("[EagerMode] Using same last agreed time \(lastAgreedSeconds)")
                    skipAppend = true
                }
            }
            prevResult = result
        } else {
            print("[EagerMode] No transcription result")
        }
        
        if !skipAppend {
            eagerResults.append(transcription)
        }
        
        // final text assembly from WhisperAX
        let finalWords = confirmedWords.map { $0.word }.joined()
        confirmedText = finalWords
        
        let lastHypothesis = lastAgreedWords + TranscriptionUtilities.findLongestDifferentSuffix(prevWords, hypothesisWords)
        hypothesisText = lastHypothesis.map { $0.word }.joined()
        
        print("[EagerMode] Confirmed: '\(confirmedText)' | Hypothesis: '\(hypothesisText)'")
        
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
}
