//
//  WorkoutData.swift
//  GymDashSync
//
//  Copyright (c) 2024
//  Licensed under the MIT License.

import Foundation
import HealthKit
import HealthDataSync

/// External object representing a workout for sync to backend
///
/// ARCHITECTURAL NOTES:
/// - This is a DATA MODEL, not an identity provider
/// - client_id comes from UserDefaults (pairing), NOT from HealthKit
/// - HealthKit provides the workout data; we tag it with client_id
/// - Missing optional fields (calories, distance, heart rate) are expected and tolerated
/// - Timestamps are preserved as-is from HealthKit (ISO8601)
/// - Units are normalized before sending to backend (seconds, meters, kcal)
///
/// HealthKit data type: HKWorkout (not HKQuantitySample)
/// Query method: HKAnchoredObjectQuery via HDS framework (incremental sync)
public struct WorkoutData: HDSExternalObjectProtocol, Codable {
    public var uuid: UUID
    
    // Workout metadata
    public let workoutType: String
    public let startTime: Date
    public let endTime: Date
    public let durationSeconds: Double
    
    // Optional metrics
    public let activeEnergyBurned: Double?
    public let distanceMeters: Double?
    public let averageHeartRate: Double?
    public let sourceDevice: String?
    
    // Backend sync fields
    public let clientId: String
    public var source: String { "apple_health" }
    
    public init(uuid: UUID = UUID(),
                workoutType: String,
                startTime: Date,
                endTime: Date,
                durationSeconds: Double,
                activeEnergyBurned: Double? = nil,
                distanceMeters: Double? = nil,
                averageHeartRate: Double? = nil,
                sourceDevice: String? = nil,
                clientId: String) {
        self.uuid = uuid
        self.workoutType = workoutType
        self.startTime = startTime
        self.endTime = endTime
        self.durationSeconds = durationSeconds
        self.activeEnergyBurned = activeEnergyBurned
        self.distanceMeters = distanceMeters
        self.averageHeartRate = averageHeartRate
        self.sourceDevice = sourceDevice
        self.clientId = clientId
    }
    
    // MARK: - HDSExternalObjectProtocol
    
    public static func authorizationTypes() -> [HKObjectType]? {
        return [
            HKObjectType.workoutType(),
            HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned)!,
            HKQuantityType.quantityType(forIdentifier: .distanceWalkingRunning)!,
            HKQuantityType.quantityType(forIdentifier: .distanceCycling)!,
            HKQuantityType.quantityType(forIdentifier: .heartRate)!
        ]
    }
    
    public static func healthKitObjectType() -> HKObjectType? {
        return HKObjectType.workoutType()
    }
    
    /// Creates WorkoutData from HealthKit HKWorkout object
    ///
    /// IMPORTANT: This method requires client_id to exist (from pairing).
    /// If client_id is missing, returns nil - this is expected behavior.
    /// HealthKit is a data source only; identity comes from pairing.
    ///
    /// HealthKit best practice: Always handle nil returns gracefully.
    /// Missing client_id is not an error - it means pairing hasn't completed yet.
    public static func externalObject(object: HKObject, converter: HDSConverterProtocol?) -> HDSExternalObjectProtocol? {
        guard let workout = object as? HKWorkout else {
            return nil
        }
        
        // Identity comes from pairing, NOT from HealthKit
        // If client_id is missing, we cannot sync (pairing required)
        guard let clientId = UserDefaults.standard.string(forKey: "GymDashSync.ClientId"), !clientId.isEmpty else {
            // Expected: client_id not set means pairing hasn't completed
            // This is not an error - just means we can't sync yet
            if DevMode.isEnabled {
                print("[WorkoutData] WARNING: Cannot convert workout to external object - clientId missing from UserDefaults. Workout UUID: \(workout.uuid)")
            }
            return nil
        }
        
        // Map workout activity type to string
        let workoutTypeString = mapWorkoutType(workout.workoutActivityType)
        
        // Calculate duration
        let duration = workout.endDate.timeIntervalSince(workout.startDate)
        
        // Extract metrics from workout
        var activeEnergy: Double? = nil
        var distance: Double? = nil
        let avgHeartRate: Double? = nil
        
        // Active energy burned
        if #available(iOS 18.0, *) {
            if let stats = workout.statistics(for: .init(.activeEnergyBurned)), let sum = stats.sumQuantity() {
                activeEnergy = sum.doubleValue(for: .kilocalorie())
            }
        } else {
            if let energy = workout.totalEnergyBurned {
                activeEnergy = energy.doubleValue(for: .kilocalorie())
            }
        }
        
        // Distance (check both walking/running and cycling)
        if let workoutDistance = workout.totalDistance {
            distance = workoutDistance.doubleValue(for: HKUnit.meter())
        }
        
        // Heart rate - would need to query separately, but for now we'll use summary if available
        // Note: HKWorkout doesn't directly contain heart rate, it's in associated samples
        // This is a simplified version - in production you might want to query heart rate samples
        
        // Determine source device from multiple sources
        var sourceDevice: String? = nil
        
        // Method 1: Check metadata for device name
        if let metadata = workout.metadata, let deviceName = metadata[HKMetadataKeyDeviceName] as? String {
            let lowerName = deviceName.lowercased()
            if lowerName.contains("watch") {
                sourceDevice = "apple_watch"
            } else if lowerName.contains("iphone") || lowerName.contains("ipad") {
                sourceDevice = "iphone"
            } else {
                // Unknown device - store the actual name for debugging
                sourceDevice = deviceName
            }
            
            if DevMode.isEnabled {
                print("[WorkoutData] Device from metadata: \(deviceName) -> \(sourceDevice ?? "unknown")")
            }
        }
        
        // Method 2: Check sourceRevision for device info (if metadata didn't have it)
        if sourceDevice == nil {
            let sourceRevision = workout.sourceRevision
            let sourceName = sourceRevision.source.name.lowercased()
            
            // Check if source is Apple Watch (common source names)
            if sourceName.contains("watch") || sourceName.contains("apple watch") {
                sourceDevice = "apple_watch"
            } else if sourceName.contains("iphone") || sourceName.contains("ipad") {
                sourceDevice = "iphone"
            } else {
                // Try to infer from source name patterns
                // Apple Watch sources often contain "Watch" or have specific patterns
                if sourceRevision.source.bundleIdentifier.contains("com.apple.health") {
                    // This is from Health app - could be either, but if we have workout data,
                    // it's more likely from Watch if it has heart rate data
                    // For now, we'll leave it as nil
                }
            }
            
            if DevMode.isEnabled {
                print("[WorkoutData] Device from sourceRevision: source=\(sourceRevision.source.name), bundle=\(sourceRevision.source.bundleIdentifier), device=\(sourceDevice ?? "nil")")
            }
        }
        
        // Method 3: If still nil, we could infer from workout characteristics
        // (e.g., workouts with heart rate are more likely from Watch)
        // But this is unreliable, so we'll leave it as nil
        
        return WorkoutData(
            uuid: workout.uuid,
            workoutType: workoutTypeString,
            startTime: workout.startDate,
            endTime: workout.endDate,
            durationSeconds: duration,
            activeEnergyBurned: activeEnergy,
            distanceMeters: distance,
            averageHeartRate: avgHeartRate,
            sourceDevice: sourceDevice,
            clientId: clientId
        )
    }
    
    public static func externalObject(deletedObject: HKDeletedObject, converter: HDSConverterProtocol?) -> HDSExternalObjectProtocol? {
        guard let clientId = UserDefaults.standard.string(forKey: "GymDashSync.ClientId"), !clientId.isEmpty else {
            if DevMode.isEnabled {
                print("[WorkoutData] WARNING: Cannot convert deleted workout to external object - clientId missing from UserDefaults. Deleted UUID: \(deletedObject.uuid)")
            }
            return nil
        }
        return WorkoutData(
            uuid: deletedObject.uuid,
            workoutType: "deleted",
            startTime: Date(),
            endTime: Date(),
            durationSeconds: 0,
            clientId: clientId
        )
    }
    
    public func update(with object: HKObject) {
        // Update is handled by creating a new WorkoutData from the HKObject
        // The framework will handle replacing the old instance with the updated one
        // Workouts are typically immutable in HealthKit, so this is mainly for framework compatibility
        _ = object as? HKWorkout
    }
    
    // MARK: - Helper Methods
    
    private static func mapWorkoutType(_ activityType: HKWorkoutActivityType) -> String {
        switch activityType {
        case .running:
            return "run"
        case .walking:
            return "walk"
        case .cycling:
            return "cycle"
        case .traditionalStrengthTraining, .functionalStrengthTraining:
            return "strength"
        case .highIntensityIntervalTraining:
            return "hiit"
        default:
            return "other"
        }
    }
    
    // MARK: - Backend Payload
    
    /// Converts WorkoutData to backend payload format
    ///
    /// HealthKit best practice: Timestamps are preserved as-is from HealthKit (no timezone conversion).
    /// Units are normalized: seconds (duration), meters (distance), kcal (calories).
    /// client_id comes from pairing (UserDefaults), not from HealthKit.
    public func toBackendPayload() -> [String: Any] {
        // Backend payload with normalized units and ISO8601 timestamps
        // Timestamps are preserved as-is from HealthKit (no timezone conversion)
        // Units: seconds (duration), meters (distance), kcal (calories)
        var payload: [String: Any] = [
            "client_id": clientId, // From pairing, not HealthKit
            "source": source,
            "workout_type": workoutType,
            "start_time": ISO8601DateFormatter().string(from: startTime), // Preserved from HealthKit
            "end_time": ISO8601DateFormatter().string(from: endTime), // Preserved from HealthKit
            "duration_seconds": durationSeconds, // Calculated from start/end times
            "healthkit_uuid": uuid.uuidString // HealthKit UUID for matching and deletion
        ]
        
        if let calories = activeEnergyBurned {
            payload["calories_active"] = calories
        }
        
        if let distance = distanceMeters {
            payload["distance_meters"] = distance
        }
        
        if let heartRate = averageHeartRate {
            payload["avg_heart_rate"] = heartRate
        }
        
        if let device = sourceDevice {
            payload["source_device"] = device
        }
        
        return payload
    }
}

