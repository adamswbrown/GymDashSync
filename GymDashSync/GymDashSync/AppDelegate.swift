//
//  AppDelegate.swift
//  GymDashSync
//
//  Copyright (c) 2024
//  Licensed under the MIT License.

import UIKit
import SwiftUI
import HealthKit
import HealthDataSync

class AppDelegate: NSObject, UIApplicationDelegate {
    private var syncManager: SyncManager?
    
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        
        // Initialize sync manager early to handle background HealthKit updates
        syncManager = SyncManager()
        
        // Register background task - must be called during app initialization
        BackgroundSyncTask.shared.registerBackgroundTask()
        
        // Start observing for HealthKit changes
        syncManager?.startObserving()
        
        // Request HealthKit permissions on first launch (or when user restarts after denying)
        // This is critical: iOS only registers permissions if the app requests them explicitly
        // Users enabling in Settings without an app request won't work properly
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.requestInitialHealthKitPermissions()
        }
        
        return true
    }
    
    private func requestInitialHealthKitPermissions() {
        guard let syncManager = syncManager else { return }
        
        // Request all permissions in one call
        syncManager.requestAllPermissions { success, error in
            if success {
                print("[AppDelegate] Initial HealthKit permissions request succeeded")
            } else if let error = error {
                print("[AppDelegate] Initial HealthKit permissions request failed: \(error.localizedDescription)")
            } else {
                print("[AppDelegate] HealthKit permissions request completed (user may have denied)")
            }
        }
    }
    
    /// Called when app becomes active (e.g., returning from Settings)
    /// Re-check HealthKit authorization status in case user changed permissions
    func applicationDidBecomeActive(_ application: UIApplication) {
        print("[AppDelegate] App became active - re-checking HealthKit authorization status")
        syncManager?.checkAuthorizationStatus()
        
        // Post notification so views can update
        NotificationCenter.default.post(name: NSNotification.Name("HealthKitAuthorizationStatusChanged"), object: nil)
    }
}

