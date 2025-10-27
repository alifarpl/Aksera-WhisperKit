//
//  Conversation.swift
//  Aksera
//
//  Created by Ivan Setiawan on 23/10/25.
//

import SwiftUI
import SwiftData

enum BubbleInputType: String, Codable {
    case text
    case speech
}

@Model
final class Bubble: Identifiable {
    @Attribute(.unique) var id: UUID
    var conversation: Conversation?
    var creationDate: Date
    var type: BubbleInputType
    var outputText: String
    
    init(id: UUID = UUID(), conversation: Conversation? = nil, creationDate: Date, type: BubbleInputType, outputText: String) {
        self.id = id
        self.conversation = conversation
        self.creationDate = creationDate
        self.type = type
        self.outputText = outputText
    }
}

