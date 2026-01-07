//
//  DevMode.swift
//  GymDashSync
//
//  Copyright (c) 2024
//  Licensed under the MIT License.

import Foundation

/// Development mode configuration
/// Controls verbosity of error messages and diagnostics
/// 
/// When enabled:
/// - Shows detailed error messages with technical details
/// - Shows HTTP status codes and response bodies
/// - Shows validation warnings
/// - Shows timestamps and request summaries
/// - Enables diagnostics panels
///
/// When disabled:
/// - Shows short, friendly messages only
/// - Hides technical details
/// - Minimal error information
///
/// To disable for production, set isEnabled to false
public struct DevMode {
    /// Global dev mode flag
    /// Set to false for production builds
    public static var isEnabled: Bool {
        // Check UserDefaults first (allows runtime toggle)
        if UserDefaults.standard.object(forKey: "GymDashSync.DevMode") != nil {
            return UserDefaults.standard.bool(forKey: "GymDashSync.DevMode")
        }
        // Default to true for development
        return true
    }
    
    /// Set dev mode (persists to UserDefaults)
    public static func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "GymDashSync.DevMode")
    }
    
    /// Toggle dev mode
    public static func toggle() {
        setEnabled(!isEnabled)
    }
}

