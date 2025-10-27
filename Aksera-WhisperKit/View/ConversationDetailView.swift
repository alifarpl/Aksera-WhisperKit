//
//  SwiftUIView.swift
//  Aksera
//
//  Created by Ivan Setiawan on 21/10/25.
//

import SwiftUI

struct ConversationDetailView: View {
    
    @Bindable var conversation: Conversation
    var isNewConversation: Bool = false
    
    @FocusState private var titleFieldIsFocused: Bool
    
    var body: some View {
        VStack(alignment: .leading) {
            Text("Created: \(conversation.creationDate.formatted(date: .abbreviated, time: .shortened))")
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .padding(.top)
            
            TextField("Title", text: $conversation.title)
                .focused($titleFieldIsFocused)
                .font(.title)
                .textFieldStyle(.plain)
                .padding(.bottom)
                .padding(.horizontal)
                .onSubmit {
                    titleFieldIsFocused = false
                }
            
            Spacer()
            
        }
        .onChange(of: conversation, initial: true) { _,_  in
            if isNewConversation {
                titleFieldIsFocused = true
            }
        }
    }
}

#Preview {
    @Previewable @State var sampleConversation = Conversation(creationDate: Date(), title: "Sample")
    ConversationDetailView(conversation: sampleConversation)
}
