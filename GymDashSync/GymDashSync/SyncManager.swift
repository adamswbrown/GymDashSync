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
/// - SYNC STRATEGY: Incremental syncs query only data since last successful sync
///
/// This is NOT a demo app - it's a production-ready ingestion client.
public class SyncManager: NSObject, HDSQueryObserverDelegate {
    // MARK: - Constants
    private let lastWorkoutSyncKey = "GymDashSync.LastWorkoutSync"
    private let lastStepsSyncKey = "GymDashSync.LastStepsSync"
    private let lastSleepSyncKey = "GymDashSync.LastSleepSync"
    private let defaultSyncWindowDays: Int = 30 // If no prior sync, go back this many days
    
    private var hdsManager: HDSManagerProtocol
    let backendStore: BackendSyncStore // Made internal for access to sync results
    private var workoutObserver: HDSQueryObserver?
    private var profileObservers: [HDSQueryObserver] = []
    
    public var onSyncStatusChanged: ((Bool, Date?, Error?) -> Void)?
    private(set) public var lastSyncDate: Date?
    private(set) public var isAuthorized: Bool = false
    private(set) public var isSyncing: Bool = false
    private var isTestReadInProgress: Bool = false // Guard against redundant test reads
    
    // Track accumulating sync results during syncNow() operation
    private var currentSyncResults: [SyncResult] = []
    private var originalOnSyncComplete: (([SyncResult]) -> Void)?
    
    // Track last known client ID to detect changes
    // When client ID changes, we need to reset anchors to force full re-sync
    private var lastKnownClientId: String?
    
    public init(backendConfig: BackendConfig = .default) {
        self.hdsManager = HDSManagerFactory.manager()
        self.backendStore = BackendSyncStore(config: backendConfig)
        super.init()
        
        // Set ourselves as the observer delegate
        hdsManager.observerDelegate = self
        
        // Don't set onSyncComplete here - let ViewModels set their own callbacks
        // Results are stored in backendStore.lastSyncResults and can be accessed directly
        
        // Check authorization status
        checkAuthorizationStatus()
        
        // Track initial client ID
        lastKnownClientId = UserDefaults.standard.string(forKey: "GymDashSync.ClientId")
        
        // If already authorized, ensure observers are initialized
        // This handles the case where app restarts but permissions were already granted
        if isAuthorized {
            initializeObserversIfAuthorized()
        }
    }
    
    /// Initializes observers if permissions are already granted
    /// This is called on init if permissions are already granted (app restart scenario)
    private func initializeObserversIfAuthorized() {
        guard HKHealthStore.isHealthDataAvailable() else {
            return
        }
        
        print("[SyncManager] Permissions already granted - initializing observers...")
        
        // Add all observers (workouts + profile metrics)
        // This ensures observers are available even if permissions were granted in a previous session
        hdsManager.addObjectTypes([WorkoutData.self], externalStore: backendStore)
        hdsManager.addObjectTypes([HeightData.self, WeightData.self, BodyFatData.self], externalStore: backendStore)
        
        let observerCount = hdsManager.allObservers.count
        print("[SyncManager] Initialized \(observerCount) observer(s) for already-granted permissions")
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
        
        // Add step and sleep types
        if let steps = HKQuantityType.quantityType(forIdentifier: .stepCount) {
            typesToRead.insert(steps)
        }
        if let sleep = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) {
            typesToRead.insert(sleep)
        }
        
        print("[SyncManager] Requesting HealthKit authorization for \(typesToRead.count) types (workouts + profile metrics + steps + sleep)...")
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
    
    /// Requests HealthKit permissions for step count data
    public func requestStepPermissions(completion: @escaping (Bool, Error?) -> Void) {
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
        
        print("[SyncManager] Requesting step count permissions...")
        
        let store = HKHealthStore()
        var typesToRead: Set<HKObjectType> = []
        
        if let stepCount = HKQuantityType.quantityType(forIdentifier: .stepCount) {
            typesToRead.insert(stepCount)
        }
        
        print("[SyncManager] Requesting HealthKit authorization for step count...")
        
        store.requestAuthorization(toShare: nil, read: typesToRead) { success, error in
            print("[SyncManager] HealthKit step count authorization result: success=\(success), error=\(error?.localizedDescription ?? "none")")
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.performAuthorizationTestReads { [weak self] isAuthorized in
                    guard let self = self else { return }
                    let wasAuthorized = self.isAuthorized
                    self.isAuthorized = isAuthorized
                    
                    if isAuthorized {
                        print("[SyncManager] SUCCESS: Step count permissions granted")
                        if wasAuthorized != isAuthorized {
                            NotificationCenter.default.post(name: NSNotification.Name("HealthKitAuthorizationStatusChanged"), object: nil)
                            self.onSyncStatusChanged?(false, self.lastSyncDate, nil)
                        }
                    }
                    completion(isAuthorized, error)
                }
            }
        }
    }
    
    /// Requests HealthKit permissions for sleep data
    public func requestSleepPermissions(completion: @escaping (Bool, Error?) -> Void) {
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
        
        print("[SyncManager] Requesting sleep data permissions...")
        
        let store = HKHealthStore()
        var typesToRead: Set<HKObjectType> = []
        
        // Sleep analysis is available in iOS 16+
        if let sleepAnalysis = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) {
            typesToRead.insert(sleepAnalysis)
        }
        
        print("[SyncManager] Requesting HealthKit authorization for sleep data...")
        
        store.requestAuthorization(toShare: nil, read: typesToRead) { success, error in
            print("[SyncManager] HealthKit sleep authorization result: success=\(success), error=\(error?.localizedDescription ?? "none")")
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.performAuthorizationTestReads { [weak self] isAuthorized in
                    guard let self = self else { return }
                    let wasAuthorized = self.isAuthorized
                    self.isAuthorized = isAuthorized
                    
                    if isAuthorized {
                        print("[SyncManager] SUCCESS: Sleep data permissions granted")
                        if wasAuthorized != isAuthorized {
                            NotificationCenter.default.post(name: NSNotification.Name("HealthKitAuthorizationStatusChanged"), object: nil)
                            self.onSyncStatusChanged?(false, self.lastSyncDate, nil)
                        }
                    }
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
        
        // If we have quick check authorization, initialize observers immediately
        if quickCheckAuthorized {
            let wasAuthorized = isAuthorized
            isAuthorized = true
            
            // Initialize observers if not already initialized
            if !wasAuthorized || hdsManager.allObservers.isEmpty {
                initializeObserversIfAuthorized()
            }
            
            // Notify observers of authorization status
            NotificationCenter.default.post(name: NSNotification.Name("HealthKitAuthorizationStatusChanged"), object: nil)
            if !wasAuthorized {
                onSyncStatusChanged?(false, lastSyncDate, nil)
            }
            
            print("[SyncManager] Authorization check: Quick check authorized - observers initialized")
            return
        }
        
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
            // But ensure observers are initialized even if we skip the check
            if isAuthorized {
                print("[SyncManager] Authorization check: Already authorized (from previous test read), skipping redundant check")
                // Ensure observers are initialized even if authorization was cached
                if hdsManager.allObservers.isEmpty {
                    initializeObserversIfAuthorized()
                }
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
                    
                    // If authorization just became true, ensure observers are initialized
                    if self.isAuthorized {
                        self.initializeObserversIfAuthorized()
                    }
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
        } else if allDenied {
            // All denied - we're definitely not authorized
            isAuthorized = false
            print("[SyncManager] Authorization check: All types .sharingDenied - need to verify with test reads")
        } else {
            // Mixed state: some .notDetermined, some denied
            // Don't immediately reset to false if we're already authorized from test reads
            // Test reads are authoritative for read-only permissions
            // Keep the current state and verify with test reads if needed
            print("[SyncManager] Authorization check: Mixed state - keeping current state (\(isAuthorized)) and running test reads to verify")
        }
        
        print("[SyncManager] Authorization check: workout=\(workoutStatus.rawValue), height=\(heightStatus.rawValue), weight=\(weightStatus.rawValue), bodyFat=\(bodyFatStatus.rawValue), isAuthorized=\(isAuthorized)")
        
        // For mixed state, always run test reads to get authoritative answer
        if !anyAuthorized && !allDenied {
            // Mixed state - run test reads
            if isTestReadInProgress {
                print("[SyncManager] Authorization check: Test read already in progress, skipping duplicate check")
                return
            }
            
            print("[SyncManager] Authorization check: Running test reads for mixed state...")
            isTestReadInProgress = true
            
            let dispatchGroup = DispatchGroup()
            var workoutAuthorized = false
            var heightAuthorized = false
            var weightAuthorized = false
            var bodyFatAuthorized = false
            
            // Test workout read
            dispatchGroup.enter()
            let workoutTestQuery = HKSampleQuery(
                sampleType: HKObjectType.workoutType() as HKSampleType,
                predicate: nil,
                limit: 1,
                sortDescriptors: nil
            ) { query, samples, error in
                if error == nil {
                    workoutAuthorized = true
                    print("[SyncManager] Authorization check: Workout test read SUCCESS")
                } else {
                    print("[SyncManager] Authorization check: Workout test read failed: \(error?.localizedDescription ?? "unknown")")
                }
                dispatchGroup.leave()
            }
            store.execute(workoutTestQuery)
            
            // Similar test reads for height, weight, body fat...
            dispatchGroup.enter()
            let heightTestQuery = HKSampleQuery(
                sampleType: HKQuantityType.quantityType(forIdentifier: .height)! as HKSampleType,
                predicate: nil,
                limit: 1,
                sortDescriptors: nil
            ) { query, samples, error in
                if error == nil {
                    heightAuthorized = true
                }
                dispatchGroup.leave()
            }
            store.execute(heightTestQuery)
            
            dispatchGroup.enter()
            let weightTestQuery = HKSampleQuery(
                sampleType: HKQuantityType.quantityType(forIdentifier: .bodyMass)! as HKSampleType,
                predicate: nil,
                limit: 1,
                sortDescriptors: nil
            ) { query, samples, error in
                if error == nil {
                    weightAuthorized = true
                }
                dispatchGroup.leave()
            }
            store.execute(weightTestQuery)
            
            dispatchGroup.enter()
            let bodyFatTestQuery = HKSampleQuery(
                sampleType: HKQuantityType.quantityType(forIdentifier: .bodyFatPercentage)! as HKSampleType,
                predicate: nil,
                limit: 1,
                sortDescriptors: nil
            ) { query, samples, error in
                if error == nil {
                    bodyFatAuthorized = true
                }
                dispatchGroup.leave()
            }
            store.execute(bodyFatTestQuery)
            
            dispatchGroup.notify(queue: .main) { [weak self] in
                guard let self = self else { return }
                self.isTestReadInProgress = false
                
                let finalAuthorized = workoutAuthorized || heightAuthorized || weightAuthorized || bodyFatAuthorized
                let statusChanged = self.isAuthorized != finalAuthorized
                self.isAuthorized = finalAuthorized
                
                print("[SyncManager] Authorization check: Mixed state test reads - authorized=\(finalAuthorized)")
                
                if statusChanged {
                    print("[SyncManager] Authorization status changed: \(wasAuthorized) -> \(finalAuthorized)")
                    NotificationCenter.default.post(name: NSNotification.Name("HealthKitAuthorizationStatusChanged"), object: nil)
                    self.onSyncStatusChanged?(false, self.lastSyncDate, nil)
                }
            }
            return
        }
        
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
        dispatchGroup.notify(queue: .main) { [weak self] in
            guard let self = self else {
                completion(false)
                return
            }
            
            let isAuthorized = workoutAuthorized || heightAuthorized || weightAuthorized || bodyFatAuthorized
            print("[SyncManager] Test reads completed - workout=\(workoutAuthorized), height=\(heightAuthorized), weight=\(weightAuthorized), bodyFat=\(bodyFatAuthorized), isAuthorized=\(isAuthorized)")
            
            // If authorized and observers aren't initialized yet, initialize them
            let wasAuthorized = self.isAuthorized
            if isAuthorized && !wasAuthorized {
                self.initializeObserversIfAuthorized()
            }
            
            completion(isAuthorized)
        }
    }
    
    // MARK: - Sync Operations
    
    /// Get the sync window start date for a given data type
    /// Returns the last recorded sync date if available, otherwise defaults to 365 days ago
    private func getSyncWindowStart(for key: String) -> Date {
        if let lastSync = UserDefaults.standard.object(forKey: key) as? Date {
            return lastSync
        }
        // First sync: go back 365 days
        return Calendar.current.date(byAdding: .day, value: -defaultSyncWindowDays, to: Date()) ?? Date(timeIntervalSince1970: 0)
    }
    
    public func startObserving() {
        hdsManager.startObserving()
    }
    
    public func stopObserving() {
        hdsManager.stopObserving()
    }
    
    /// Collects step count data from HealthKit and syncs to backend
    /// - Parameter since: Query steps from this date onwards. If nil, uses last recorded sync date or 365 days ago
    public func collectAndSyncSteps(since: Date? = nil, completion: @escaping (Bool, Error?) -> Void) {
        guard let clientId = UserDefaults.standard.string(forKey: "GymDashSync.ClientId") else {
            completion(false, NSError(domain: "SyncManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Missing client_id"]))
            return
        }
        
        let store = HKHealthStore()
        guard let stepType = HKQuantityType.quantityType(forIdentifier: .stepCount) else {
            completion(false, NSError(domain: "SyncManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Step count type not available"]))
            return
        }
        
        // Query steps from 'since' date onwards (or use incremental window)
        let endDate = Date()
        let startDate = since ?? getSyncWindowStart(for: lastStepsSyncKey)
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: .strictStartDate)
        
        print("[SyncManager] Querying steps from \(startDate) to \(endDate)")
        
        let query = HKStatisticsCollectionQuery(
            quantityType: stepType,
            quantitySamplePredicate: predicate,
            options: .cumulativeSum,
            anchorDate: startDate,
            intervalComponents: DateComponents(day: 1)
        )
        
        query.initialResultsHandler = { [weak self] _, statistics, error in
            guard let self = self else { return }
            
            if let error = error {
                print("[SyncManager] Error querying steps: \(error.localizedDescription)")
                completion(false, error)
                return
            }
            
            guard let statistics = statistics else {
                print("[SyncManager] No step statistics available")
                completion(true, nil)
                return
            }
            
            var stepDataArray: [StepData] = []
            statistics.enumerateStatistics(from: startDate, to: endDate) { statistic, _ in
                guard let sum = statistic.sumQuantity() else { return }
                let steps = Int(sum.doubleValue(for: HKUnit.count()))
                let stepData = StepData(date: statistic.startDate, totalSteps: steps, sourceDevices: nil, clientId: clientId)
                stepDataArray.append(stepData)
            }
            
            print("[SyncManager] Collected \(stepDataArray.count) days of step data")
            
            // Skip sync if no data collected (normal for incremental syncs with no new data)
            guard !stepDataArray.isEmpty else {
                print("[SyncManager] No new step data to sync")
                completion(true, nil)
                return
            }
            
            // Sync to backend
            self.backendStore.syncSteps(stepDataArray) { result in
                if result.success {
                    print("[SyncManager] Step data synced successfully")
                    // Update last sync date for steps
                    UserDefaults.standard.set(Date(), forKey: self.lastStepsSyncKey)
                    completion(true, nil)
                } else {
                    print("[SyncManager] Step data sync failed: \(result.error?.localizedDescription ?? "unknown error")")
                    completion(false, result.error)
                }
            }
        }
        
        store.execute(query)
    }
    
    /// Collects sleep data from HealthKit and syncs to backend
    /// - Parameter since: Query sleep from this date onwards. If nil, uses last recorded sync date or 365 days ago
    public func collectAndSyncSleep(since: Date? = nil, completion: @escaping (Bool, Error?) -> Void) {
        guard let clientId = UserDefaults.standard.string(forKey: "GymDashSync.ClientId") else {
            completion(false, NSError(domain: "SyncManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Missing client_id"]))
            return
        }
        
        let store = HKHealthStore()
        guard let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else {
            // Sleep analysis not available on older iOS versions
            print("[SyncManager] Sleep analysis not available on this device")
            completion(true, nil)
            return
        }
        
        // Query sleep from 'since' date onwards (or use incremental window)
        let calendar = Calendar.current
        let endDate = Date()
        let startDate = since ?? getSyncWindowStart(for: lastSleepSyncKey)
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: .strictStartDate)
        
        print("[SyncManager] Querying sleep from \(startDate) to \(endDate)")
        
        let query = HKSampleQuery(
            sampleType: sleepType,
            predicate: predicate,
            limit: HKObjectQueryNoLimit,
            sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)],
            resultsHandler: { [weak self] _, samples, error in
                guard let self = self else { return }
                
                if let error = error {
                    print("[SyncManager] Error querying sleep: \(error.localizedDescription)")
                    completion(false, error)
                    return
                }
                
                guard let samples = samples as? [HKCategorySample] else {
                    print("[SyncManager] No sleep samples available")
                    completion(true, nil)
                    return
                }
                
                // Group sleep by date (aggregate daily)
                var sleepByDate: [DateComponents: (totalMinutes: Int, samples: [HKCategorySample])] = [:]
                for sample in samples {
                    let dateComponents = calendar.dateComponents([.year, .month, .day], from: sample.startDate)
                    let minutes = Int(sample.endDate.timeIntervalSince(sample.startDate) / 60)
                    
                    if sleepByDate[dateComponents] == nil {
                        sleepByDate[dateComponents] = (0, [])
                    }
                    sleepByDate[dateComponents]?.totalMinutes += minutes
                    sleepByDate[dateComponents]?.samples.append(sample)
                }
                
                let sleepDataArray = sleepByDate.map { dateComponents, data -> SleepData in
                    guard let date = calendar.date(from: dateComponents) else {
                        return SleepData(date: Date(), totalSleepMinutes: data.totalMinutes, sourceDevices: nil, clientId: clientId)
                    }
                    
                    // Extract earliest start and latest end from samples that day
                    let sortedSamples = data.samples.sorted { $0.startDate < $1.startDate }
                    let sleepStart = sortedSamples.first?.startDate
                    let sleepEnd = sortedSamples.last?.endDate
                    
                    return SleepData(
                        date: date,
                        totalSleepMinutes: data.totalMinutes,
                        sourceDevices: nil,
                        sleepStart: sleepStart,
                        sleepEnd: sleepEnd,
                        clientId: clientId
                    )
                }
                
                print("[SyncManager] Collected \(sleepDataArray.count) days of sleep data")
                
                // Skip sync if no data collected (normal for incremental syncs with no new data)
                guard !sleepDataArray.isEmpty else {
                    print("[SyncManager] No new sleep data to sync")
                    completion(true, nil)
                    return
                }
                
                // Sync to backend
                self.backendStore.syncSleep(sleepDataArray) { result in
                    if result.success {
                        print("[SyncManager] Sleep data synced successfully")
                        // Update last sync date for sleep
                        UserDefaults.standard.set(Date(), forKey: self.lastSleepSyncKey)
                        completion(true, nil)
                    } else {
                        print("[SyncManager] Sleep data sync failed: \(result.error?.localizedDescription ?? "unknown error")")
                        completion(false, result.error)
                    }
                }
            }
        )
        
        store.execute(query)
    }
    
    public func syncNow(completion: @escaping (Bool, Error?) -> Void) {
        guard !isSyncing else {
            let error = NSError(domain: "SyncManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Sync already in progress"])
            let result = SyncResult(
                success: false,
                timestamp: Date(),
                error: ErrorMapper.unknownError(message: "Sync already in progress", error: error)
            )
            SyncQueue.shared.logFailure(result)
            completion(false, error)
            return
        }
        
        // Check if client ID has changed - if so, reset anchors to force full re-sync
        let currentClientId = UserDefaults.standard.string(forKey: "GymDashSync.ClientId")
        if let lastClientId = lastKnownClientId, let currentId = currentClientId {
            if lastClientId != currentId {
                print("[SyncManager] Client ID changed from \(lastClientId) to \(currentId) - resetting anchors for full re-sync")
                resetAllAnchors()
            }
        } else if let currentId = currentClientId, lastKnownClientId == nil {
            // First time syncing with a client ID - ensure anchors are cleared
            print("[SyncManager] First sync with client ID \(currentId) - ensuring anchors are cleared")
            resetAllAnchors()
        }
        // Update tracked client ID
        lastKnownClientId = currentClientId
        
        isSyncing = true
        onSyncStatusChanged?(true, lastSyncDate, nil)
        
        // Clear/reset accumulating results at start of sync
        currentSyncResults = []
        
        // Save original callback and replace with accumulator during sync
        originalOnSyncComplete = backendStore.onSyncComplete
        backendStore.onSyncComplete = { [weak self] results in
            guard let self = self else { return }
            // Accumulate results from each observer's execution
            self.currentSyncResults.append(contentsOf: results)
            print("[SyncManager] Accumulated \(results.count) result(s), total: \(self.currentSyncResults.count)")
        }
        
        // Get all observers and execute queries on each to force manual sync
        // This ensures we query HealthKit for data even if there are no new changes
        let observers = hdsManager.allObservers
        
        guard !observers.isEmpty else {
            print("[SyncManager] WARNING: No observers configured. Make sure you've requested permissions and added object types.")
            // Restore original callback
            backendStore.onSyncComplete = originalOnSyncComplete
            originalOnSyncComplete = nil
            isSyncing = false
            let error = NSError(domain: "SyncManager", code: -2, userInfo: [NSLocalizedDescriptionKey: "No observers configured"])
            let appError = ErrorMapper.unknownError(message: "No observers configured", error: error)
            let result = SyncResult(
                success: false,
                timestamp: Date(),
                error: appError
            )
            SyncQueue.shared.logFailure(result)
            onSyncStatusChanged?(false, lastSyncDate, appError)
            completion(false, appError)
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
                    print("[SyncManager] Observer \(index + 1) execution failed for type \(observerType)")
                    print("[SyncManager] Error type: \(type(of: error))")
                    print("[SyncManager] Error description: \(error.localizedDescription)")
                    if let appError = error as? AppError {
                        print("[SyncManager] AppError details: category=\(appError.category.rawValue), message=\(appError.message)")
                        if let detail = appError.detail {
                            print("[SyncManager] AppError detail: \(detail)")
                        }
                        if let context = appError.context, let endpoint = context.endpoint {
                            print("[SyncManager] AppError endpoint: \(endpoint)")
                        }
                    } else if let nsError = error as NSError? {
                        print("[SyncManager] NSError domain: \(nsError.domain), code: \(nsError.code)")
                        print("[SyncManager] NSError userInfo: \(nsError.userInfo)")
                    }
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
            
            // After all observers complete, sync steps and sleep using incremental window
            print("[SyncManager] Starting supplemental step and sleep sync...")
            let stepSleepGroup = DispatchGroup()
            
            // Get sync windows for supplemental data (respects last sync dates)
            let stepsSyncStart = self.getSyncWindowStart(for: self.lastStepsSyncKey)
            let sleepSyncStart = self.getSyncWindowStart(for: self.lastSleepSyncKey)
            
            // Sync steps
            stepSleepGroup.enter()
            self.collectAndSyncSteps(since: stepsSyncStart) { success, error in
                if let error = error {
                    print("[SyncManager] Step sync failed: \(error.localizedDescription)")
                    syncErrors.append(error)
                } else if success {
                    print("[SyncManager] Step sync completed")
                }
                stepSleepGroup.leave()
            }
            
            // Sync sleep
            stepSleepGroup.enter()
            self.collectAndSyncSleep(since: sleepSyncStart) { success, error in
                if let error = error {
                    print("[SyncManager] Sleep sync failed: \(error.localizedDescription)")
                    syncErrors.append(error)
                } else if success {
                    print("[SyncManager] Sleep sync completed")
                }
                stepSleepGroup.leave()
            }
            
            stepSleepGroup.notify(queue: .main) {
                // All observers have completed - combine all results and update once
                // Restore original callback
                self.backendStore.onSyncComplete = self.originalOnSyncComplete
                self.originalOnSyncComplete = nil
                
                // If no results were accumulated, it means observers found no data
                // Create a summary result to show that sync ran but found nothing
                if self.currentSyncResults.isEmpty {
                    print("[SyncManager] No sync results accumulated - observers found no data to sync")
                    let summaryResult = SyncResult(
                        success: true,
                        timestamp: Date(),
                        recordsReceived: 0,
                        recordsInserted: 0,
                        duplicatesSkipped: 0,
                        warningsCount: 0,
                        errorsCount: 0
                    )
                    self.currentSyncResults = [summaryResult]
                }
                
                // Update backendStore with all combined results
                self.backendStore.lastSyncResults = self.currentSyncResults
                
                // Call the callback once with all combined results
                let totalRecords = self.currentSyncResults.reduce(0) { $0 + $1.recordsReceived }
                print("[SyncManager] Updating diagnostics with \(self.currentSyncResults.count) combined result(s) (total records: \(totalRecords))")
                
                // Call the callback after restoring it
                // This ensures the ViewModel's onSyncComplete callback gets the combined results
                self.backendStore.onSyncComplete?(self.currentSyncResults)
                
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
                    
                    // Log detailed error information
                    if let appError = firstError as? AppError {
                        print("[SyncManager] Error details: category=\(appError.category.rawValue), message=\(appError.message), detail=\(appError.detail ?? "nil")")
                    } else {
                        print("[SyncManager] Error type: \(type(of: firstError)), description: \(firstError.localizedDescription)")
                    }
                    
                    // Convert to AppError for better error handling
                    let appError = ErrorMapper.unknownError(
                        message: "Sync failed: \(firstError.localizedDescription)",
                        error: firstError
                    )
                    self.onSyncStatusChanged?(false, self.lastSyncDate, appError)
                    completion(false, appError)
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
    
    /// Resets all anchor states to force a full re-sync of all data
    /// This clears all stored anchors and last execution dates for all observers,
    /// so the next sync will re-query all HealthKit data from scratch
    public func resetAllAnchors() {
        print("[SyncManager] Resetting all anchor states for full re-sync...")
        
        let observers = hdsManager.allObservers
        let userDefaults = UserDefaults.standard
        
        if observers.isEmpty {
            print("[SyncManager] WARNING: No observers found. Make sure permissions are granted and observers are added.")
        } else {
            print("[SyncManager] Found \(observers.count) observer(s) to reset")
        }
        
        var resetCount = 0
        for observer in observers {
            if let identifier = observer.externalObjectType.healthKitObjectType()?.identifier {
                // Clear anchor
                let anchorKey = identifier + "-Anchor"
                if userDefaults.object(forKey: anchorKey) != nil {
                    userDefaults.removeObject(forKey: anchorKey)
                    resetCount += 1
                }
                print("[SyncManager] Cleared anchor for: \(identifier)")
                
                // Clear last execution date
                let lastExecutionKey = identifier + "-Last-Execution-Date"
                if userDefaults.object(forKey: lastExecutionKey) != nil {
                    userDefaults.removeObject(forKey: lastExecutionKey)
                }
                print("[SyncManager] Cleared last execution date for: \(identifier)")
            } else {
                print("[SyncManager] WARNING: Could not get identifier for observer type: \(observer.externalObjectType)")
            }
        }
        
        userDefaults.synchronize()
        print("[SyncManager] All anchors reset (\(resetCount) anchor(s) cleared). Next sync will re-query all data from HealthKit.")
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

