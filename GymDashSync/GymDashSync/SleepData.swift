//
//  SleepData.swift
//  GymDashSync
//
//  Simplified sleep duration model for CoachFit ingestion.
//

import Foundation

public struct SleepData {
    public let date: Date // date representing sleep start date (midnight-based)
    public let totalSleepMinutes: Int
    public let sourceDevices: [String]?
    public let sleepStart: Date?
    public let sleepEnd: Date?
    public let clientId: String
    public let uuid: UUID
    
    public init(date: Date,
                totalSleepMinutes: Int,
                sourceDevices: [String]? = nil,
                sleepStart: Date? = nil,
                sleepEnd: Date? = nil,
                clientId: String,
                uuid: UUID = UUID()) {
        self.date = date
        self.totalSleepMinutes = totalSleepMinutes
        self.sourceDevices = sourceDevices
        self.sleepStart = sleepStart
        self.sleepEnd = sleepEnd
        self.clientId = clientId
        self.uuid = uuid
    }
    
    public func toBackendPayload(formatter: ISO8601DateFormatter, dateOnlyFormatter: DateFormatter) -> [String: Any] {
        var payload: [String: Any] = [
            "date": dateOnlyFormatter.string(from: date),
            "total_sleep_minutes": totalSleepMinutes,
            "healthkit_uuid": uuid.uuidString
        ]
        if let sourceDevices = sourceDevices, !sourceDevices.isEmpty {
            payload["source_devices"] = sourceDevices
        }
        if let sleepStart = sleepStart {
            payload["sleep_start"] = formatter.string(from: sleepStart)
        }
        if let sleepEnd = sleepEnd {
            payload["sleep_end"] = formatter.string(from: sleepEnd)
        }
        return payload
    }
}
