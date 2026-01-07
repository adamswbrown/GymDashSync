//
//  SyncResult.swift
//  GymDashSync
//
//  Copyright (c) 2024
//  Licensed under the MIT License.

import Foundation

/// Result of a sync operation with detailed diagnostics
public struct SyncResult {
    public let success: Bool
    public let timestamp: Date
    public let endpoint: String?
    public let statusCode: Int?
    public let duration: TimeInterval
    
    // Record counts
    public let recordsReceived: Int
    public let recordsInserted: Int
    public let duplicatesSkipped: Int
    public let warningsCount: Int
    public let errorsCount: Int
    
    // Error details
    public let error: AppError?
    public let validationErrors: [String]?
    
    public init(
        success: Bool,
        timestamp: Date = Date(),
        endpoint: String? = nil,
        statusCode: Int? = nil,
        duration: TimeInterval = 0,
        recordsReceived: Int = 0,
        recordsInserted: Int = 0,
        duplicatesSkipped: Int = 0,
        warningsCount: Int = 0,
        errorsCount: Int = 0,
        error: AppError? = nil,
        validationErrors: [String]? = nil
    ) {
        self.success = success
        self.timestamp = timestamp
        self.endpoint = endpoint
        self.statusCode = statusCode
        self.duration = duration
        self.recordsReceived = recordsReceived
        self.recordsInserted = recordsInserted
        self.duplicatesSkipped = duplicatesSkipped
        self.warningsCount = warningsCount
        self.errorsCount = errorsCount
        self.error = error
        self.validationErrors = validationErrors
    }
    
    /// Human-readable summary
    public var summary: String {
        if success {
            return "Sync successful: \(recordsInserted) records inserted"
        } else {
            return "Sync failed: \(error?.message ?? "Unknown error")"
        }
    }
    
    /// Detailed diagnostics (for dev mode)
    public var diagnostics: String {
        var diag = "Sync Diagnostics\n"
        diag += "================\n"
        diag += "Timestamp: \(timestamp)\n"
        diag += "Success: \(success)\n"
        diag += "Duration: \(String(format: "%.2f", duration))s\n"
        
        if let endpoint = endpoint {
            diag += "Endpoint: \(endpoint)\n"
        }
        
        if let statusCode = statusCode {
            diag += "Status Code: \(statusCode)\n"
        }
        
        diag += "\nRecord Counts:\n"
        diag += "  Received: \(recordsReceived)\n"
        diag += "  Inserted: \(recordsInserted)\n"
        diag += "  Duplicates Skipped: \(duplicatesSkipped)\n"
        diag += "  Warnings: \(warningsCount)\n"
        diag += "  Errors: \(errorsCount)\n"
        
        if let validationErrors = validationErrors, !validationErrors.isEmpty {
            diag += "\nValidation Errors:\n"
            for error in validationErrors {
                diag += "  - \(error)\n"
            }
        }
        
        if let error = error {
            diag += "\nError:\n"
            diag += error.technicalDetails
        }
        
        return diag
    }
}

