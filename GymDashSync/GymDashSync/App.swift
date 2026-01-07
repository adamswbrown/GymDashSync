//
//  App.swift
//  GymDashSync
//
//  Copyright (c) 2024
//  Licensed under the MIT License.

import SwiftUI
import Combine

@main
struct GymDashSyncApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState()
    
    var body: some Scene {
        WindowGroup {
            if appState.hasClientId {
                ContentView()
                    .environmentObject(appState)
            } else {
                PairingView()
                    .environmentObject(appState)
            }
        }
    }
}

class AppState: ObservableObject {
    @Published var hasClientId: Bool {
        didSet {
            UserDefaults.standard.set(hasClientId, forKey: "GymDashSync.HasClientId")
        }
    }
    
    init() {
        // Check if client_id exists
        let clientId = UserDefaults.standard.string(forKey: "GymDashSync.ClientId")
        self.hasClientId = clientId != nil && !clientId!.isEmpty
    }
    
    func checkClientId() {
        let clientId = UserDefaults.standard.string(forKey: "GymDashSync.ClientId")
        self.hasClientId = clientId != nil && !clientId!.isEmpty
    }
    
    func clearClientId() {
        UserDefaults.standard.removeObject(forKey: "GymDashSync.ClientId")
        self.hasClientId = false
    }
}

