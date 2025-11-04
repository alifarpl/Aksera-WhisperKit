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
    // WhisperAX @AppStorage equivalents
    private let selectedTask: String = "transcribe"
    private let selectedLanguage: String = "indonesian" // can be changed to english/indonesian
    private let enableTimestamps: Bool = true
    private let enablePromptPrefill: Bool = true
    private let enableCachePrefill: Bool = true
    private let enableSpecialCharacters: Bool = false
    private let temperatureStart: Double = 0
    private let fallbackCount: Double = 5
    private let compressionCheckWindow: Double = 60
    private let sampleLength: Double = 224
    private let tokenConfirmationsNeeded: Double = 2
    private let realtimeDelayInterval: Double = 0.5
    
    // WhisperKit - like WhisperAX
    private var whisperKit: WhisperKit?
    
    // State
    private var running = false
    private var tickingTask: Task<Void, Never>?
    private var isTranscribing = false
    
    // For text stability detection
    private var recentHypotheses: [String] = []

    // Determines if hypothesis has remained unchanged for several loops
    private func isTextStable() -> Bool {
        guard recentHypotheses.count >= 2 else { return false }
        let lastThree = recentHypotheses.suffix(2)
        // If all last 3 hypotheses are identical, it's stable
        let unique = Set(lastThree)
        return unique.count == 1
    }
    
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
    
    // Performance metrics
    private var tokensPerSecond: TimeInterval = 0
    private var firstTokenTime: TimeInterval = 0
    private var effectiveRealTimeFactor: TimeInterval = 0
    
    // Silence detection for bubble creation
    private let silenceThreshold: Double = 0.3  // WhisperAX value
    private let silenceDurationForSplit: Double = 1.5
    private var lastSpeechTime: Date = Date()
    private var silenceDetected: Bool = false
    private var bufferResetDone: Bool = false  // Track if buffer was reset during current silence
    
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
        
        // Get model folder from bundle resources (added as folder reference in Copy Bundle Resources)
        let modelFolderName = "openai_whisper-large-v3-v20240930_626MB"
        
        guard let modelPathURL = Bundle.main.url(forResource: modelFolderName, withExtension: nil) else {
            throw NSError(
                domain: "TranscriptionManager",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Model folder '\(modelFolderName)' not found in bundle. Please ensure it's added to the Xcode project as a folder reference in 'Copy Bundle Resources'."]
            )
        }
        
        let modelPath = modelPathURL.path
        
        // Verify model folder contains required files
        let requiredFiles = ["MelSpectrogram.mlmodelc", "AudioEncoder.mlmodelc", "TextDecoder.mlmodelc", "config.json"]
        let missingFiles = requiredFiles.filter { fileName in
            !FileManager.default.fileExists(atPath: (modelPath as NSString).appendingPathComponent(fileName))
        }
        
        if !missingFiles.isEmpty {
            throw NSError(
                domain: "TranscriptionManager",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "Model folder is missing required files: \(missingFiles.joined(separator: ", "))"]
            )
        }
        
        // WhisperKit initialization from WhisperAX
        let config = WhisperKitConfig(
            modelFolder: modelPath,
            computeOptions: ModelComputeOptions(
                audioEncoderCompute: .cpuAndNeuralEngine,
                textDecoderCompute: .cpuAndNeuralEngine
            ),
            verbose: true,
            logLevel: .debug,
            prewarm: false,
            load: true,
            download: false //local
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
        bufferResetDone = false
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
        
        // CRITICAL: Also check silence duration based on time, even if voice is "detected"
        // This handles cases where background noise makes voice detection think there's speech
        let silenceDuration = Date().timeIntervalSince(lastSpeechTime)
        let hasAnyText = !confirmedText.isEmpty || !hypothesisText.isEmpty
        
        // If we have long silence (1.5s+) AND have text, create new bubble regardless of voice detection
        // IMPORTANT: silenceDurationForSplit is 1.5 seconds - bubbles only created after this threshold
        if silenceDuration >= silenceDurationForSplit && hasAnyText && !silenceDetected {
            print("[TranscriptionManager] 🔔 Long silence detected by TIME (\(String(format: "%.2f", silenceDuration))s >= \(silenceDurationForSplit)s threshold), creating new bubble")
            silenceDetected = true
            
            // ✅ CRITICAL: Finalize hypothesis FIRST before saving bubble
            if !hypothesisText.isEmpty {
                print("[TranscriptionManager] 📝 Finalizing hypothesis before bubble creation: '\(hypothesisText)'")
                confirmedText += hypothesisText
                confirmedWords.append(contentsOf: hypothesisWords)
                
                hypothesisWords = []
                hypothesisText = ""
            }
            
            // Update UI with finalized text BEFORE triggering callback
            let finalText = confirmedText
            print("[TranscriptionManager] ✅ Finalized text for bubble: '\(finalText)'")
            onLiveUpdate(finalText, finalText)

            // CRITICAL: Small delay to ensure UI updates before callback
            try? await Task.sleep(nanoseconds: 50_000_000)  // 50ms

            // NOW trigger bubble creation with complete finalized text
            print("[TranscriptionManager] 💾 Triggering onSilenceDetected callback")
            onSilenceDetected()

            // Wait for bubble to be saved before resetting
            try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms
            
            // Reset audio buffer and prepare for next speech
            print("[TranscriptionManager] 🔄 Resetting audio processor")
            do {
                whisperKit.audioProcessor.stopRecording()
                // Give the audio system time to fully release the device
                try? await Task.sleep(nanoseconds: 300_000_000)  // 300ms - increased delay
                
                whisperKit.audioProcessor = AudioProcessor()
                
                // Add small delay before restarting to ensure clean state
                try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms
                
                try whisperKit.audioProcessor.startRecordingLive(inputDeviceID: nil) { [weak self] _ in
                    guard let self else { return }
                    Task { await self.updateBufferState() }
                }
                print("[TranscriptionManager] ✅ Audio processor reset successfully")
            } catch {
                // If reset fails, log but don't crash - the system will continue
                print("[TranscriptionManager] ⚠️ Error resetting audio processor: \(error.localizedDescription)")
                // Try to continue with existing processor - it might still work
            }
            
            // Reset state for new bubble
            eagerResults = []
            prevResult = nil
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
            recentHypotheses = []
            bufferEnergy = []
            bufferSeconds = 0
            bufferResetDone = false
            
            // Reset lastAgreedSeconds to 0 for fresh start on new bubble
            lastAgreedSeconds = 0.0
            
            print("[TranscriptionManager] ✅ Reset complete, ready for new audio")
            return
        }
        
        guard voiceDetected else {
            print("[TranscriptionManager] No voice detected, waiting...")
//            if currentText.isEmpty {
//                    currentText = "Waiting for speech..."
//            }
            
            // Check for long silence to create new bubble
            let silenceDuration = Date().timeIntervalSince(lastSpeechTime)
            
            // After 0.5s of silence, move hypothesis to confirmed and reset buffer
            // Only do this once per silence period (not repeatedly)
            if silenceDuration >= 0.5 && silenceDuration < silenceDurationForSplit && !bufferResetDone {
                var needsBufferReset = false
                
                // Finalize hypothesis if present
                if !hypothesisText.isEmpty {
                    print("[TranscriptionManager] ⏰ Finalizing lingering hypothesis after short silence")

                    // Promote hypothesis words to confirmed
                    confirmedText += hypothesisText
                    confirmedWords.append(contentsOf: hypothesisWords)
                    
                    // Reset agreement baseline so WhisperKit doesn't re-append old suffix
                    prevWords = []
                    lastAgreedWords = []
                    hypothesisWords = []
                    hypothesisText = ""

                    onLiveUpdate(confirmedText, confirmedText)
                    needsBufferReset = true
                }
                
                // ✅ Reset buffer once after short silence - this prepares for new speech
                // After buffer reset, lastAgreedSeconds needs to be reset to 0 since buffer is fresh
                if needsBufferReset && bufferSeconds > 0 {
                    print("[TranscriptionManager] 🧹 Resetting audio buffer after short silence")
                    
                    // Store previous value for logging
                    let previousLastAgreed = lastAgreedSeconds
                    
                    whisperKit.audioProcessor.stopRecording()
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    whisperKit.audioProcessor = AudioProcessor()
                    try? whisperKit.audioProcessor.startRecordingLive(inputDeviceID: nil) { [weak self] _ in
                        guard let self else { return }
                        Task { await self.updateBufferState() }
                    }
                    
                    // CRITICAL: Reset lastAgreedSeconds to 0 since buffer is now empty/fresh
                    // This ensures new speech will be transcribed from the beginning of the new buffer
                    lastAgreedSeconds = 0.0
                    bufferResetDone = true
                    print("[TranscriptionManager] 🔄 Reset lastAgreedSeconds from \(previousLastAgreed)s to 0.0s for fresh buffer")
                }
            }
            
            else if isTextStable() && !hypothesisText.isEmpty && silenceDuration < 0.5 {
                print("[TranscriptionManager] 🧩 Hypothesis stable, finalizing even without silence")

                confirmedText += hypothesisText
                confirmedWords.append(contentsOf: hypothesisWords)

                let newBoundary = hypothesisWords.last?.end ?? confirmedWords.last?.end
                if let boundary = newBoundary {
                    lastAgreedSeconds = boundary
                    print("[TranscriptionManager] 🔒 Advanced lastAgreedSeconds → \(lastAgreedSeconds)s after stable text finalization")
                }

                hypothesisWords = []
                hypothesisText = ""
                recentHypotheses.removeAll()

                onLiveUpdate(confirmedText, confirmedText)
            }
            
            try await Task.sleep(nanoseconds: 100_000_000)
            return
        }
        
        bufferResetDone = false  // Reset flag when speech is detected
        
        print("[TranscriptionManager] Voice detected, transcribing...")
        
        // CRITICAL: Check silence duration BEFORE transcription
        // This allows us to create bubbles even if silence markers are being transcribed
        // IMPORTANT: Do NOT reset silenceDetected flag here - only reset it after meaningful transcription
        let silenceDurationBeforeTranscription = Date().timeIntervalSince(lastSpeechTime)
        let hasAnyTextBeforeTranscription = !confirmedText.isEmpty || !hypothesisText.isEmpty
        
        // If we have long silence (1.5s+) AND have text, create new bubble
        // IMPORTANT: Only create bubble if silence duration is >= 1.5s (silenceDurationForSplit)
        // The silenceDetected flag prevents multiple bubbles from being created in quick succession
        if silenceDurationBeforeTranscription >= silenceDurationForSplit && hasAnyTextBeforeTranscription && !silenceDetected {
            print("[TranscriptionManager] 🔔 Long silence detected BEFORE transcription (\(String(format: "%.2f", silenceDurationBeforeTranscription))s >= \(silenceDurationForSplit)s threshold), creating new bubble")
            silenceDetected = true
            
            // ✅ CRITICAL: Finalize hypothesis FIRST before saving bubble
            if !hypothesisText.isEmpty {
                print("[TranscriptionManager] 📝 Finalizing hypothesis before bubble creation: '\(hypothesisText)'")
                confirmedText += hypothesisText
                confirmedWords.append(contentsOf: hypothesisWords)
                
                hypothesisWords = []
                hypothesisText = ""
            }
            
            // Update UI with finalized text BEFORE triggering callback
            let finalText = confirmedText
            print("[TranscriptionManager] ✅ Finalized text for bubble: '\(finalText)'")
            onLiveUpdate(finalText, finalText)

            // CRITICAL: Small delay to ensure UI updates before callback
            try? await Task.sleep(nanoseconds: 50_000_000)  // 50ms

            // NOW trigger bubble creation with complete finalized text
            print("[TranscriptionManager] 💾 Triggering onSilenceDetected callback")
            onSilenceDetected()

            // Wait for bubble to be saved before resetting
            try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms
            
            // Reset audio buffer and prepare for next speech
            print("[TranscriptionManager] 🔄 Resetting audio processor")
            do {
                whisperKit.audioProcessor.stopRecording()
                // Give the audio system time to fully release the device
                try? await Task.sleep(nanoseconds: 300_000_000)  // 300ms - increased delay
                
                whisperKit.audioProcessor = AudioProcessor()
                
                // Add small delay before restarting to ensure clean state
                try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms
                
                try whisperKit.audioProcessor.startRecordingLive(inputDeviceID: nil) { [weak self] _ in
                    guard let self else { return }
                    Task { await self.updateBufferState() }
                }
                print("[TranscriptionManager] ✅ Audio processor reset successfully")
            } catch {
                // If reset fails, log but don't crash - the system will continue
                print("[TranscriptionManager] ⚠️ Error resetting audio processor: \(error.localizedDescription)")
                // Try to continue with existing processor - it might still work
            }
            
            // Reset state for new bubble
            eagerResults = []
            prevResult = nil
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
            recentHypotheses = []
            bufferEnergy = []
            bufferSeconds = 0
            bufferResetDone = false
            
            // Reset lastAgreedSeconds to 0 for fresh start on new bubble
            lastAgreedSeconds = 0.0
            
            print("[TranscriptionManager] ✅ Reset complete, ready for new audio")
            return
        }
        
        // Transcribe using eager mode
        try await transcribeEagerMode(samples: Array(currentBuffer), whisperKit: whisperKit)
        
        // Helper function to check if text is meaningful (not just silence markers)
        func isMeaningfulText(_ text: String) -> Bool {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            // Ignore if empty
            if trimmed.isEmpty {
                return false
            }
            // Check if it's just silence markers like "[ Silence ]", "[silence]", etc.
            let silencePatterns = ["[silence]", "[ silence ]", "[silence", "silence]", "[blankaudio]", "[ blank audio ]", "[blank", "blank]", "[ silence", "silence ]"]
            let lowerText = trimmed.lowercased()
            for pattern in silencePatterns {
                if lowerText == pattern || lowerText.trimmingCharacters(in: CharacterSet(charactersIn: "[] ")) == "silence" || lowerText.trimmingCharacters(in: CharacterSet(charactersIn: "[] ")) == "blank" {
                    return false
                }
            }
            // Check if it only contains brackets and whitespace
            let withoutBrackets = trimmed.replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            if withoutBrackets.isEmpty || withoutBrackets.lowercased() == "silence" || withoutBrackets.lowercased() == "blank" {
                return false
            }
            return true
        }
        
        // CRITICAL: Only update lastSpeechTime if we got MEANINGFUL NEW transcription
        // (not just silence markers). This prevents silence markers from resetting the silence timer.
        // We check hypothesisText because that's the NEW transcription from this cycle
        let hasMeaningfulTranscription = isMeaningfulText(hypothesisText)
        
        if hasMeaningfulTranscription {
            lastSpeechTime = Date()
            // CRITICAL: Only reset silenceDetected flag when we get MEANINGFUL transcription
            // This ensures bubbles are only created after 1.5s of silence, not on every silence detection
            silenceDetected = false
            print("[TranscriptionManager] ✅ Updated lastSpeechTime after meaningful transcription, reset silenceDetected flag")
        } else {
            // Keep silenceDetected flag set if we didn't get meaningful transcription
            // This prevents bubbles from being created repeatedly during silence
            print("[TranscriptionManager] ⏸️ Skipped updating lastSpeechTime - only silence markers or empty transcription (hypothesis: '\(hypothesisText)')")
        }
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
            
            let audioDuration = Double(samples.count) / 16000.0
            
            // CRITICAL FIX: If lastAgreedSeconds exceeds buffer duration, something is wrong
            // This can happen if the buffer was reset but lastAgreedSeconds wasn't, or if
            // the buffer accumulated audio differently than expected. Reset to 0.
            if Float(lastAgreedSeconds) > Float(audioDuration) {
                print("[EagerMode] ⚠️ lastAgreedSeconds (\(lastAgreedSeconds)s) > buffer duration (\(audioDuration)s) - resetting to 0")
                lastAgreedSeconds = 0.0
                // Also clear prefix tokens since we're starting fresh
                lastAgreedWords = []
                prevWords = []
                prevResult = nil
            }
            
            print("[EagerMode] Transcribing \(lastAgreedSeconds)-\(audioDuration) seconds (buffer: \(samples.count) samples)")
            
            let streamingAudio = samples

            // ✅ Safety: only skip if buffer hasn't grown
            // After buffer reset, lastAgreedSeconds is 0, so we should always transcribe if there's any audio
            let newAudioDuration = Float(audioDuration) - lastAgreedSeconds
            if newAudioDuration < 0.2 && lastAgreedSeconds > 0 {
                print("[EagerMode] 💤 No new audio to transcribe (new: \(newAudioDuration)s) — skipping this loop")
                return
            }
            
            if lastAgreedSeconds == 0.0 && audioDuration > 0.1 {
                print("[EagerMode] 🎯 Fresh buffer with new audio (\(audioDuration)s), transcribing from start")
            }
            
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
            
            // CRITICAL FIX: Process result and handle hypothesis advancement
            guard let result = transcription else {
                print("[EagerMode] No transcription result")
                return
            }
            
            // Get new words starting from our baseline
            var newWords = result.allWords.filter { $0.start >= lastAgreedSeconds }
            
            // Filter out hallucinations: reject very short segments that are likely hallucinations
            // Whisper often hallucinates during silence, producing short segments with high probabilities
            if !newWords.isEmpty {
                let segmentStart = newWords.first!.start
                let segmentEnd = newWords.last!.end
                let segmentDuration = segmentEnd - segmentStart
                
                // Check if this is likely a hallucination:
                // 1. Very short duration (< 0.15s) - real speech is usually longer
                // 2. High average word probability (> 0.85) for such short segments is suspicious
                let avgProbability = newWords.map { $0.probability }.reduce(0.0, +) / Float(newWords.count)
                
                // Also check recent audio energy
                let recentEnergy = bufferEnergy.isEmpty ? 0.0 : bufferEnergy.suffix(10).reduce(0.0, +) / Float(min(10, bufferEnergy.count))
                
                if segmentDuration < 0.35 && avgProbability > 0.85 && recentEnergy < Float(silenceThreshold) {
                    print("[EagerMode] ❌ Rejecting hallucination: duration=\(String(format: "%.3f", segmentDuration))s, avgProb=\(String(format: "%.2f", avgProbability)), energy=\(String(format: "%.3f", recentEnergy))")
                    // Clear the words to prevent them from being processed
                    newWords = []
                } else if segmentDuration < 0.35 && avgProbability > 0.9 {
                    // Even without low energy, very short + very high prob is suspicious
                    print("[EagerMode] ⚠️ Suspicious short segment: duration=\(String(format: "%.3f", segmentDuration))s, avgProb=\(String(format: "%.2f", avgProbability)) - keeping but may be hallucination")
                }
            }
            
            print("[EagerMode] Got \(newWords.count) new words from transcription")
            print("[EagerMode] New words: \"\((newWords.map { $0.word }).joined())\"")
            
            // If we have a previous result, find agreement
            if let prevResult = prevResult {
                let prevWords = prevResult.allWords.filter { $0.start >= lastAgreedSeconds }
                let commonPrefix = TranscriptionUtilities.findLongestCommonPrefix(prevWords, newWords)
                
                print("[EagerMode] Prev: \"\((prevWords.map { $0.word }).joined())\"")
                print("[EagerMode] Next: \"\((newWords.map { $0.word }).joined())\"")
                print("[EagerMode] Common prefix: \"\((commonPrefix.map { $0.word }).joined())\" (\(commonPrefix.count) words)")
                
                // Check if hypothesis has been stable (same for multiple iterations)
                let currentHypothesis = newWords.map { $0.word }.joined()
                let isStableNow = isTextStable() && !hypothesisText.isEmpty && currentHypothesis == hypothesisText
                
                // If we have enough agreement, confirm words and advance
                if commonPrefix.count >= Int(tokenConfirmationsNeeded) {
                    // Keep last N words as agreement baseline
                    lastAgreedWords = Array(commonPrefix.suffix(Int(tokenConfirmationsNeeded)))
                    
                    // Confirm all except the last N words
                    let wordsToConfirm = commonPrefix.prefix(commonPrefix.count - Int(tokenConfirmationsNeeded))
                    
                    // CRITICAL: If wordsToConfirm is empty BUT hypothesis is stable, finalize it
                    if wordsToConfirm.isEmpty && isStableNow {
                        print("[EagerMode] 🔒 Hypothesis stable with exact agreement - finalizing all \(commonPrefix.count) words")
                        
                        // Finalize all agreed words
                        confirmedWords.append(contentsOf: commonPrefix)
                        
                        // Advance past the finalized content
                        if let lastWord = commonPrefix.last {
                            lastAgreedSeconds = lastWord.end
                            print("[EagerMode] ✅ Advanced lastAgreedSeconds → \(lastAgreedSeconds)s (end of '\(lastWord.word)')")
                        }
                        
                        // Clear agreement baseline for fresh start
                        lastAgreedWords = []
                        hypothesisWords = []
                        recentHypotheses.removeAll()
                    } else if !wordsToConfirm.isEmpty {
                        // Normal case: confirm some words, keep others as hypothesis
                        confirmedWords.append(contentsOf: wordsToConfirm)
                        
                        // CRITICAL: Advance lastAgreedSeconds to the END of the last confirmed word
                        // This ensures we don't re-transcribe confirmed content
                        if let lastConfirmedWord = wordsToConfirm.last {
                            lastAgreedSeconds = lastConfirmedWord.end
                            print("[EagerMode] ✅ Advanced lastAgreedSeconds → \(lastAgreedSeconds)s (end of '\(lastConfirmedWord.word)')")
                        }
                        
                        // Update hypothesis to be everything after confirmed
                        hypothesisWords = Array(newWords.suffix(Int(tokenConfirmationsNeeded)))
                    } else {
                        // Edge case: exact agreement but not stable yet - just update hypothesis
                        hypothesisWords = Array(newWords.suffix(Int(tokenConfirmationsNeeded)))
                    }
                    
                    let currentWords = confirmedWords.map { $0.word }.joined()
                    print("[EagerMode] Confirmed words: \(currentWords)")
                    
                } else {
                    // Not enough agreement - this happens when transcription changes significantly
                    print("[EagerMode] ⚠️ Insufficient agreement (\(commonPrefix.count) < \(Int(tokenConfirmationsNeeded)))")
                    
                    // If previous hypothesis was stable and we're seeing new different content,
                    // it likely means the user continued speaking
                    if !hypothesisWords.isEmpty && isTextStable() {
                        print("[EagerMode] 🔄 Finalizing previous stable hypothesis before processing new speech")
                        
                        // Finalize the stable hypothesis
                        confirmedWords.append(contentsOf: hypothesisWords)
                        if let lastHypWord = hypothesisWords.last {
                            lastAgreedSeconds = lastHypWord.end
                            print("[EagerMode] 🔒 Advanced lastAgreedSeconds → \(lastAgreedSeconds)s after finalizing hypothesis")
                        }
                        
                        // Clear hypothesis for new content
                        hypothesisWords = []
                        lastAgreedWords = []
                        recentHypotheses.removeAll()
                    }
                    
                    // Use new words as hypothesis
                    hypothesisWords = newWords
                }
            } else {
                // First result - everything is hypothesis
                print("[EagerMode] First result - treating as hypothesis")
                hypothesisWords = newWords
            }
            
            prevResult = result
            eagerResults.append(transcription)
            
            // Assemble final text
            confirmedText = confirmedWords.map { $0.word }.joined()
            hypothesisText = hypothesisWords.map { $0.word }.joined()
            
            // Track hypothesis history for stability checks
            recentHypotheses.append(hypothesisText)
            if recentHypotheses.count > 5 {
                recentHypotheses.removeFirst()
            }
            
            print("[EagerMode] Confirmed: '\(confirmedText)' | Hypothesis: '\(hypothesisText)'")
            
            // Update callbacks
            let combinedText = confirmedText + hypothesisText
            onLiveUpdate(combinedText, confirmedText)
            
            // Update metrics
            tokensPerSecond = result.timings.tokensPerSecond
            firstTokenTime = result.timings.firstTokenTime
            let totalAudio = Double(samples.count) / 16000.0
            let totalInferenceTime = result.timings.fullPipeline
            effectiveRealTimeFactor = totalInferenceTime / totalAudio
        }
}
