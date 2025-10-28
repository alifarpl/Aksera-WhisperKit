//
//  SwiftUIView.swift
//  Aksera
//
//  Created by Ivan Setiawan on 21/10/25.
//

import SwiftUI
import SwiftData
import AVFoundation

struct ConversationDetailView: View {
    
    @Bindable var conversation: Conversation
    var isNewConversation: Bool = false
    
    @FocusState private var titleFieldIsFocused: Bool
    
    // Transcription
    @State private var transcriptionManager: TranscriptionManager?
    @State private var isRecording: Bool = false
    @State private var currentLiveText: String = ""
    @State private var currentFinalizedText: String = ""
    @State private var errorMessage: String?
    @State private var showError: Bool = false
    
    // Model context for saving bubbles
    @Environment(\.modelContext) private var modelContext
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header section
            VStack(alignment: .leading) {
                Text("Created: \(conversation.creationDate.formatted(date: .abbreviated, time: .shortened))")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
                    .padding(.top)
                
                TextField("Title", text: $conversation.title)
                    .focused($titleFieldIsFocused)
                    .font(.title)
                    .textFieldStyle(.plain)
                    .padding(.horizontal)
                    .onSubmit {
                        titleFieldIsFocused = false
                    }
            }
            
            Divider()
            
            // Bubbles/Messages Section
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        // Show existing saved bubbles
                        ForEach(conversation.bubbles.sorted(by: { $0.creationDate < $1.creationDate })) { bubble in
                            BubbleView(bubble: bubble)
                                .id(bubble.id)
                        }
                        
                        // Show live transcription in real-time (like typing indicator)
                        if isRecording {
                            LiveBubbleView(
                                liveText: currentLiveText,
                                finalizedText: currentFinalizedText
                            )
                            .id("live-bubble")
                        }
                    }
                    .padding()
                }
                .onChange(of: currentLiveText) { _, _ in
                    // Auto-scroll as new text appears
                    withAnimation {
                        proxy.scrollTo("live-bubble", anchor: .bottom)
                    }
                }
                .onChange(of: conversation.bubbles.count) { _, _ in
                    if let lastBubble = conversation.bubbles.last {
                        withAnimation {
                            proxy.scrollTo(lastBubble.id, anchor: .bottom)
                        }
                    }
                }
            }
            
            Divider()
            
            // Error message
            if showError, let error = errorMessage {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(Color.red.opacity(0.1))
            }
            
            // Recording controls
            HStack(spacing: 12) {
                Button(action: toggleRecording) {
                    HStack {
                        Image(systemName: isRecording ? "stop.circle.fill" : "mic.circle.fill")
                            .font(.title2)
                        Text(isRecording ? "Stop" : "Record")
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(isRecording ? Color.red : Color.blue)
                    .cornerRadius(8)
                }
                .disabled(transcriptionManager == nil && !isRecording)
                
                if isRecording {
                    HStack {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 8, height: 8)
                            .opacity(0.8)
                        Text("Recording...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .transition(.opacity)
                }
                
                Spacer()
            }
            .padding()
        }
        .onChange(of: conversation) { oldValue, newValue in
            // When switching to a different conversation, reset transcription state
            if oldValue.id != newValue.id {
                if isRecording {
                    stopRecording()
                }
                // Reset the transcription manager state
                Task {
                    await transcriptionManager?.reset()
                    await MainActor.run {
                        currentLiveText = ""
                        currentFinalizedText = ""
                    }
                }
            }
            
            if isNewConversation {
                titleFieldIsFocused = true
            }
        }
        .task {
            await initializeTranscriptionManager()
        }
        .onDisappear {
            if isRecording {
                stopRecording()
            }
        }
    }
    
    // MARK: - Transcription Methods
    
    private func initializeTranscriptionManager() async {
        // Capture the conversation ID to ensure we're always saving to the right one
        let conversationID = conversation.id
        
        transcriptionManager = TranscriptionManager(
            onLiveUpdate: { live, finalized in
                Task { @MainActor in
                    // ONLY update the live text display
                    // DO NOT save anything here - only save on silence detection
                    self.currentLiveText = live
                    self.currentFinalizedText = finalized
                }
            },
            onError: { error in
                Task { @MainActor in
                    self.errorMessage = error.localizedDescription
                    self.showError = true
                    self.isRecording = false
                }
            },
            onSilenceDetected: {
                Task { @MainActor in
                    // Silence detected - save current text as a bubble ONLY if on correct conversation
                    if !self.currentLiveText.isEmpty && self.conversation.id == conversationID {
                        self.saveBubbleToCurrentConversation(text: self.currentLiveText)
                        
                        // Clear for next bubble
                        self.currentLiveText = ""
                        self.currentFinalizedText = ""
                    }
                }
            }
        )
    }
    
    private func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            Task {
                await startRecording()
            }
        }
    }
    
    private func startRecording() async {
        // Request microphone permission
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        guard granted else {
            errorMessage = "Microphone permission denied. Please enable it in System Settings."
            showError = true
            return
        }
        
        guard let manager = transcriptionManager else {
            errorMessage = "Transcription manager not initialized"
            showError = true
            return
        }
        
        do {
            try await manager.start()
            await MainActor.run {
                isRecording = true
                showError = false
                currentLiveText = ""
                currentFinalizedText = ""
            }
        } catch {
            await MainActor.run {
                errorMessage = "Failed to start recording: \(error.localizedDescription)"
                showError = true
                isRecording = false
            }
        }
    }
    
    private func stopRecording() {
        Task {
            // First check which conversation we're on
            let currentConvID = await MainActor.run { conversation.id }
            
            await transcriptionManager?.stop()
            
            await MainActor.run {
                isRecording = false
                
                // Only save if we're still on the SAME conversation
                if !currentLiveText.isEmpty && conversation.id == currentConvID {
                    saveBubbleToCurrentConversation(text: currentLiveText)
                }
                
                currentLiveText = ""
                currentFinalizedText = ""
            }
        }
    }
    
    // MARK: - Helper Methods
    
    private func saveBubbleToCurrentConversation(text: String) {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }
        
        let newBubble = Bubble(
            creationDate: Date(),
            type: .speech,
            outputText: trimmedText
        )
        
        // Insert into model context
        modelContext.insert(newBubble)
        
        // CRITICAL: Link bubble to THIS specific conversation
        newBubble.conversation = conversation
        
        // Add to conversation's bubbles array
        conversation.bubbles.append(newBubble)
        
        // Force save to ensure it's persisted immediately
        try? modelContext.save()
    }
}

// MARK: - Bubble View (Saved/Finalized Messages)
struct BubbleView: View {
    let bubble: Bubble
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: bubble.type == .speech ? "waveform" : "text.alignleft")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(bubble.creationDate.formatted(date: .omitted, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            
            Text(bubble.outputText)
                .padding(12)
                .background(bubble.type == .speech ? Color.blue.opacity(0.15) : Color.gray.opacity(0.1))
                .cornerRadius(12)
        }
    }
}

// MARK: - Live Bubble View (Shows real-time transcription)
struct LiveBubbleView: View {
    let liveText: String
    let finalizedText: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "waveform")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                Text("Transcribing...")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                
                // Animated dots to show it's live
                HStack(spacing: 2) {
                    ForEach(0..<3) { index in
                        Circle()
                            .fill(Color.orange)
                            .frame(width: 4, height: 4)
                            .opacity(0.6)
                            .animation(
                                Animation.easeInOut(duration: 0.6)
                                    .repeatForever()
                                    .delay(Double(index) * 0.2),
                                value: liveText.count
                            )
                    }
                }
            }
            
            if !liveText.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    // Show finalized part (confirmed text)
                    if !finalizedText.isEmpty {
                        Text(finalizedText)
                            .padding(12)
                            .background(Color.green.opacity(0.15))
                            .cornerRadius(12)
                    }
                    
                    // Show live/unfinalized part (text still being processed)
                    let unfinalizedText = String(liveText.dropFirst(finalizedText.count))
                    if !unfinalizedText.isEmpty {
                        Text(unfinalizedText)
                            .padding(12)
                            .background(Color.orange.opacity(0.15))
                            .cornerRadius(12)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(Color.orange.opacity(0.3), lineWidth: 1)
                                    .animation(.easeInOut(duration: 0.5).repeatForever(), value: liveText.count)
                            )
                    }
                }
            } else {
                Text("Listening...")
                    .italic()
                    .foregroundStyle(.secondary)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.1))
                    .cornerRadius(12)
            }
        }
    }
}

#Preview {
    @Previewable @State var sampleConversation = Conversation(creationDate: Date(), title: "Sample")
    ConversationDetailView(conversation: sampleConversation)
        .modelContainer(for: [Conversation.self, Bubble.self], inMemory: true)
}
