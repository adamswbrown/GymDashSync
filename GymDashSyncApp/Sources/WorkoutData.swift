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
    public let source: String = "apple_health"
    
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
    
    public static func externalObject(object: HKObject, converter: HDSConverterProtocol?) -> HDSExternalObjectProtocol? {
        guard let workout = object as? HKWorkout else {
            return nil
        }
        
        // Get client ID from user defaults (must be set via pairing)
        guard let clientId = UserDefaults.standard.string(forKey: "GymDashSync.ClientId"), !clientId.isEmpty else {
            // Client ID not set - pairing required
            return nil
        }
        
        // Map workout activity type to string
        let workoutTypeString = mapWorkoutType(workout.workoutActivityType)
        
        // Calculate duration
        let duration = workout.endDate.timeIntervalSince(workout.startDate)
        
        // Extract metrics from workout
        var activeEnergy: Double? = nil
        var distance: Double? = nil
        var avgHeartRate: Double? = nil
        
        // Active energy burned
        if let energy = workout.totalEnergyBurned {
            activeEnergy = energy.doubleValue(for: HKUnit.kilocalorie())
        }
        
        // Distance (check both walking/running and cycling)
        if let workoutDistance = workout.totalDistance {
            distance = workoutDistance.doubleValue(for: HKUnit.meter())
        }
        
        // Heart rate - would need to query separately, but for now we'll use summary if available
        // Note: HKWorkout doesn't directly contain heart rate, it's in associated samples
        // This is a simplified version - in production you might want to query heart rate samples
        
        // Determine source device
        var sourceDevice: String? = nil
        if let metadata = workout.metadata, let deviceName = metadata[HKMetadataKeyDeviceName] as? String {
            sourceDevice = deviceName.lowercased().contains("watch") ? "apple_watch" : "iphone"
        }
        
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
        guard let workout = object as? HKWorkout else {
            return
        }
        
        // Update mutable properties from the HealthKit object
        // Note: Since WorkoutData uses let for most properties, we create a new instance
        // The framework will handle replacing the old instance with the updated one
        // For now, we'll update what we can (though workouts are typically immutable in HealthKit)
        
        // If the workout UUID matches, we can update metrics that might have changed
        // This is rare for workouts, but the framework supports it
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
    
    public func toBackendPayload() -> [String: Any] {
        var payload: [String: Any] = [
            "client_id": clientId,
            "source": source,
            "workout_type": workoutType,
            "start_time": ISO8601DateFormatter().string(from: startTime),
            "end_time": ISO8601DateFormatter().string(from: endTime),
            "duration_seconds": durationSeconds
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

