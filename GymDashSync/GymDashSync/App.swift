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
            if appState.hasCompletedOnboarding {
                ContentView()
                    .environmentObject(appState)
            } else {
                OnboardingView()
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
    
    @Published var hasCompletedOnboarding: Bool {
        didSet {
            UserDefaults.standard.set(hasCompletedOnboarding, forKey: "GymDashSync.HasCompletedOnboarding")
        }
    }
    
    init() {
        let clientId = UserDefaults.standard.string(forKey: "GymDashSync.ClientId")
        let hasClientIdLocal = clientId != nil && !(clientId!.isEmpty)
        self.hasClientId = hasClientIdLocal

        let onboardingComplete = UserDefaults.standard.bool(forKey: "GymDashSync.HasCompletedOnboarding")
        self.hasCompletedOnboarding = onboardingComplete && hasClientIdLocal
    }
    
    func checkClientId() {
        let clientId = UserDefaults.standard.string(forKey: "GymDashSync.ClientId")
        self.hasClientId = clientId != nil && !clientId!.isEmpty
        
        // Update onboarding status if client ID changed
        if !hasClientId {
            hasCompletedOnboarding = false
        }
    }
    
    func completeOnboarding() {
        // Mark onboarding as complete (user has paired and granted permissions)
        self.hasCompletedOnboarding = true
    }
    
    func clearClientId() {
        UserDefaults.standard.removeObject(forKey: "GymDashSync.ClientId")
        UserDefaults.standard.removeObject(forKey: "GymDashSync.HasCompletedOnboarding")
        self.hasClientId = false
        self.hasCompletedOnboarding = false
    }
}

