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
        
        // Start observing for HealthKit changes
        syncManager?.startObserving()
        
        return true
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

