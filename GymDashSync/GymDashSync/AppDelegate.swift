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
}

