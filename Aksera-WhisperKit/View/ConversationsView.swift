//
//  HomeView.swift
//  Aksera
//
//  Created by Ivan Setiawan on 20/10/25.
//

import SwiftUI
import SwiftData

struct ConversationsView: View {
    @State private var selectedConversation: Conversation?

    // Model context
    @Environment(\.modelContext) private var modelContext

    // Querying all conversations
    @Query(sort: \Conversation.creationDate, order: .reverse, animation: .snappy) private var conversations: [Conversation]

    // View properties
    @State private var deleteConversationAlert: Bool = false
    @State private var isAddingNewConversation = false

    var body: some View {
        NavigationSplitView {
            conversationsList
                .alert(
                    "Are you sure you want to permanently remove \(selectedConversation?.title.isEmpty == false ? selectedConversation!.title : "this conversation")?",
                    isPresented: $deleteConversationAlert,
                    presenting: selectedConversation
                ) { _ in
                    Button("Cancel", role: .cancel) {}
                    Button("Delete", role: .destructive) {
                        deleteSelectedConversation()
                    }
                } message: { _ in
                    Text("This action cannot be undone.")
                }
        } detail: {
            if let conversation = selectedConversation {
                ConversationDetailView(conversation: conversation, isNewConversation: isAddingNewConversation)
                .onChange(of: conversation, initial: true) { _,_  in
                    isAddingNewConversation = false
                }
                
            } else {
                Text("Select or Create a Conversation")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Aksera")
    }

    // Extracted list to reduce type-checking complexity
    private var conversationsList: some View {
        List(selection: $selectedConversation) {
            ForEach(conversations, id: \.persistentModelID) { conversation in
                ConversationRow(title: conversation.title, creationDate: conversation.creationDate)
                    .tag(conversation)
                    .contextMenu {
                        Button("Delete") {
                            deleteConversationAlert = true
                        }
                    }
            }
        }
        .onDeleteCommand(perform: { deleteConversationAlert = true })
        .listStyle(.sidebar)
        .toolbar {
            ToolbarItem {
                Button(action: addConversation) {
                    Label("New Conversation", systemImage: "square.and.pencil")
                }
            }
        }
    }

    private func addConversation() {
        withAnimation {
            let newConversation = Conversation(creationDate: Date(), title: "")
            modelContext.insert(newConversation)
            selectedConversation = newConversation
            isAddingNewConversation = true
        }
    }

    private func deleteSelectedConversation() {
        withAnimation {
            if let conversationToDelete = selectedConversation {
                modelContext.delete(conversationToDelete)
                // Clear selection after deletion
                selectedConversation = nil
            }
        }
    }
}

// Small row view to keep the List item simple for the type-checker
private struct ConversationRow: View {
    let title: String
    let creationDate: Date
    var body: some View {
        VStack(alignment: .leading) {
            Text(title.isEmpty ? "Untitled" : title)
                .padding(0)
            Text(creationDate.formatted(date: .abbreviated, time: .shortened))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(0)
        }
        .padding(5)
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [Conversation.self], inMemory: true)
}
