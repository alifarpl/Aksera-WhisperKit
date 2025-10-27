//
//  ContentView.swift
//  Aksera-WhisperKit
//
//  Created by Alifa Reppawali on 27/10/25.
//

import SwiftUI

struct ContentView: View {
    var body: some View {
        ConversationsView()
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [Conversation.self], inMemory: true)
}
