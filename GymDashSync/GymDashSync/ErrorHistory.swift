//
//  ErrorHistory.swift
//  GymDashSync
//
//  Copyright (c) 2024
//  Licensed under the MIT License.

import Foundation
import Combine

/// Manages a rolling history of errors for debugging
/// Stores last N errors in memory (configurable)
public class ErrorHistory: ObservableObject {
    @Published public private(set) var errors: [AppError] = []
    
    private let maxErrors: Int
    private let queue = DispatchQueue(label: "com.gymdashsync.errorhistory")
    
    public init(maxErrors: Int = 10) {
        self.maxErrors = maxErrors
    }
    
    /// Add an error to history
    public func add(_ error: AppError) {
        queue.async { [weak self] in
            guard let self = self else { return }
            
            DispatchQueue.main.async {
                self.errors.insert(error, at: 0)
                
                // Keep only last N errors
                if self.errors.count > self.maxErrors {
                    self.errors = Array(self.errors.prefix(self.maxErrors))
                }
                
                // Log to console for Xcode debugging
                print("[ERROR] \(error.category.rawValue.uppercased()): \(error.message)")
                if let detail = error.detail {
                    print("[ERROR] Detail: \(detail)")
                }
                if let context = error.context {
                    print("[ERROR] Context: \(context)")
                }
                print("[ERROR] Error ID: \(error.id.uuidString)")
            }
        }
    }
    
    /// Clear all errors
    public func clear() {
        DispatchQueue.main.async {
            self.errors.removeAll()
        }
    }
    
    /// Get errors by category
    public func errors(for category: ErrorCategory) -> [AppError] {
        return errors.filter { $0.category == category }
    }
}

// MARK: - ErrorHistory Singleton

extension ErrorHistory {
    /// Shared singleton instance for app-wide error history
    public static let shared = ErrorHistory()
}

