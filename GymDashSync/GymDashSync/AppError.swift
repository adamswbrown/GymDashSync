//
//  AppError.swift
//  GymDashSync
//
//  Copyright (c) 2024
//  Licensed under the MIT License.

import Foundation

/// Structured error model for the app
/// All failures must be mapped into AppError for consistent error handling
public struct AppError: Identifiable, Codable, Equatable, Error {
    public let id: UUID
    public let category: ErrorCategory
    public let message: String
    public let detail: String?
    public let timestamp: Date
    public let context: ErrorContext?
    
    public init(
        id: UUID = UUID(),
        category: ErrorCategory,
        message: String,
        detail: String? = nil,
        timestamp: Date = Date(),
        context: ErrorContext? = nil
    ) {
        self.id = id
        self.category = category
        self.message = message
        self.detail = detail
        self.timestamp = timestamp
        self.context = context
    }
    
    /// Human-readable description for UI
    public var displayMessage: String {
        if let context = context, DevMode.isEnabled {
            var msg = message
            if let statusCode = context.statusCode {
                msg += " (\(statusCode))"
            }
            if let endpoint = context.endpoint {
                msg += "\nEndpoint: \(endpoint)"
            }
            if let responseBody = context.responseBody {
                msg += "\nResponse: \(responseBody)"
            }
            return msg
        }
        return message
    }
    
    /// Full technical details for dev mode
    public var technicalDetails: String {
        var details = "Category: \(category.rawValue)\n"
        details += "Message: \(message)\n"
        if let detail = detail {
            details += "Detail: \(detail)\n"
        }
        if let context = context {
            details += "Context:\n"
            if let endpoint = context.endpoint {
                details += "  Endpoint: \(endpoint)\n"
            }
            if let statusCode = context.statusCode {
                details += "  Status Code: \(statusCode)\n"
            }
            if let responseBody = context.responseBody {
                details += "  Response: \(responseBody)\n"
            }
            if let healthKitError = context.healthKitError {
                details += "  HealthKit Error: \(healthKitError)\n"
            }
        }
        details += "Timestamp: \(timestamp)\n"
        details += "Error ID: \(id.uuidString)"
        return details
    }
}

/// Error categories for classification
public enum ErrorCategory: String, Codable {
    case pairing = "pairing"
    case healthkit = "healthkit"
    case network = "network"
    case backend = "backend"
    case validation = "validation"
    case unknown = "unknown"
}

/// Additional context for errors
public struct ErrorContext: Codable, Equatable {
    public let endpoint: String?
    public let statusCode: Int?
    public let responseBody: String?
    public let healthKitError: String?
    public let requestDuration: TimeInterval?
    
    public init(
        endpoint: String? = nil,
        statusCode: Int? = nil,
        responseBody: String? = nil,
        healthKitError: String? = nil,
        requestDuration: TimeInterval? = nil
    ) {
        self.endpoint = endpoint
        self.statusCode = statusCode
        self.responseBody = responseBody
        self.healthKitError = healthKitError
        self.requestDuration = requestDuration
    }
}

/// Error mapping utilities
public struct ErrorMapper {
    /// Map pairing error to AppError
    public static func pairingError(
        message: String,
        endpoint: String,
        statusCode: Int? = nil,
        responseBody: String? = nil,
        duration: TimeInterval? = nil
    ) -> AppError {
        return AppError(
            category: .pairing,
            message: message,
            detail: "Pairing code exchange failed",
            context: ErrorContext(
                endpoint: endpoint,
                statusCode: statusCode,
                responseBody: responseBody,
                requestDuration: duration
            )
        )
    }
    
    /// Map HealthKit error to AppError
    public static func healthKitError(
        message: String,
        detail: String? = nil,
        healthKitError: String? = nil
    ) -> AppError {
        return AppError(
            category: .healthkit,
            message: message,
            detail: detail,
            context: ErrorContext(healthKitError: healthKitError)
        )
    }
    
    /// Map network error to AppError
    public static func networkError(
        message: String,
        endpoint: String? = nil,
        detail: String? = nil,
        duration: TimeInterval? = nil
    ) -> AppError {
        return AppError(
            category: .network,
            message: message,
            detail: detail,
            context: ErrorContext(
                endpoint: endpoint,
                requestDuration: duration
            )
        )
    }
    
    /// Map backend error to AppError
    public static func backendError(
        message: String,
        endpoint: String,
        statusCode: Int,
        responseBody: String? = nil,
        detail: String? = nil,
        duration: TimeInterval? = nil
    ) -> AppError {
        return AppError(
            category: .backend,
            message: message,
            detail: detail,
            context: ErrorContext(
                endpoint: endpoint,
                statusCode: statusCode,
                responseBody: responseBody,
                requestDuration: duration
            )
        )
    }
    
    /// Map validation error to AppError
    public static func validationError(
        message: String,
        detail: String? = nil,
        endpoint: String? = nil
    ) -> AppError {
        return AppError(
            category: .validation,
            message: message,
            detail: detail,
            context: ErrorContext(endpoint: endpoint)
        )
    }
    
    /// Map unknown error to AppError
    public static func unknownError(
        message: String,
        error: Error,
        endpoint: String? = nil
    ) -> AppError {
        return AppError(
            category: .unknown,
            message: message,
            detail: error.localizedDescription,
            context: ErrorContext(endpoint: endpoint)
        )
    }
}

