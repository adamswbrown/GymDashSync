//
//  SyncViewModel.swift
//  GymDashSync
//
//  Copyright (c) 2024
//  Licensed under the MIT License.

import Foundation
import SwiftUI
import Combine
import HealthKit

class SyncViewModel: ObservableObject {
    @Published var isAuthorized: Bool = false
    @Published var isSyncing: Bool = false
    @Published var lastSyncDate: Date?
    @Published var lastError: AppError?
    @Published var lastSyncResults: [SyncResult] = []
    @Published var healthKitError: AppError?
    
    private let syncManager: SyncManager
    private let errorHistory = ErrorHistory.shared
    private var cancellables = Set<AnyCancellable>()
    
    init() {
        self.syncManager = SyncManager()
        
        // Observe sync status changes
        syncManager.onSyncStatusChanged = { [weak self] syncing, lastSync, error in
            DispatchQueue.main.async {
                self?.isSyncing = syncing
                self?.lastSyncDate = lastSync
                if let error = error {
                    let appError = ErrorMapper.unknownError(
                        message: "Sync error: \(error.localizedDescription)",
                        error: error
                    )
                    self?.lastError = appError
                    self?.errorHistory.add(appError)
                }
                
                // Update sync results from backend store
                if !syncing, let results = self?.syncManager.backendStore.lastSyncResults {
                    self?.lastSyncResults = results
                    
                    // Check for errors in results
                    if let failedResult = results.first(where: { !$0.success }),
                       let error = failedResult.error {
                        self?.lastError = error
                        self?.errorHistory.add(error)
                    }
                }
            }
        }
        
        // Track sync results from backend store
        syncManager.backendStore.onSyncComplete = { [weak self] results in
            DispatchQueue.main.async {
                self?.lastSyncResults = results
            }
        }
        
        // Check initial authorization status
        checkAuthorizationStatus()
        
        // Start observing for changes
        syncManager.startObserving()
        
        // Listen for app becoming active (user may have changed permissions in Settings)
        // Also listen for authorization status changes from test reads
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("HealthKitAuthorizationStatusChanged"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            print("[SyncViewModel] Received HealthKitAuthorizationStatusChanged notification - reading updated status")
            // Read the updated value directly (notification is posted AFTER isAuthorized is updated)
            // Don't call checkAuthorizationStatus() again as it would trigger another test read
            self?.isAuthorized = self?.syncManager.isAuthorized ?? false
        }
    }
    
    func checkAuthorizationStatus() {
        syncManager.checkAuthorizationStatus()
        isAuthorized = syncManager.isAuthorized
    }
    
    /// Requests HealthKit permissions for workout data
    ///
    /// HealthKit best practice: Always handle partial authorization.
    /// User may grant some types and deny others - this is expected and acceptable.
    func requestWorkoutPermissions() {
        // Check availability first (surfaces simulator limitations)
        guard HKHealthStore.isHealthDataAvailable() else {
            let appError = ErrorMapper.healthKitError(
                message: "HealthKit is not available",
                detail: "HealthKit requires a physical iPhone. It is not available on iPad or iOS Simulator. Please test on a physical device.",
                healthKitError: "HKHealthStore.isHealthDataAvailable() = false"
            )
            healthKitError = appError
            errorHistory.add(appError)
            return
        }
        
        syncManager.requestWorkoutPermissions { [weak self] success, error in
            DispatchQueue.main.async {
                self?.checkAuthorizationStatus()
                
                // HealthKit may return success=true even if user denied some types
                // This is expected - we handle partial authorization
                if let error = error {
                    let appError = ErrorMapper.healthKitError(
                        message: "Workout permission request failed",
                        detail: error.localizedDescription,
                        healthKitError: (error as NSError).localizedDescription
                    )
                    self?.healthKitError = appError
                    self?.errorHistory.add(appError)
                } else if !success {
                    // User denied permissions - must reset in Settings
                    let appError = ErrorMapper.healthKitError(
                        message: "Workout permission denied",
                        detail: "User denied workout data access. To reset: Settings → Privacy & Security → Health → GymDash Sync"
                    )
                    self?.healthKitError = appError
                    self?.errorHistory.add(appError)
                }
                // If success=true, permissions were granted (even if partial)
            }
        }
    }
    
    /// Requests HealthKit permissions for profile metrics (height, weight, body fat)
    ///
    /// HealthKit best practice: Always handle partial authorization.
    /// User may grant some types and deny others - this is expected and acceptable.
    func requestProfilePermissions() {
        // Check availability first (surfaces simulator limitations)
        guard HKHealthStore.isHealthDataAvailable() else {
            let appError = ErrorMapper.healthKitError(
                message: "HealthKit is not available",
                detail: "HealthKit requires a physical iPhone. It is not available on iPad or iOS Simulator. Please test on a physical device.",
                healthKitError: "HKHealthStore.isHealthDataAvailable() = false"
            )
            healthKitError = appError
            errorHistory.add(appError)
            return
        }
        
        syncManager.requestProfilePermissions { [weak self] success, error in
            DispatchQueue.main.async {
                self?.checkAuthorizationStatus()
                
                // HealthKit may return success=true even if user denied some types
                // This is expected - we handle partial authorization
                if let error = error {
                    let appError = ErrorMapper.healthKitError(
                        message: "Profile permission request failed",
                        detail: error.localizedDescription,
                        healthKitError: (error as NSError).localizedDescription
                    )
                    self?.healthKitError = appError
                    self?.errorHistory.add(appError)
                } else if !success {
                    // User denied permissions - must reset in Settings
                    let appError = ErrorMapper.healthKitError(
                        message: "Profile permission denied",
                        detail: "User denied profile data access. To reset: Settings → Privacy & Security → Health → GymDash Sync"
                    )
                    self?.healthKitError = appError
                    self?.errorHistory.add(appError)
                }
                // If success=true, permissions were granted (even if partial)
            }
        }
    }
    
    func syncNow() {
        // Use BackendSyncStore directly to get detailed results
        guard let clientId = UserDefaults.standard.string(forKey: "GymDashSync.ClientId"),
              !clientId.isEmpty else {
            let appError = ErrorMapper.validationError(
                message: "No client ID found",
                detail: "Please pair your device first"
            )
            lastError = appError
            errorHistory.add(appError)
            return
        }
        
        isSyncing = true
        lastError = nil
        
        // Note: This is a simplified sync - in production, you'd want to collect
        // objects from HealthKit first, then sync them
        // For now, we rely on the HDS framework's automatic sync
        
        syncManager.syncNow { [weak self] success, error in
            DispatchQueue.main.async {
                self?.isSyncing = false
                if let error = error {
                    let appError = ErrorMapper.unknownError(
                        message: "Sync failed",
                        error: error
                    )
                    self?.lastError = appError
                    self?.errorHistory.add(appError)
                } else if success {
                    // Sync results are already updated via onSyncComplete callback
                    // If no results were captured, create a placeholder success result
                    if self?.lastSyncResults.isEmpty ?? true {
                        self?.lastSyncResults = [SyncResult(
                            success: true,
                            timestamp: Date(),
                            recordsReceived: 0,
                            recordsInserted: 0
                        )]
                    }
                }
            }
        }
    }
    
    func resetAuthorization() {
        syncManager.resetAuthorization()
        checkAuthorizationStatus()
        lastError = nil
        healthKitError = nil
    }
    
    func clearLastError() {
        lastError = nil
    }
    
    func clearHealthKitError() {
        healthKitError = nil
    }
}

