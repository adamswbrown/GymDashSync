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
///
/// ARCHITECTURAL PRINCIPLES:
/// - HealthKit is a DATA SOURCE ONLY, not an identity provider
/// - Identity comes from pairing codes → client_id (stored in UserDefaults)
/// - All HealthKit data is tagged with client_id before syncing
/// - Missing or partial HealthKit data is expected and tolerated
/// - Replayed data from HealthKit queries is expected (backend deduplicates)
/// - Permissions are requested AFTER pairing (not before)
///
/// This is NOT a demo app - it's a production-ready ingestion client.
public class SyncManager: NSObject, HDSQueryObserverDelegate {
    private var hdsManager: HDSManagerProtocol
    let backendStore: BackendSyncStore // Made internal for access to sync results
    private var workoutObserver: HDSQueryObserver?
    private var profileObservers: [HDSQueryObserver] = []
    
    public var onSyncStatusChanged: ((Bool, Date?, Error?) -> Void)?
    private(set) public var lastSyncDate: Date?
    private(set) public var isAuthorized: Bool = false
    private(set) public var isSyncing: Bool = false
    private var isTestReadInProgress: Bool = false // Guard against redundant test reads
    
    public init(backendConfig: BackendConfig = .default) {
        self.hdsManager = HDSManagerFactory.manager()
        self.backendStore = BackendSyncStore(config: backendConfig)
        super.init()
        
        // Set ourselves as the observer delegate
        hdsManager.observerDelegate = self
        
        // Track sync results for dev mode
        backendStore.onSyncComplete = { results in
            // Results are stored in backendStore.lastSyncResults
            // Can be accessed by view models for diagnostics
        }
        
        // Check authorization status
        checkAuthorizationStatus()
    }
    
    // MARK: - Permission Management
    
    /// Requests HealthKit permissions for workout data
    ///
    /// HealthKit best practice: Always check availability before requesting permissions.
    /// This method:
    /// 1. Checks if HealthKit is available on device
    /// 2. Requests read-only access to workout types
    /// 3. Handles partial authorization gracefully
    /// 4. Surfaces errors clearly in dev mode
    ///
    /// Note: Permissions are requested AFTER pairing (client_id must exist).
    /// Identity is NOT derived from HealthKit - client_id comes from pairing.
    public func requestWorkoutPermissions(completion: @escaping (Bool, Error?) -> Void) {
        // HealthKit availability check (required before any HealthKit operations)
        guard HKHealthStore.isHealthDataAvailable() else {
            let error = ErrorMapper.healthKitError(
                message: "HealthKit is not available on this device",
                detail: "HealthKit requires a physical iPhone. It is not available on iPad or iOS Simulator.",
                healthKitError: "HKHealthStore.isHealthDataAvailable() returned false"
            )
            print("[SyncManager] ERROR: HealthKit not available")
            DispatchQueue.main.async {
                completion(false, error)
            }
            return
        }
        
        print("[SyncManager] Requesting workout permissions...")
        
        // Add workout observer
        hdsManager.addObjectTypes([WorkoutData.self], externalStore: backendStore)
        
        // Request directly from HealthKit
        let store = HKHealthStore()
        var typesToRead: Set<HKObjectType> = []
        
        // Add workout type
        typesToRead.insert(HKObjectType.workoutType())
        
        // Add related quantity types
        if let activeEnergy = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned) {
            typesToRead.insert(activeEnergy)
        }
        if let distance = HKQuantityType.quantityType(forIdentifier: .distanceWalkingRunning) {
            typesToRead.insert(distance)
        }
        if let heartRate = HKQuantityType.quantityType(forIdentifier: .heartRate) {
            typesToRead.insert(heartRate)
        }
        
        print("[SyncManager] Requesting HealthKit authorization for \(typesToRead.count) types...")
        print("[SyncManager] Types to read: \(typesToRead.map { $0.identifier })")
        
        // Check current authorization status before requesting
        for type in typesToRead {
            let status = store.authorizationStatus(for: type)
            print("[SyncManager] Current status for \(type.identifier): \(status.rawValue) (\(status == .sharingAuthorized ? "authorized" : status == .sharingDenied ? "denied" : "not determined"))")
        }
        
        // Request read-only permissions directly from HealthKit
        // NOTE: We do NOT use hdsManager.requestPermissionsForAllObservers because it requests
        // write permissions, and we only need read-only access. The HDS framework observers
        // will work fine with read-only permissions.
        store.requestAuthorization(toShare: nil, read: typesToRead) { success, error in
            print("[SyncManager] HealthKit authorization result: success=\(success), error=\(error?.localizedDescription ?? "none")")
            
            // IMPORTANT: success=true only means the request completed, NOT that permissions were granted
            // The actual authorization status must be checked separately
            
            // Check status again after request (with a small delay to ensure iOS has updated)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                var authorizedCount = 0
                var deniedCount = 0
                
                for type in typesToRead {
                    let status = store.authorizationStatus(for: type)
                    let statusString = status == .sharingAuthorized ? "authorized" : status == .sharingDenied ? "denied" : "not determined"
                    print("[SyncManager] New status for \(type.identifier): \(status.rawValue) (\(statusString))")
                    
                    if status == .sharingAuthorized {
                        authorizedCount += 1
                    } else if status == .sharingDenied {
                        deniedCount += 1
                    }
                }
                
                // Check authorization status (will perform test reads if needed)
                // This is the authoritative check - test reads verify actual read access
                // Always verify authorization via test reads after permission request
                // Don't rely on cached isAuthorized - always check current state
                // authorizationStatus checks sharing (read+write), but we need to verify actual read access
                self.performAuthorizationTestReads { [weak self] isAuthorized in
                    guard let self = self else { return }
                    
                    // Update the cached authorization state
                    let wasAuthorized = self.isAuthorized
                    self.isAuthorized = isAuthorized
                    
                    // Provide clear feedback based on actual status from test reads
                    if isAuthorized {
                        print("[SyncManager] SUCCESS: Permissions granted (verified via test reads)")
                        // Notify observers of status change
                        if wasAuthorized != isAuthorized {
                            NotificationCenter.default.post(name: NSNotification.Name("HealthKitAuthorizationStatusChanged"), object: nil)
                            self.onSyncStatusChanged?(false, self.lastSyncDate, nil)
                        }
                    } else {
                        // Only show denied if we're actually not authorized after test reads
                        if authorizedCount == 0 && deniedCount > 0 {
                    print("[SyncManager] WARNING: \(deniedCount) type(s) denied. User can enable in Settings → Privacy & Security → Health → GymDashSync")
                        } else if authorizedCount == 0 && deniedCount == 0 {
                            print("[SyncManager] INFO: Permissions still not determined - user may not have responded to dialog yet")
                        }
                    }
                    
                    // Call completion with actual authorization state from test reads
                    completion(isAuthorized, error)
                }
            }
        }
    }
    
    /// Requests ALL HealthKit permissions in a single authorization request (workouts + profile metrics)
    /// This ensures only one permission dialog is shown to the user
    public func requestAllPermissions(completion: @escaping (Bool, Error?) -> Void) {
        // HealthKit availability check (required before any HealthKit operations)
        guard HKHealthStore.isHealthDataAvailable() else {
            let error = ErrorMapper.healthKitError(
                message: "HealthKit is not available on this device",
                detail: "HealthKit requires a physical iPhone. It is not available on iPad or iOS Simulator.",
                healthKitError: "HKHealthStore.isHealthDataAvailable() returned false"
            )
            print("[SyncManager] ERROR: HealthKit not available")
            DispatchQueue.main.async {
                completion(false, error)
            }
            return
        }
        
        print("[SyncManager] Requesting all HealthKit permissions in a single request...")
        
        // Add all observers
        hdsManager.addObjectTypes([WorkoutData.self], externalStore: backendStore)
        hdsManager.addObjectTypes([HeightData.self, WeightData.self, BodyFatData.self], externalStore: backendStore)
        
        // Request directly from HealthKit - combine all types into one request
        let store = HKHealthStore()
        var typesToRead: Set<HKObjectType> = []
        
        // Add workout type
        typesToRead.insert(HKObjectType.workoutType())
        
        // Add workout-related quantity types
        if let activeEnergy = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned) {
            typesToRead.insert(activeEnergy)
        }
        if let distance = HKQuantityType.quantityType(forIdentifier: .distanceWalkingRunning) {
            typesToRead.insert(distance)
        }
        if let heartRate = HKQuantityType.quantityType(forIdentifier: .heartRate) {
            typesToRead.insert(heartRate)
        }
        
        // Add profile metric types
        if let height = HKQuantityType.quantityType(forIdentifier: .height) {
            typesToRead.insert(height)
        }
        if let weight = HKQuantityType.quantityType(forIdentifier: .bodyMass) {
            typesToRead.insert(weight)
        }
        if let bodyFat = HKQuantityType.quantityType(forIdentifier: .bodyFatPercentage) {
            typesToRead.insert(bodyFat)
        }
        
        print("[SyncManager] Requesting HealthKit authorization for \(typesToRead.count) types (workouts + profile metrics)...")
        print("[SyncManager] Types to read: \(typesToRead.map { $0.identifier })")
        
        // Check current authorization status before requesting
        for type in typesToRead {
            let status = store.authorizationStatus(for: type)
            print("[SyncManager] Current status for \(type.identifier): \(status.rawValue) (\(status == .sharingAuthorized ? "authorized" : status == .sharingDenied ? "denied" : "not determined"))")
        }
        
        // Request read-only permissions for ALL types in a single call
        // This will show ONE permission dialog with all requested types
        store.requestAuthorization(toShare: nil, read: typesToRead) { success, error in
            print("[SyncManager] HealthKit authorization result (all types): success=\(success), error=\(error?.localizedDescription ?? "none")")
            
            // IMPORTANT: success=true only means the request completed, NOT that permissions were granted
            // The actual authorization status must be checked separately
            
            // Check status again after request (with a small delay to ensure iOS has updated)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                var authorizedCount = 0
                var deniedCount = 0
                
                for type in typesToRead {
                    let status = store.authorizationStatus(for: type)
                    let statusString = status == .sharingAuthorized ? "authorized" : status == .sharingDenied ? "denied" : "not determined"
                    print("[SyncManager] New status for \(type.identifier): \(status.rawValue) (\(statusString))")
                    
                    if status == .sharingAuthorized {
                        authorizedCount += 1
                    } else if status == .sharingDenied {
                        deniedCount += 1
                    }
                }
                
                // Always verify authorization via test reads after permission request
                // This is the authoritative check - test reads verify actual read access
                self.performAuthorizationTestReads { [weak self] isAuthorized in
                    guard let self = self else { return }
                    
                    // Update the cached authorization state
                    let wasAuthorized = self.isAuthorized
                    self.isAuthorized = isAuthorized
                    
                    // Provide clear feedback based on actual status from test reads
                    if isAuthorized {
                        print("[SyncManager] SUCCESS: All permissions granted (verified via test reads)")
                        // Notify observers of status change
                        if wasAuthorized != isAuthorized {
                            NotificationCenter.default.post(name: NSNotification.Name("HealthKitAuthorizationStatusChanged"), object: nil)
                            self.onSyncStatusChanged?(false, self.lastSyncDate, nil)
                        }
                    } else {
                        // Only show denied if we're actually not authorized after test reads
                        if authorizedCount == 0 && deniedCount > 0 {
                            print("[SyncManager] WARNING: \(deniedCount) type(s) denied. User can enable in Settings → Privacy & Security → Health → GymDashSync")
                        } else if authorizedCount == 0 && deniedCount == 0 {
                            print("[SyncManager] INFO: Permissions still not determined - user may not have responded to dialog yet")
                        }
                    }
                    
                    // Call completion with actual authorization state from test reads
                    completion(isAuthorized, error)
                }
            }
        }
    }
    
    /// Requests HealthKit permissions for profile metrics (height, weight, body fat)
    ///
    /// HealthKit best practice: Always check availability before requesting permissions.
    /// Profile metrics use HKQuantityType (not characteristic types - those are read-only from Health app).
    public func requestProfilePermissions(completion: @escaping (Bool, Error?) -> Void) {
        // HealthKit availability check (required before any HealthKit operations)
        guard HKHealthStore.isHealthDataAvailable() else {
            let error = ErrorMapper.healthKitError(
                message: "HealthKit is not available on this device",
                detail: "HealthKit requires a physical iPhone. It is not available on iPad or iOS Simulator.",
                healthKitError: "HKHealthStore.isHealthDataAvailable() returned false"
            )
            print("[SyncManager] ERROR: HealthKit not available")
            DispatchQueue.main.async {
                completion(false, error)
            }
            return
        }
        
        print("[SyncManager] Requesting profile permissions...")
        
        // Add profile metric observers
        hdsManager.addObjectTypes([HeightData.self, WeightData.self, BodyFatData.self], externalStore: backendStore)
        
        // Request directly from HealthKit
        let store = HKHealthStore()
        var typesToRead: Set<HKObjectType> = []
        
        // Add profile metric types
        if let height = HKQuantityType.quantityType(forIdentifier: .height) {
            typesToRead.insert(height)
        }
        if let weight = HKQuantityType.quantityType(forIdentifier: .bodyMass) {
            typesToRead.insert(weight)
        }
        if let bodyFat = HKQuantityType.quantityType(forIdentifier: .bodyFatPercentage) {
            typesToRead.insert(bodyFat)
        }
        
        print("[SyncManager] Requesting HealthKit authorization for \(typesToRead.count) profile types...")
        // Request read-only permissions directly from HealthKit
        // NOTE: We do NOT use hdsManager.requestPermissionsForAllObservers because it requests
        // write permissions, and we only need read-only access. The HDS framework observers
        // will work fine with read-only permissions.
        store.requestAuthorization(toShare: nil, read: typesToRead) { success, error in
            print("[SyncManager] HealthKit profile authorization result: success=\(success), error=\(error?.localizedDescription ?? "none")")
            
            // IMPORTANT: success=true only means the request completed, NOT that permissions were granted
            // The actual authorization status must be checked separately
            
            // Check status again after request (with a small delay to ensure iOS has updated)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                var authorizedCount = 0
                var deniedCount = 0
                
                for type in typesToRead {
                    let status = store.authorizationStatus(for: type)
                    let statusString = status == .sharingAuthorized ? "authorized" : status == .sharingDenied ? "denied" : "not determined"
                    print("[SyncManager] New status for \(type.identifier): \(status.rawValue) (\(statusString))")
                    
                    if status == .sharingAuthorized {
                        authorizedCount += 1
                    } else if status == .sharingDenied {
                        deniedCount += 1
                    }
                }
                
                // Always verify authorization via test reads after permission request
                // Don't rely on cached isAuthorized - always check current state
                // authorizationStatus checks sharing (read+write), but we need to verify actual read access
                self.performAuthorizationTestReads { [weak self] isAuthorized in
                    guard let self = self else { return }
                    
                    // Update the cached authorization state
                    let wasAuthorized = self.isAuthorized
                    self.isAuthorized = isAuthorized
                    
                    // Provide clear feedback based on actual status from test reads
                    if isAuthorized {
                        print("[SyncManager] SUCCESS: Profile permissions granted (verified via test reads)")
                        // Notify observers of status change
                        if wasAuthorized != isAuthorized {
                            NotificationCenter.default.post(name: NSNotification.Name("HealthKitAuthorizationStatusChanged"), object: nil)
                            self.onSyncStatusChanged?(false, self.lastSyncDate, nil)
                        }
                    } else {
                        // Only show denied if we're actually not authorized after test reads
                        if authorizedCount == 0 && deniedCount > 0 {
                    print("[SyncManager] WARNING: \(deniedCount) profile type(s) denied. User can enable in Settings → Privacy & Security → Health → GymDashSync")
                        } else if authorizedCount == 0 && deniedCount == 0 {
                            print("[SyncManager] INFO: Permissions still not determined - user may not have responded to dialog yet")
                        }
                }
                    
                    // Call completion with actual authorization state from test reads
                    completion(isAuthorized, error)
                }
            }
        }
    }
    
    /// Checks HealthKit authorization status
    ///
    /// IMPORTANT: HealthKit has a quirk - `authorizationStatus(for:)` checks SHARING status (read+write),
    /// but we only request READ permissions. This means:
    /// - If user grants read-only in Settings, `authorizationStatus` may still show `.sharingDenied`
    /// - We need to actually try to READ data to verify permissions
    ///
    /// This method:
    /// 1. First checks authorization status (quick check)
    /// 2. If status suggests denied but user says they enabled in Settings, performs a test read
    /// 3. Uses the test read result as the authoritative check
    ///
    /// HealthKit best practice: Never assume permissions persist forever.
    /// Always check availability and authorization status before queries.
    public func checkAuthorizationStatus() {
        let store = HKHealthStore()
        
        // Check if HealthKit is available on this device
        guard HKHealthStore.isHealthDataAvailable() else {
            print("[SyncManager] HealthKit is not available on this device")
            isAuthorized = false
            return
        }
        
        // Quick check using authorization status
        let workoutType = HKObjectType.workoutType()
        let heightType = HKQuantityType.quantityType(forIdentifier: .height)!
        let weightType = HKQuantityType.quantityType(forIdentifier: .bodyMass)!
        let bodyFatType = HKQuantityType.quantityType(forIdentifier: .bodyFatPercentage)!
        
        let workoutStatus = store.authorizationStatus(for: workoutType)
        let heightStatus = store.authorizationStatus(for: heightType)
        let weightStatus = store.authorizationStatus(for: weightType)
        let bodyFatStatus = store.authorizationStatus(for: bodyFatType)
        
        // If any status is .sharingAuthorized, we definitely have access
        let quickCheckAuthorized = workoutStatus == .sharingAuthorized || 
                                   heightStatus == .sharingAuthorized || 
                                   weightStatus == .sharingAuthorized ||
                                   bodyFatStatus == .sharingAuthorized
        
        // Check if any profile types show denied - we need to test read them even if workout is authorized
        let profileTypesDenied = heightStatus == .sharingDenied || 
                                 weightStatus == .sharingDenied || 
                                 bodyFatStatus == .sharingDenied
        
        // If quick check passes AND no profile types show denied, we're definitely authorized
        if quickCheckAuthorized && !profileTypesDenied {
            let wasAuthorized = isAuthorized
            print("[SyncManager] Authorization check: Quick check passed - at least one type is .sharingAuthorized and no profile types denied")
            isAuthorized = true
            
            // Notify if status changed
            if wasAuthorized != isAuthorized {
                print("[SyncManager] Authorization status changed: \(wasAuthorized) -> \(isAuthorized)")
                NotificationCenter.default.post(name: NSNotification.Name("HealthKitAuthorizationStatusChanged"), object: nil)
                onSyncStatusChanged?(false, lastSyncDate, nil)
            }
            return
        }
        
        // If profile types show denied (even if workout is authorized) OR all are denied, perform test reads
        // This handles the case where read-only permissions are granted but sharing status shows denied
        let allDenied = workoutStatus == .sharingDenied && 
                       heightStatus == .sharingDenied && 
                       weightStatus == .sharingDenied &&
                       bodyFatStatus == .sharingDenied
        
        if allDenied || (profileTypesDenied && !quickCheckAuthorized) {
            // Guard against redundant test reads
            if isTestReadInProgress {
                print("[SyncManager] Authorization check: Test read already in progress, skipping duplicate check")
                return
            }
            
            // If we're already authorized, don't re-check
            if isAuthorized {
                print("[SyncManager] Authorization check: Already authorized (from previous test read), skipping redundant check")
                return
            }
            
            if allDenied {
            print("[SyncManager] Authorization check: All types show .sharingDenied, but performing test reads to verify actual access...")
            } else {
                print("[SyncManager] Authorization check: Profile types show .sharingDenied, performing test reads to verify actual read access...")
            }
            isTestReadInProgress = true
            
            // Perform test reads for all types (workout, height, weight, body fat)
            // This is the authoritative check for read-only permissions
            // We consider the app authorized if ANY test read succeeds
            let dispatchGroup = DispatchGroup()
            var workoutAuthorized = false
            var heightAuthorized = false
            var weightAuthorized = false
            var bodyFatAuthorized = false
            
            // Test workout read
            dispatchGroup.enter()
            let workoutTestQuery = HKSampleQuery(
                sampleType: workoutType as HKSampleType,
                predicate: nil,
                limit: 1,
                sortDescriptors: nil
            ) { query, samples, error in
                if error == nil {
                    // Can query (even if no data) = permissions granted
                    workoutAuthorized = true
                    print("[SyncManager] Authorization check: Workout test read SUCCESS")
                } else if let error = error as? HKError, error.code == .errorAuthorizationDenied {
                    print("[SyncManager] Authorization check: Workout test read DENIED")
                } else {
                    // Other error but can query = permissions granted
                    workoutAuthorized = true
                    print("[SyncManager] Authorization check: Workout test read completed (permissions granted, may have no data)")
                }
                dispatchGroup.leave()
            }
            store.execute(workoutTestQuery)
            
            // Test height read
            dispatchGroup.enter()
            let heightTestQuery = HKSampleQuery(
                sampleType: heightType as HKSampleType,
                predicate: nil,
                limit: 1,
                sortDescriptors: nil
            ) { query, samples, error in
                if error == nil {
                    heightAuthorized = true
                    print("[SyncManager] Authorization check: Height test read SUCCESS")
                } else if let error = error as? HKError, error.code == .errorAuthorizationDenied {
                    print("[SyncManager] Authorization check: Height test read DENIED")
                } else {
                    heightAuthorized = true
                    print("[SyncManager] Authorization check: Height test read completed (permissions granted, may have no data)")
                }
                dispatchGroup.leave()
            }
            store.execute(heightTestQuery)
            
            // Test weight read
            dispatchGroup.enter()
            let weightTestQuery = HKSampleQuery(
                sampleType: weightType as HKSampleType,
                predicate: nil,
                limit: 1,
                sortDescriptors: nil
            ) { query, samples, error in
                if error == nil {
                    weightAuthorized = true
                    print("[SyncManager] Authorization check: Weight test read SUCCESS")
                } else if let error = error as? HKError, error.code == .errorAuthorizationDenied {
                    print("[SyncManager] Authorization check: Weight test read DENIED")
                } else {
                    weightAuthorized = true
                    print("[SyncManager] Authorization check: Weight test read completed (permissions granted, may have no data)")
                }
                dispatchGroup.leave()
            }
            store.execute(weightTestQuery)
            
            // Test body fat read
            dispatchGroup.enter()
            let bodyFatTestQuery = HKSampleQuery(
                sampleType: bodyFatType as HKSampleType,
                predicate: nil,
                limit: 1,
                sortDescriptors: nil
            ) { query, samples, error in
                if error == nil {
                    bodyFatAuthorized = true
                    print("[SyncManager] Authorization check: Body fat test read SUCCESS")
                } else if let error = error as? HKError, error.code == .errorAuthorizationDenied {
                    print("[SyncManager] Authorization check: Body fat test read DENIED")
                } else {
                    bodyFatAuthorized = true
                    print("[SyncManager] Authorization check: Body fat test read completed (permissions granted, may have no data)")
                }
                dispatchGroup.leave()
            }
            store.execute(bodyFatTestQuery)
            
            // Wait for all test reads to complete, then update authorization status
            dispatchGroup.notify(queue: .main) { [weak self] in
                guard let self = self else { return }
                
                // Clear the in-progress flag
                self.isTestReadInProgress = false
                
                let wasAuthorized = self.isAuthorized
                // Authorized if ANY test read succeeded
                self.isAuthorized = workoutAuthorized || heightAuthorized || weightAuthorized || bodyFatAuthorized
                
                print("[SyncManager] Authorization check: Test reads completed - workout=\(workoutAuthorized), height=\(heightAuthorized), weight=\(weightAuthorized), bodyFat=\(bodyFatAuthorized), isAuthorized=\(self.isAuthorized)")
                
                // Always notify observers when test reads complete (even if status didn't change)
                // This ensures UI updates even if isAuthorized was already true
                NotificationCenter.default.post(name: NSNotification.Name("HealthKitAuthorizationStatusChanged"), object: nil)
                
                // Also trigger the sync status callback if status changed
                if wasAuthorized != self.isAuthorized {
                    print("[SyncManager] Authorization status changed: \(wasAuthorized) -> \(self.isAuthorized)")
                    self.onSyncStatusChanged?(false, self.lastSyncDate, nil)
                }
            }
            
            // Don't set isAuthorized = false here - keep the current state until test reads complete
            // This prevents the UI from flickering to "Not Authorized" during test reads
            return
        }
        
        // Mixed state - some not determined, some denied, some authorized
        // If workout is authorized but profile types show denied, we still need to check profile types with test reads
        // This handles the case where user granted workout permissions but profile permissions were denied
        // but then enabled in Settings (read-only)
        if quickCheckAuthorized && profileTypesDenied {
            // Workout is authorized but profile types show denied - perform test reads for profile types
            // Guard against redundant test reads
            if isTestReadInProgress {
                print("[SyncManager] Authorization check: Test read already in progress, skipping duplicate check")
                return
            }
            
            print("[SyncManager] Authorization check: Workout authorized but profile types show denied - performing test reads for profile types...")
            isTestReadInProgress = true
            
            let dispatchGroup = DispatchGroup()
            var heightAuthorized = false
            var weightAuthorized = false
            var bodyFatAuthorized = false
            
            // Test height read
            dispatchGroup.enter()
            let heightTestQuery = HKSampleQuery(
                sampleType: heightType as HKSampleType,
                predicate: nil,
                limit: 1,
                sortDescriptors: nil
            ) { query, samples, error in
                if error == nil {
                    heightAuthorized = true
                    print("[SyncManager] Authorization check: Height test read SUCCESS")
                } else if let error = error as? HKError, error.code == .errorAuthorizationDenied {
                    print("[SyncManager] Authorization check: Height test read DENIED")
                } else {
                    heightAuthorized = true
                    print("[SyncManager] Authorization check: Height test read completed (permissions granted, may have no data)")
                }
                dispatchGroup.leave()
            }
            store.execute(heightTestQuery)
            
            // Test weight read
            dispatchGroup.enter()
            let weightTestQuery = HKSampleQuery(
                sampleType: weightType as HKSampleType,
                predicate: nil,
                limit: 1,
                sortDescriptors: nil
            ) { query, samples, error in
                if error == nil {
                    weightAuthorized = true
                    print("[SyncManager] Authorization check: Weight test read SUCCESS")
                } else if let error = error as? HKError, error.code == .errorAuthorizationDenied {
                    print("[SyncManager] Authorization check: Weight test read DENIED")
                } else {
                    weightAuthorized = true
                    print("[SyncManager] Authorization check: Weight test read completed (permissions granted, may have no data)")
                }
                dispatchGroup.leave()
            }
            store.execute(weightTestQuery)
            
            // Test body fat read
            dispatchGroup.enter()
            let bodyFatTestQuery = HKSampleQuery(
                sampleType: bodyFatType as HKSampleType,
                predicate: nil,
                limit: 1,
                sortDescriptors: nil
            ) { query, samples, error in
                if error == nil {
                    bodyFatAuthorized = true
                    print("[SyncManager] Authorization check: Body fat test read SUCCESS")
                } else if let error = error as? HKError, error.code == .errorAuthorizationDenied {
                    print("[SyncManager] Authorization check: Body fat test read DENIED")
                } else {
                    bodyFatAuthorized = true
                    print("[SyncManager] Authorization check: Body fat test read completed (permissions granted, may have no data)")
                }
                dispatchGroup.leave()
            }
            store.execute(bodyFatTestQuery)
            
            // Wait for all test reads to complete
            dispatchGroup.notify(queue: .main) { [weak self] in
                guard let self = self else { return }
                
                self.isTestReadInProgress = false
                
                let wasAuthorized = self.isAuthorized
                // Authorized if workout is authorized OR any profile type test read succeeded
                self.isAuthorized = workoutStatus == .sharingAuthorized || heightAuthorized || weightAuthorized || bodyFatAuthorized
                
                print("[SyncManager] Authorization check: Profile test reads completed - height=\(heightAuthorized), weight=\(weightAuthorized), bodyFat=\(bodyFatAuthorized), isAuthorized=\(self.isAuthorized)")
                
                NotificationCenter.default.post(name: NSNotification.Name("HealthKitAuthorizationStatusChanged"), object: nil)
                
                if wasAuthorized != self.isAuthorized {
                    print("[SyncManager] Authorization status changed: \(wasAuthorized) -> \(self.isAuthorized)")
                    self.onSyncStatusChanged?(false, self.lastSyncDate, nil)
                }
            }
            
            return
        }
        
        // Mixed state - some not determined, some denied
        // If any type is explicitly authorized, we're authorized
        let wasAuthorized = isAuthorized
        let anyAuthorized = workoutStatus == .sharingAuthorized || 
                           heightStatus == .sharingAuthorized || 
                           weightStatus == .sharingAuthorized ||
                           bodyFatStatus == .sharingAuthorized
        
        // If any type is explicitly authorized, we're definitely authorized
        if anyAuthorized {
            isAuthorized = true
            print("[SyncManager] Authorization check: At least one type is .sharingAuthorized - authorized")
        } else {
            // No types are explicitly authorized, but some might be denied
            // For mixed state (some .notDetermined, some denied), we're not authorized yet
            // but we also shouldn't show as denied - keep current state or set to false
            isAuthorized = false
            print("[SyncManager] Authorization check: Mixed state - no types explicitly authorized, isAuthorized=false")
        }
        
        print("[SyncManager] Authorization check: workout=\(workoutStatus.rawValue), height=\(heightStatus.rawValue), weight=\(weightStatus.rawValue), bodyFat=\(bodyFatStatus.rawValue), isAuthorized=\(isAuthorized)")
        
        // Notify observers if status changed
        if wasAuthorized != isAuthorized {
            print("[SyncManager] Authorization status changed: \(wasAuthorized) -> \(isAuthorized)")
            NotificationCenter.default.post(name: NSNotification.Name("HealthKitAuthorizationStatusChanged"), object: nil)
            onSyncStatusChanged?(false, lastSyncDate, nil)
        }
        
        // In dev mode, surface denied types clearly
        if DevMode.isEnabled {
            var deniedTypes: [String] = []
            if workoutStatus == .sharingDenied { deniedTypes.append("workouts") }
            if heightStatus == .sharingDenied { deniedTypes.append("height") }
            if weightStatus == .sharingDenied { deniedTypes.append("weight") }
            if bodyFatStatus == .sharingDenied { deniedTypes.append("body_fat") }
            
            if !deniedTypes.isEmpty {
                print("[SyncManager] WARNING: User denied access to: \(deniedTypes.joined(separator: ", ")). Reset in Settings → Privacy & Security → Health")
            }
        }
    }
    
    /// Performs authorization test reads to verify actual read access
    /// This always performs test reads regardless of cached authorization state
    /// Use this when you need to verify current authorization after permission changes
    private func performAuthorizationTestReads(completion: @escaping (Bool) -> Void) {
        guard HKHealthStore.isHealthDataAvailable() else {
            completion(false)
            return
        }
        
        let store = HKHealthStore()
        let workoutType = HKObjectType.workoutType()
        let heightType = HKQuantityType.quantityType(forIdentifier: .height)!
        let weightType = HKQuantityType.quantityType(forIdentifier: .bodyMass)!
        let bodyFatType = HKQuantityType.quantityType(forIdentifier: .bodyFatPercentage)!
        
        let dispatchGroup = DispatchGroup()
        var workoutAuthorized = false
        var heightAuthorized = false
        var weightAuthorized = false
        var bodyFatAuthorized = false
        
        // Test workout read
        dispatchGroup.enter()
        let workoutTestQuery = HKSampleQuery(
            sampleType: workoutType as HKSampleType,
            predicate: nil,
            limit: 1,
            sortDescriptors: nil
        ) { query, samples, error in
            if error == nil {
                workoutAuthorized = true
                print("[SyncManager] Test read: Workout SUCCESS")
            } else if let error = error as? HKError, error.code == .errorAuthorizationDenied {
                print("[SyncManager] Test read: Workout DENIED")
            } else {
                workoutAuthorized = true
                print("[SyncManager] Test read: Workout completed (permissions granted, may have no data)")
            }
            dispatchGroup.leave()
        }
        store.execute(workoutTestQuery)
        
        // Test height read
        dispatchGroup.enter()
        let heightTestQuery = HKSampleQuery(
            sampleType: heightType as HKSampleType,
            predicate: nil,
            limit: 1,
            sortDescriptors: nil
        ) { query, samples, error in
            if error == nil {
                heightAuthorized = true
                print("[SyncManager] Test read: Height SUCCESS")
            } else if let error = error as? HKError, error.code == .errorAuthorizationDenied {
                print("[SyncManager] Test read: Height DENIED")
            } else {
                heightAuthorized = true
                print("[SyncManager] Test read: Height completed (permissions granted, may have no data)")
            }
            dispatchGroup.leave()
        }
        store.execute(heightTestQuery)
        
        // Test weight read
        dispatchGroup.enter()
        let weightTestQuery = HKSampleQuery(
            sampleType: weightType as HKSampleType,
            predicate: nil,
            limit: 1,
            sortDescriptors: nil
        ) { query, samples, error in
            if error == nil {
                weightAuthorized = true
                print("[SyncManager] Test read: Weight SUCCESS")
            } else if let error = error as? HKError, error.code == .errorAuthorizationDenied {
                print("[SyncManager] Test read: Weight DENIED")
            } else {
                weightAuthorized = true
                print("[SyncManager] Test read: Weight completed (permissions granted, may have no data)")
            }
            dispatchGroup.leave()
        }
        store.execute(weightTestQuery)
        
        // Test body fat read
        dispatchGroup.enter()
        let bodyFatTestQuery = HKSampleQuery(
            sampleType: bodyFatType as HKSampleType,
            predicate: nil,
            limit: 1,
            sortDescriptors: nil
        ) { query, samples, error in
            if error == nil {
                bodyFatAuthorized = true
                print("[SyncManager] Test read: Body fat SUCCESS")
            } else if let error = error as? HKError, error.code == .errorAuthorizationDenied {
                print("[SyncManager] Test read: Body fat DENIED")
            } else {
                bodyFatAuthorized = true
                print("[SyncManager] Test read: Body fat completed (permissions granted, may have no data)")
            }
            dispatchGroup.leave()
        }
        store.execute(bodyFatTestQuery)
        
        // Wait for all test reads to complete
        dispatchGroup.notify(queue: .main) {
            let isAuthorized = workoutAuthorized || heightAuthorized || weightAuthorized || bodyFatAuthorized
            print("[SyncManager] Test reads completed - workout=\(workoutAuthorized), height=\(heightAuthorized), weight=\(weightAuthorized), bodyFat=\(bodyFatAuthorized), isAuthorized=\(isAuthorized)")
            completion(isAuthorized)
        }
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
        
        // Get all observers and execute queries on each to force manual sync
        // This ensures we query HealthKit for data even if there are no new changes
        let observers = hdsManager.allObservers
        
        guard !observers.isEmpty else {
            print("[SyncManager] WARNING: No observers configured. Make sure you've requested permissions and added object types.")
            isSyncing = false
            onSyncStatusChanged?(false, lastSyncDate, NSError(domain: "SyncManager", code: -2, userInfo: [NSLocalizedDescriptionKey: "No observers configured"]))
            completion(false, NSError(domain: "SyncManager", code: -2, userInfo: [NSLocalizedDescriptionKey: "No observers configured"]))
            return
        }
        
        print("[SyncManager] Starting manual sync for \(observers.count) observer(s)...")
        
        // Track completion of all observers
        let dispatchGroup = DispatchGroup()
        var syncErrors: [Error] = []
        var completedObservers = 0
        
        // Execute each observer's query
        for (index, observer) in observers.enumerated() {
            let observerType = observer.externalObjectType
            print("[SyncManager] Executing query for observer \(index + 1)/\(observers.count): \(observerType)")
            
            dispatchGroup.enter()
            observer.execute { success, error in
                completedObservers += 1
                
                if let error = error {
                    print("[SyncManager] Observer \(index + 1) execution failed: \(error.localizedDescription)")
                    syncErrors.append(error)
                } else if success {
                    print("[SyncManager] Observer \(index + 1) execution completed successfully")
                } else {
                    print("[SyncManager] Observer \(index + 1) execution was cancelled or skipped")
                }
                
                dispatchGroup.leave()
            }
        }
        
        // Wait for all observers to complete
        dispatchGroup.notify(queue: .main) { [weak self] in
            guard let self = self else { return }
            
            print("[SyncManager] All observer executions completed: \(completedObservers)/\(observers.count) finished")
            
                    self.isSyncing = false
                    self.lastSyncDate = Date()
            
            // Report completion
            if syncErrors.isEmpty {
                print("[SyncManager] Manual sync completed successfully")
                    self.onSyncStatusChanged?(false, self.lastSyncDate, nil)
                    completion(true, nil)
            } else {
                let firstError = syncErrors.first!
                print("[SyncManager] Manual sync completed with \(syncErrors.count) error(s)")
                self.onSyncStatusChanged?(false, self.lastSyncDate, firstError)
                completion(false, firstError)
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
            
            let observerType = observer.externalObjectType
            if let error = error {
                print("[SyncManager] Observer execution finished with error for type \(observerType): \(error.localizedDescription)")
            } else {
                print("[SyncManager] Observer execution finished successfully for type \(observerType)")
                self.lastSyncDate = Date()
            }
            
            // Note: didFinishExecution is called by each observer independently
            // For manual sync (syncNow), we track completion in syncNow() itself
            // This method is still useful for background sync notifications
            // Don't automatically set isSyncing = false here since manual sync tracks completion separately
        }
    }
}

