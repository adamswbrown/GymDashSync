//
//  StepData.swift
//  GymDashSync
//
//  Lightweight model for step count sync to CoachFit.
//

import Foundation

public struct StepData {
    public let date: Date
    public let totalSteps: Int
    public let sourceDevices: [String]?
    public let clientId: String
    public let uuid: UUID
    
    public init(date: Date, totalSteps: Int, sourceDevices: [String]? = nil, clientId: String, uuid: UUID = UUID()) {
        self.date = date
        self.totalSteps = totalSteps
        self.sourceDevices = sourceDevices
        self.clientId = clientId
        self.uuid = uuid
    }
    
    public func toBackendPayload(formatter: ISO8601DateFormatter) -> [String: Any] {
        var payload: [String: Any] = [
            "date": formatter.string(from: date),
            "total_steps": totalSteps,
            "healthkit_uuid": uuid.uuidString
        ]
        if let sourceDevices = sourceDevices, !sourceDevices.isEmpty {
            payload["source_devices"] = sourceDevices
        }
        return payload
    }
}
