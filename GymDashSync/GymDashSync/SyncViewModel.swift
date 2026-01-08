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
    @Published var workoutsSynced: Int = 0
    @Published var profileMetricsSynced: Int = 0
    @Published var mostRecentWorkoutSynced: WorkoutData? = nil
    @Published var backendHostname: String = ""
    
    private let syncManager: SyncManager
    private let errorHistory = ErrorHistory.shared
    private var cancellables = Set<AnyCancellable>()
    
    init() {
        self.syncManager = SyncManager()
        
        // Extract backend hostname from config
        self.backendHostname = syncManager.backendStore.config.hostname
        
        // Set up callback for most recent workout changes
        syncManager.backendStore.onMostRecentWorkoutChanged = { [weak self] workout in
            DispatchQueue.main.async {
                self?.mostRecentWorkoutSynced = workout
            }
        }
        
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
                print("[SyncViewModel] onSyncComplete callback fired with \(results.count) result(s)")
                self?.lastSyncResults = results
                print("[SyncViewModel] lastSyncResults updated, now has \(self?.lastSyncResults.count ?? 0) result(s)")
                
                // Separate workout and profile metric results by checking endpoint
                var workoutCount = 0
                var profileMetricCount = 0
                
                for result in results {
                    if let endpoint = result.endpoint {
                        if endpoint.contains("workouts") {
                            workoutCount += result.recordsInserted
                        } else if endpoint.contains("profile-metrics") {
                            profileMetricCount += result.recordsInserted
                        }
                    }
                }
                
                self?.workoutsSynced = workoutCount
                self?.profileMetricsSynced = profileMetricCount
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
    
    /// Requests all HealthKit permissions in a single authorization request
    /// This ensures only one permission dialog is shown to the user
    func requestAllPermissions() {
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
        
        syncManager.requestAllPermissions { [weak self] success, error in
            DispatchQueue.main.async {
                // Update authorization status after permission request
                // The syncManager uses test reads to verify actual access, which is more reliable
                // than authorizationStatus which only checks sharing (read+write) permissions
                self?.checkAuthorizationStatus()
                
                // Wait a moment for checkAuthorizationStatus to complete (it may trigger test reads)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    // Check the actual authorization state from test reads
                    let isActuallyAuthorized = self?.syncManager.isAuthorized ?? false
                    
                    // Only show errors if there was a real error OR if we're actually not authorized
                    if let error = error {
                        let appError = ErrorMapper.healthKitError(
                            message: "Permission request failed",
                            detail: error.localizedDescription,
                            healthKitError: (error as NSError).localizedDescription
                        )
                        self?.healthKitError = appError
                        self?.errorHistory.add(appError)
                    } else if !isActuallyAuthorized {
                        // Only show denied error if we're actually not authorized (after test reads)
                        let appError = ErrorMapper.healthKitError(
                            message: "Permissions denied",
                            detail: "HealthKit access was denied. To enable: Settings → Privacy & Security → Health → GymDashSync → Turn on the data types you want to share."
                        )
                        self?.healthKitError = appError
                        self?.errorHistory.add(appError)
                    } else {
                        // Successfully authorized (verified via test reads)
                        // Clear any previous errors
                        self?.healthKitError = nil
                    }
                }
            }
        }
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
                // Update authorization status after permission request
                // The syncManager uses test reads to verify actual access, which is more reliable
                // than authorizationStatus which only checks sharing (read+write) permissions
                self?.checkAuthorizationStatus()
                
                // Wait a moment for checkAuthorizationStatus to complete (it may trigger test reads)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    // Check the actual authorization state from test reads
                    let isActuallyAuthorized = self?.syncManager.isAuthorized ?? false
                    
                    // Only show errors if there was a real error OR if we're not actually authorized
                if let error = error {
                    let appError = ErrorMapper.healthKitError(
                        message: "Workout permission request failed",
                        detail: error.localizedDescription,
                        healthKitError: (error as NSError).localizedDescription
                    )
                    self?.healthKitError = appError
                    self?.errorHistory.add(appError)
                    } else if !isActuallyAuthorized {
                        // Only show denied error if we're actually not authorized (after test reads)
                        // Don't rely on 'success' parameter which uses authorizationStatus (checks sharing, not read)
                    let appError = ErrorMapper.healthKitError(
                        message: "Workout permission denied",
                            detail: "Workout data access was denied. To enable: Settings → Privacy & Security → Health → GymDashSync → Turn on the data types you want to share."
                    )
                    self?.healthKitError = appError
                    self?.errorHistory.add(appError)
                    } else {
                        // Successfully authorized (verified via test reads)
                        // Clear any previous errors
                        self?.healthKitError = nil
                    }
                }
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
                // Update authorization status after permission request
                // The syncManager uses test reads to verify actual access, which is more reliable
                // than authorizationStatus which only checks sharing (read+write) permissions
                self?.checkAuthorizationStatus()
                
                // Wait a moment for checkAuthorizationStatus to complete (it may trigger test reads)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    // Check the actual authorization state from test reads
                    let isActuallyAuthorized = self?.syncManager.isAuthorized ?? false
                    
                    // Only show errors if there was a real error OR if we're not actually authorized
                if let error = error {
                    let appError = ErrorMapper.healthKitError(
                        message: "Profile permission request failed",
                        detail: error.localizedDescription,
                        healthKitError: (error as NSError).localizedDescription
                    )
                    self?.healthKitError = appError
                    self?.errorHistory.add(appError)
                    } else if !isActuallyAuthorized {
                        // Only show denied error if we're actually not authorized (after test reads)
                        // Don't rely on 'success' parameter which uses authorizationStatus (checks sharing, not read)
                    let appError = ErrorMapper.healthKitError(
                        message: "Profile permission denied",
                            detail: "Profile data access was denied. To enable: Settings → Privacy & Security → Health → GymDashSync → Turn on the data types you want to share."
                    )
                    self?.healthKitError = appError
                    self?.errorHistory.add(appError)
                    } else {
                        // Successfully authorized (verified via test reads)
                        // Clear any previous errors
                        self?.healthKitError = nil
                    }
                }
            }
        }
    }
    
    func syncNow() {
        // Validate prerequisites before syncing
        
        // 1. Check for client ID (required for pairing)
        guard let clientId = UserDefaults.standard.string(forKey: "GymDashSync.ClientId"),
              !clientId.isEmpty else {
            let appError = ErrorMapper.validationError(
                message: "Cannot sync: Device not paired",
                detail: "A client ID is required to sync data. Please pair your device first using the pairing code."
            )
            lastError = appError
            errorHistory.add(appError)
            return
        }
        
        // 2. Check authorization status
        guard isAuthorized else {
            let appError = ErrorMapper.validationError(
                message: "Cannot sync: HealthKit permissions not granted",
                detail: "HealthKit permissions are required to read workout and profile data. Please authorize access in Settings → Privacy & Security → Health → GymDashSync"
            )
            lastError = appError
            errorHistory.add(appError)
            return
        }
        
        isSyncing = true
        lastError = nil
        
        // Reset counts at the start of each sync
        workoutsSynced = 0
        profileMetricsSynced = 0
        
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
                    // Check if we got no data and provide helpful messaging
                    if let results = self?.lastSyncResults {
                        if results.isEmpty {
                            // No sync results at all - this can happen if:
                            // 1. No observers are configured (should be caught earlier)
                            // 2. All objects were filtered out during conversion
                            // 3. No new data since last sync (anchored queries return 0)
                            print("[SyncViewModel] Sync completed with no results - this may be normal if no new data since last sync")
                            self?.lastSyncResults = [SyncResult(
                                success: true,
                                timestamp: Date(),
                                recordsReceived: 0,
                                recordsInserted: 0
                            )]
                        } else {
                            // Check if all results show 0 records
                            let totalReceived = results.reduce(0) { $0 + $1.recordsReceived }
                            let totalInserted = results.reduce(0) { $0 + $1.recordsInserted }
                            let totalDuplicates = results.reduce(0) { $0 + $1.duplicatesSkipped }
                            
                            if totalReceived == 0 && totalInserted == 0 {
                                // No new data was synced - this is expected with anchored queries
                                // (HKAnchoredObjectQuery only returns data NEW since last anchor)
                                print("[SyncViewModel] Sync completed: No new data since last sync (this is normal for incremental sync)")
                                // Don't show this as an error - it's expected behavior
                                // If user wants to see existing data, they need to understand incremental sync behavior
                            } else {
                                // We got some data - show success
                                print("[SyncViewModel] Sync completed successfully: \(totalInserted) inserted, \(totalDuplicates) duplicates skipped")
                            }
                        }
                    } else {
                        // Fallback if results aren't set
                        print("[SyncViewModel] Sync completed but no results available")
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
    
    /// Resets all anchor states and triggers a full re-sync
    func forceResync() {
        syncManager.resetAllAnchors()
        // Trigger sync after a brief delay to ensure anchors are cleared
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.syncNow()
        }
    }
    
    func clearLastError() {
        lastError = nil
    }
    
    func clearHealthKitError() {
        healthKitError = nil
    }
}

