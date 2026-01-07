//
//  SyncManager.swift
//  GymDashSync
//
//  Copyright (c) 2024
//  Licensed under the MIT License.

import Foundation
import HealthKit
import HealthDataSync

/// Manages HealthKit sync operations
public class SyncManager: NSObject, HDSQueryObserverDelegate {
    private var hdsManager: HDSManagerProtocol
    let backendStore: BackendSyncStore // Made internal for access to sync results
    private var workoutObserver: HDSQueryObserver?
    private var profileObservers: [HDSQueryObserver] = []
    
    public var onSyncStatusChanged: ((Bool, Date?, Error?) -> Void)?
    private(set) public var lastSyncDate: Date?
    private(set) public var isAuthorized: Bool = false
    private(set) public var isSyncing: Bool = false
    
    public init(backendConfig: BackendConfig = .default) {
        self.hdsManager = HDSManagerFactory.manager()
        self.backendStore = BackendSyncStore(config: backendConfig)
        super.init()
        
        // Set ourselves as the observer delegate
        hdsManager.observerDelegate = self
        
        // Track sync results for dev mode
        backendStore.onSyncComplete = { [weak self] results in
            // Results are stored in backendStore.lastSyncResults
            // Can be accessed by view models for diagnostics
        }
        
        // Check authorization status
        checkAuthorizationStatus()
    }
    
    // MARK: - Permission Management
    
    public func requestWorkoutPermissions(completion: @escaping (Bool, Error?) -> Void) {
        // Add workout observer
        hdsManager.addObjectTypes([WorkoutData.self], externalStore: backendStore)
        
        // Request permissions for workout-related types
        hdsManager.requestPermissionsForAllObservers { [weak self] success, error in
            DispatchQueue.main.async {
                self?.checkAuthorizationStatus()
                completion(success, error)
            }
        }
    }
    
    public func requestProfilePermissions(completion: @escaping (Bool, Error?) -> Void) {
        // Add profile metric observers
        hdsManager.addObjectTypes([HeightData.self, WeightData.self, BodyFatData.self], externalStore: backendStore)
        
        // Request permissions for profile types
        hdsManager.requestPermissionsForAllObservers { [weak self] success, error in
            DispatchQueue.main.async {
                self?.checkAuthorizationStatus()
                completion(success, error)
            }
        }
    }
    
    public func checkAuthorizationStatus() {
        let store = HKHealthStore()
        
        // Check workout authorization
        let workoutType = HKObjectType.workoutType()
        let workoutStatus = store.authorizationStatus(for: workoutType)
        
        // Check profile metric authorization
        let heightType = HKQuantityType.quantityType(forIdentifier: .height)!
        let weightType = HKQuantityType.quantityType(forIdentifier: .bodyMass)!
        let heightStatus = store.authorizationStatus(for: heightType)
        let weightStatus = store.authorizationStatus(for: weightType)
        
        // Consider authorized if at least workout is authorized
        isAuthorized = workoutStatus == .sharingAuthorized || workoutStatus == .notDetermined
    }
    
    // MARK: - Sync Operations
    
    public func startObserving() {
        hdsManager.startObserving()
    }
    
    public func stopObserving() {
        hdsManager.stopObserving()
    }
    
    public func syncNow(completion: @escaping (Bool, Error?) -> Void) {
        guard !isSyncing else {
            completion(false, NSError(domain: "SyncManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Sync already in progress"]))
            return
        }
        
        isSyncing = true
        onSyncStatusChanged?(true, lastSyncDate, nil)
        
        // Trigger a manual sync by temporarily stopping and starting observation
        // This will cause the observers to check for changes
        hdsManager.stopObserving()
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self else { return }
            self.hdsManager.startObserving()
            
            // Note: Actual sync completion will be reported via didFinishExecution
            // For now, we'll set a timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                if self.isSyncing {
                    self.isSyncing = false
                    self.lastSyncDate = Date()
                    self.onSyncStatusChanged?(false, self.lastSyncDate, nil)
                    completion(true, nil)
                }
            }
        }
    }
    
    public func resetAuthorization() {
        // Clear stored authorization state
        // Note: HealthKit doesn't provide a way to revoke permissions programmatically
        // User must do this in Settings
        UserDefaults.standard.removeObject(forKey: "GymDashSync.ClientId")
        isAuthorized = false
        onSyncStatusChanged?(false, nil, nil)
    }
    
    // MARK: - HDSQueryObserverDelegate
    
    public func batchSize(for observer: HDSQueryObserver) -> Int? {
        return 25 // Default batch size
    }
    
    public func shouldExecute(for observer: HDSQueryObserver, completion: @escaping (Bool) -> Void) {
        // Always allow sync execution
        completion(true)
    }
    
    public func didFinishExecution(for observer: HDSQueryObserver, error: Error?) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            if error == nil {
                self.lastSyncDate = Date()
            }
            
            // Check if all observers are done (simplified - in production you'd track each observer)
            self.isSyncing = false
            self.onSyncStatusChanged?(false, self.lastSyncDate, error)
        }
    }
}

