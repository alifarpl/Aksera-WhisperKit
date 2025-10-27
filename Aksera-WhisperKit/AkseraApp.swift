//
//  AkseraApp.swift
//  Aksera
//
//  Created by Ivan Setiawan on 19/10/25.
//

import SwiftUI
import SwiftData

@main
struct Aksera_WhisperKitApp: App {
    
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Conversation.self,
        ])
        
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()
    
    var body: some Scene {
        WindowGroup {
            ContentView()
            // Setting min frame
                .frame(minWidth: 320, minHeight: 400)
        }
        .windowResizability(.contentSize)
        
        // Add data model
        .modelContainer(sharedModelContainer)
    }
}
