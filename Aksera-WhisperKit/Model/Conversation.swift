//
//  Conversation.swift
//  Aksera
//
//  Created by Ivan Setiawan on 19/10/25.
//

import SwiftUI
import SwiftData

@Model
final class Conversation: Identifiable {
    @Attribute(.unique) var id: UUID
    var creationDate: Date
    var title: String
    
    // Relationship
    @Relationship(deleteRule: .cascade, inverse: \Bubble.conversation)
    var bubbles: [Bubble] = []
    
    init(id: UUID = UUID(), creationDate: Date, title: String) {
        self.id = id
        self.creationDate = creationDate
        self.title = title
    }
    
}

