//
//  ProfileMetricData.swift
//  GymDashSync
//
//  Copyright (c) 2024
//  Licensed under the MIT License.

import Foundation
import HealthKit
import HealthDataSync

/// External object representing a profile/body metric for sync to backend
///
/// ARCHITECTURAL NOTES:
/// - This is a DATA MODEL, not an identity provider
/// - client_id comes from UserDefaults (pairing), NOT from HealthKit
/// - HealthKit provides the metric data; we tag it with client_id
/// - Missing metrics are expected (user may not have height/weight/body fat data)
/// - Units are normalized (cm for height, kg for weight, percent for body fat)
/// - Timestamps are preserved as-is from HealthKit (ISO8601)
///
/// HealthKit data types: HKQuantityType (height, bodyMass, bodyFatPercentage)
/// Query method: HKAnchoredObjectQuery via HDS framework (incremental sync)
/// Note: Characteristic types (biological sex, date of birth) are NOT used here
///
/// Note: This does not implement HDSExternalObjectProtocol directly.
/// Use HeightData, WeightData, or BodyFatData wrapper types instead.
public struct ProfileMetricData: Codable {
    public var uuid: UUID
    
    // Metric data
    public let metric: String // "height", "weight", "body_fat"
    public let value: Double
    public let unit: String
    public let measuredAt: Date
    
    // Backend sync fields
    public let clientId: String
    public var source: String { "apple_health" }
    
    public init(uuid: UUID = UUID(),
                metric: String,
                value: Double,
                unit: String,
                measuredAt: Date,
                clientId: String) {
        self.uuid = uuid
        self.metric = metric
        self.value = value
        self.unit = unit
        self.measuredAt = measuredAt
        self.clientId = clientId
    }
    
    // MARK: - Height
    
    public static func heightAuthorizationTypes() -> [HKObjectType]? {
        return [HKQuantityType.quantityType(forIdentifier: .height)!]
    }
    
    public static func heightHealthKitObjectType() -> HKObjectType? {
        return HKQuantityType.quantityType(forIdentifier: .height)
    }
    
    /// Creates HeightData from HealthKit HKQuantitySample
    ///
    /// IMPORTANT: This method requires client_id to exist (from pairing).
    /// If client_id is missing, returns nil - this is expected behavior.
    /// HealthKit is a data source only; identity comes from pairing.
    ///
    /// Unit conversion: HealthKit stores height in meters; we convert to centimeters for backend.
    public static func heightExternalObject(object: HKObject, converter: HDSConverterProtocol?) -> HDSExternalObjectProtocol? {
        guard let sample = object as? HKQuantitySample,
              sample.quantityType == HKQuantityType.quantityType(forIdentifier: .height) else {
            return nil
        }
        
        // Identity comes from pairing, NOT from HealthKit
        // If client_id is missing, we cannot sync (pairing required)
        guard let clientId = UserDefaults.standard.string(forKey: "GymDashSync.ClientId"), !clientId.isEmpty else {
            // Expected: client_id not set means pairing hasn't completed
            // This is not an error - just means we can't sync yet
            return nil
        }
        
        // Convert meters to centimeters
        let valueInMeters = sample.quantity.doubleValue(for: HKUnit.meter())
        let valueInCm = valueInMeters * 100.0
        
        let metricData = ProfileMetricData(
            uuid: sample.uuid,
            metric: "height",
            value: valueInCm,
            unit: "cm",
            measuredAt: sample.startDate,
            clientId: clientId
        )
        return HeightData(metric: metricData)
    }
    
    // MARK: - Weight
    
    public static func weightAuthorizationTypes() -> [HKObjectType]? {
        return [HKQuantityType.quantityType(forIdentifier: .bodyMass)!]
    }
    
    public static func weightHealthKitObjectType() -> HKObjectType? {
        return HKQuantityType.quantityType(forIdentifier: .bodyMass)
    }
    
    public static func weightExternalObject(object: HKObject, converter: HDSConverterProtocol?) -> HDSExternalObjectProtocol? {
        guard let sample = object as? HKQuantitySample,
              sample.quantityType == HKQuantityType.quantityType(forIdentifier: .bodyMass) else {
            return nil
        }
        
        // Get client ID from user defaults (must be set via pairing)
        guard let clientId = UserDefaults.standard.string(forKey: "GymDashSync.ClientId"), !clientId.isEmpty else {
            return nil
        }
        
        // HealthKit stores weight in grams; we normalize to kilograms for backend
        // Unit conversion: HKUnit.gramUnit(with: .kilo) = kg
        let value = sample.quantity.doubleValue(for: HKUnit.gramUnit(with: .kilo))
        
        let metricData = ProfileMetricData(
            uuid: sample.uuid,
            metric: "weight",
            value: value,
            unit: "kg",
            measuredAt: sample.startDate, // Timestamp preserved as-is from HealthKit
            clientId: clientId
        )
        return WeightData(metric: metricData)
    }
    
    // MARK: - Body Fat
    
    public static func bodyFatAuthorizationTypes() -> [HKObjectType]? {
        return [HKQuantityType.quantityType(forIdentifier: .bodyFatPercentage)!]
    }
    
    public static func bodyFatHealthKitObjectType() -> HKObjectType? {
        return HKQuantityType.quantityType(forIdentifier: .bodyFatPercentage)
    }
    
    public static func bodyFatExternalObject(object: HKObject, converter: HDSConverterProtocol?) -> HDSExternalObjectProtocol? {
        guard let sample = object as? HKQuantitySample,
              sample.quantityType == HKQuantityType.quantityType(forIdentifier: .bodyFatPercentage) else {
            return nil
        }
        
        // Get client ID from user defaults (must be set via pairing)
        guard let clientId = UserDefaults.standard.string(forKey: "GymDashSync.ClientId"), !clientId.isEmpty else {
            return nil
        }
        
        // HealthKit stores body fat as percentage (0.0-1.0 range)
        // We preserve the percentage value as-is (no conversion needed)
        // Unit conversion: HKUnit.percent() returns 0.0-1.0, we store as percentage value
        let value = sample.quantity.doubleValue(for: HKUnit.percent())
        
        let metricData = ProfileMetricData(
            uuid: sample.uuid,
            metric: "body_fat",
            value: value,
            unit: "percent",
            measuredAt: sample.startDate, // Timestamp preserved as-is from HealthKit
            clientId: clientId
        )
        return BodyFatData(metric: metricData)
    }
    
    // MARK: - Helper for Deleted Objects
    
    public static func deletedMetric(uuid: UUID) -> ProfileMetricData? {
        guard let clientId = UserDefaults.standard.string(forKey: "GymDashSync.ClientId"), !clientId.isEmpty else {
            return nil
        }
        return ProfileMetricData(
            uuid: uuid,
            metric: "deleted",
            value: 0,
            unit: "",
            measuredAt: Date(),
            clientId: clientId
        )
    }
    
    // MARK: - Backend Payload
    
    public func toBackendPayload() -> [String: Any] {
        return [
            "client_id": clientId,
            "metric": metric,
            "value": value,
            "unit": unit,
            "measured_at": ISO8601DateFormatter().string(from: measuredAt),
            "source": source
        ]
    }
}

// MARK: - Wrapper Types for HDS Integration

public struct HeightData: HDSExternalObjectProtocol {
    public var uuid: UUID
    private var metric: ProfileMetricData
    
    public init(metric: ProfileMetricData) {
        self.uuid = metric.uuid
        self.metric = metric
    }
    
    public static func authorizationTypes() -> [HKObjectType]? {
        return ProfileMetricData.heightAuthorizationTypes()
    }
    
    public static func healthKitObjectType() -> HKObjectType? {
        return ProfileMetricData.heightHealthKitObjectType()
    }
    
    public static func externalObject(object: HKObject, converter: HDSConverterProtocol?) -> HDSExternalObjectProtocol? {
        return ProfileMetricData.heightExternalObject(object: object, converter: converter)
    }
    
    public static func externalObject(deletedObject: HKDeletedObject, converter: HDSConverterProtocol?) -> HDSExternalObjectProtocol? {
        guard let data = ProfileMetricData.deletedMetric(uuid: deletedObject.uuid) else {
            return nil
        }
        return HeightData(metric: data)
    }
    
    public func update(with object: HKObject) {
        // HeightData updates are handled by creating new ProfileMetricData
        // The framework will replace the old instance
    }
    
    public func toProfileMetric() -> ProfileMetricData {
        return metric
    }
}

public struct WeightData: HDSExternalObjectProtocol {
    public var uuid: UUID
    private var metric: ProfileMetricData
    
    public init(metric: ProfileMetricData) {
        self.uuid = metric.uuid
        self.metric = metric
    }
    
    public static func authorizationTypes() -> [HKObjectType]? {
        return ProfileMetricData.weightAuthorizationTypes()
    }
    
    public static func healthKitObjectType() -> HKObjectType? {
        return ProfileMetricData.weightHealthKitObjectType()
    }
    
    public static func externalObject(object: HKObject, converter: HDSConverterProtocol?) -> HDSExternalObjectProtocol? {
        return ProfileMetricData.weightExternalObject(object: object, converter: converter)
    }
    
    public static func externalObject(deletedObject: HKDeletedObject, converter: HDSConverterProtocol?) -> HDSExternalObjectProtocol? {
        guard let data = ProfileMetricData.deletedMetric(uuid: deletedObject.uuid) else {
            return nil
        }
        return WeightData(metric: data)
    }
    
    public func update(with object: HKObject) {
        // Update is handled by creating a new ProfileMetricData from the HKObject
            // Framework will handle replacing the instance
        _ = ProfileMetricData.weightExternalObject(object: object, converter: nil)
    }
    
    public mutating func updateMetric(with object: HKObject) {
        if let result = ProfileMetricData.weightExternalObject(object: object, converter: nil),
           let weightData = result as? WeightData {
            self.metric = weightData.toProfileMetric()
            self.uuid = weightData.uuid
        }
    }
    
    public func toProfileMetric() -> ProfileMetricData {
        return metric
    }
}

public struct BodyFatData: HDSExternalObjectProtocol {
    public var uuid: UUID
    private var metric: ProfileMetricData
    
    public init(metric: ProfileMetricData) {
        self.uuid = metric.uuid
        self.metric = metric
    }
    
    public static func authorizationTypes() -> [HKObjectType]? {
        return ProfileMetricData.bodyFatAuthorizationTypes()
    }
    
    public static func healthKitObjectType() -> HKObjectType? {
        return ProfileMetricData.bodyFatHealthKitObjectType()
    }
    
    public static func externalObject(object: HKObject, converter: HDSConverterProtocol?) -> HDSExternalObjectProtocol? {
        return ProfileMetricData.bodyFatExternalObject(object: object, converter: converter)
    }
    
    public static func externalObject(deletedObject: HKDeletedObject, converter: HDSConverterProtocol?) -> HDSExternalObjectProtocol? {
        guard let data = ProfileMetricData.deletedMetric(uuid: deletedObject.uuid) else {
            return nil
        }
        return BodyFatData(metric: data)
    }
    
    public func update(with object: HKObject) {
        // Update is handled by creating a new ProfileMetricData from the HKObject
            // Framework will handle replacing the instance
        _ = ProfileMetricData.bodyFatExternalObject(object: object, converter: nil)
    }
    
    public mutating func updateMetric(with object: HKObject) {
        if let result = ProfileMetricData.bodyFatExternalObject(object: object, converter: nil),
           let bodyFatData = result as? BodyFatData {
            self.metric = bodyFatData.toProfileMetric()
            self.uuid = bodyFatData.uuid
        }
    }
    
    public func toProfileMetric() -> ProfileMetricData {
        return metric
    }
}

