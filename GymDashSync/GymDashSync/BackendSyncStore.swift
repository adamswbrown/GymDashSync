//
//  BackendSyncStore.swift
//  GymDashSync
//
//  Copyright (c) 2024
//  Licensed under the MIT License.

import Foundation
import HealthDataSync

/// Configuration for backend sync endpoint
public struct BackendConfig {
    public let baseURL: String
    public let apiKey: String?
    public let workoutEndpoint: String
    public let profileMetricEndpoint: String
    public let workoutQueryEndpoint: String
    public let profileMetricQueryEndpoint: String
    
    public init(baseURL: String, apiKey: String? = nil) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.workoutEndpoint = "\(baseURL)/api/v1/workouts"
        self.profileMetricEndpoint = "\(baseURL)/api/v1/profile-metrics"
        self.workoutQueryEndpoint = "\(baseURL)/api/v1/workouts/query"
        self.profileMetricQueryEndpoint = "\(baseURL)/api/v1/profile-metrics/query"
    }
    
    public static var `default`: BackendConfig {
        // Default to Mac's IP address for physical device testing, fallback to localhost for simulator
        // Can be overridden via UserDefaults key "GymDashSync.BackendURL"
        let defaultURL = UserDefaults.standard.string(forKey: "GymDashSync.BackendURL") ?? "http://192.168.68.51:3001"
        let key = UserDefaults.standard.string(forKey: "GymDashSync.APIKey")
        return BackendConfig(baseURL: defaultURL, apiKey: key)
    }
}

/// Backend sync store implementation for HealthDataSync
///
/// ARCHITECTURAL PRINCIPLES:
/// - Receives HealthKit data objects that are ALREADY tagged with client_id
/// - client_id comes from pairing (UserDefaults), NOT from HealthKit
/// - All sync operations require client_id to be present
/// - Backend owns identity and deduplication logic
/// - Missing or partial data is expected and handled gracefully
///
/// This store does NOT derive identity from HealthKit data.
/// It assumes client_id is already attached to each object.
public class BackendSyncStore: HDSExternalStoreProtocol {
    private let config: BackendConfig
    private let session: URLSession
    
    // Dev mode: Track last sync results
    public var lastSyncResults: [SyncResult] = []
    public var onSyncComplete: (([SyncResult]) -> Void)?
    
    public init(config: BackendConfig = .default) {
        self.config = config
        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.timeoutIntervalForRequest = 30
        sessionConfig.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: sessionConfig)
    }
    
    // MARK: - HDSExternalStoreProtocol
    
    public func fetchObjects(with objects: [HDSExternalObjectProtocol], completion: @escaping ([HDSExternalObjectProtocol]?, Error?) -> Void) {
        guard !objects.isEmpty else {
            completion([], nil)
            return
        }
        
        // Group objects by type
        var workouts: [WorkoutData] = []
        var profileMetrics: [ProfileMetricData] = []
        
        for obj in objects {
            if let workout = obj as? WorkoutData {
                workouts.append(workout)
            } else if let height = obj as? HeightData {
                profileMetrics.append(height.toProfileMetric())
            } else if let weight = obj as? WeightData {
                profileMetrics.append(weight.toProfileMetric())
            } else if let bodyFat = obj as? BodyFatData {
                profileMetrics.append(bodyFat.toProfileMetric())
            }
        }
        
        let group = DispatchGroup()
        var fetchedWorkouts: [WorkoutData] = []
        var fetchedMetrics: [ProfileMetricData] = []
        var errors: [Error] = []
        
        // Query workouts
        if !workouts.isEmpty {
            group.enter()
            queryWorkouts(workouts) { result, error in
                if let error = error {
                    errors.append(error)
                } else if let workouts = result {
                    fetchedWorkouts = workouts
                }
                group.leave()
            }
        }
        
        // Query profile metrics
        if !profileMetrics.isEmpty {
            group.enter()
            queryProfileMetrics(profileMetrics) { result, error in
                if let error = error {
                    errors.append(error)
                } else if let metrics = result {
                    fetchedMetrics = metrics
                }
                group.leave()
            }
        }
        
        group.notify(queue: .main) {
            if !errors.isEmpty {
                completion(nil, errors.first)
                return
            }
            
            // Convert back to HDSExternalObjectProtocol array
            var result: [HDSExternalObjectProtocol] = []
            
            // Convert workouts back
            for workout in fetchedWorkouts {
                result.append(workout)
            }
            
            // Convert profile metrics back to wrapper types
            for metric in fetchedMetrics {
                switch metric.metric {
                case "height":
                    result.append(HeightData(metric: metric))
                case "weight":
                    result.append(WeightData(metric: metric))
                case "body_fat":
                    result.append(BodyFatData(metric: metric))
                default:
                    break
                }
            }
            
            completion(result.isEmpty ? nil : result, nil)
        }
    }
    
    /// Adds HealthKit objects to backend
    ///
    /// IMPORTANT: All objects MUST have client_id attached (from pairing, not HealthKit).
    /// This method assumes client_id is already present in each object.
    /// Missing client_id is a validation error, not a HealthKit error.
    ///
    /// HealthKit best practice: Re-running queries may return the same data.
    /// Backend deduplicates by client_id + timestamp, so replay is safe.
    public func add(objects: [HDSExternalObjectProtocol], completion: @escaping (Error?) -> Void) {
        guard !objects.isEmpty else {
            completion(nil)
            return
        }
        
        // Group objects by type
        // Note: All objects are already tagged with client_id from pairing
        var workouts: [WorkoutData] = []
        var profileMetrics: [ProfileMetricData] = []
        
        for obj in objects {
            if let workout = obj as? WorkoutData {
                workouts.append(workout)
            } else if let height = obj as? HeightData {
                profileMetrics.append(height.toProfileMetric())
            } else if let weight = obj as? WeightData {
                profileMetrics.append(weight.toProfileMetric())
            } else if let bodyFat = obj as? BodyFatData {
                profileMetrics.append(bodyFat.toProfileMetric())
            }
        }
        
        let group = DispatchGroup()
        var syncResults: [SyncResult] = []
        
        // Sync workouts
        if !workouts.isEmpty {
            group.enter()
            syncWorkouts(workouts) { result in
                syncResults.append(result)
                group.leave()
            }
        }
        
        // Sync profile metrics
        if !profileMetrics.isEmpty {
            group.enter()
            syncProfileMetrics(profileMetrics) { result in
                syncResults.append(result)
                group.leave()
            }
        }
        
        group.notify(queue: .main) {
            // Store results for dev mode diagnostics
            self.lastSyncResults = syncResults
            self.onSyncComplete?(syncResults)
            
            // Check if any sync failed
            let failedResults = syncResults.filter { !$0.success }
            if let firstFailure = failedResults.first, let error = firstFailure.error {
                completion(error)
            } else {
                completion(nil)
            }
        }
    }
    
    /// Add objects with detailed sync result callback (for dev mode diagnostics)
    public func addWithResult(objects: [HDSExternalObjectProtocol], completion: @escaping ([SyncResult]) -> Void) {
        guard !objects.isEmpty else {
            completion([])
            return
        }
        
        // Group objects by type
        var workouts: [WorkoutData] = []
        var profileMetrics: [ProfileMetricData] = []
        
        for obj in objects {
            if let workout = obj as? WorkoutData {
                workouts.append(workout)
            } else if let height = obj as? HeightData {
                profileMetrics.append(height.toProfileMetric())
            } else if let weight = obj as? WeightData {
                profileMetrics.append(weight.toProfileMetric())
            } else if let bodyFat = obj as? BodyFatData {
                profileMetrics.append(bodyFat.toProfileMetric())
            }
        }
        
        let group = DispatchGroup()
        var syncResults: [SyncResult] = []
        
        // Sync workouts
        if !workouts.isEmpty {
            group.enter()
            syncWorkouts(workouts) { result in
                syncResults.append(result)
                group.leave()
            }
        }
        
        // Sync profile metrics
        if !profileMetrics.isEmpty {
            group.enter()
            syncProfileMetrics(profileMetrics) { result in
                syncResults.append(result)
                group.leave()
            }
        }
        
        group.notify(queue: .main) {
            completion(syncResults)
        }
    }
    
    public func update(objects: [HDSExternalObjectProtocol], completion: @escaping (Error?) -> Void) {
        guard !objects.isEmpty else {
            completion(nil)
            return
        }
        
        // Group objects by type
        var workouts: [WorkoutData] = []
        var profileMetrics: [ProfileMetricData] = []
        
        for obj in objects {
            if let workout = obj as? WorkoutData {
                workouts.append(workout)
            } else if let height = obj as? HeightData {
                profileMetrics.append(height.toProfileMetric())
            } else if let weight = obj as? WeightData {
                profileMetrics.append(weight.toProfileMetric())
            } else if let bodyFat = obj as? BodyFatData {
                profileMetrics.append(bodyFat.toProfileMetric())
            }
        }
        
        let group = DispatchGroup()
        var errors: [Error] = []
        
        // Update workouts
        if !workouts.isEmpty {
            group.enter()
            updateWorkouts(workouts) { error in
                if let error = error {
                    errors.append(error)
                }
                group.leave()
            }
        }
        
        // Update profile metrics
        if !profileMetrics.isEmpty {
            group.enter()
            updateProfileMetrics(profileMetrics) { error in
                if let error = error {
                    errors.append(error)
                }
                group.leave()
            }
        }
        
        group.notify(queue: .main) {
            if errors.isEmpty {
                completion(nil)
            } else {
                completion(errors.first)
            }
        }
    }
    
    public func delete(deletedObjects: [HDSExternalObjectProtocol], completion: @escaping (Error?) -> Void) {
        // Deletion not implemented yet - backend endpoint would need to support DELETE
        // For now, just complete successfully
        print("Delete operation not yet implemented")
        completion(nil)
    }
    
    // MARK: - Private Methods
    
    /// Query backend to check which workouts exist (by UUID)
    private func queryWorkouts(_ workouts: [WorkoutData], completion: @escaping ([WorkoutData]?, Error?) -> Void) {
        let uuids = workouts.map { $0.uuid.uuidString }
        
        guard let url = URL(string: config.workoutQueryEndpoint) else {
            completion(nil, NSError(domain: "BackendSyncStore", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid URL"]))
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        if let apiKey = config.apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        
        let payload: [String: Any] = ["uuids": uuids]
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        } catch {
            completion(nil, error)
            return
        }
        
        session.dataTask(with: request) { data, response, error in
            if let error = error {
                // If backend doesn't support query endpoint yet, return empty (all new)
                // This allows graceful degradation
                if (error as NSError).code == NSURLErrorBadServerResponse || 
                   (error as NSError).code == NSURLErrorCannotFindHost {
                    completion([], nil)
                    return
                }
                completion(nil, error)
                return
            }
            
            guard let data = data else {
                completion([], nil)
                return
            }
            
            if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode == 404 {
                    // Endpoint doesn't exist yet - return empty (graceful degradation)
                    completion([], nil)
                    return
                }
                
                guard httpResponse.statusCode >= 200 && httpResponse.statusCode < 300 else {
                    let error = NSError(
                        domain: "BackendSyncStore",
                        code: httpResponse.statusCode,
                        userInfo: [NSLocalizedDescriptionKey: "Backend returned status code \(httpResponse.statusCode)"]
                    )
                    completion(nil, error)
                    return
                }
            }
            
            // Parse response - expect array of workout objects with uuid field
            do {
                if let jsonArray = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                    var fetchedWorkouts: [WorkoutData] = []
                    
                    for json in jsonArray {
                        if let uuidString = json["uuid"] as? String,
                           let uuid = UUID(uuidString: uuidString),
                           let workout = workouts.first(where: { $0.uuid == uuid }) {
                            // Reconstruct from existing workout data (backend may have additional fields)
                            fetchedWorkouts.append(workout)
                        }
                    }
                    
                    completion(fetchedWorkouts, nil)
                } else {
                    // Empty response or unexpected format - return empty
                    completion([], nil)
                }
            } catch {
                // Parse error - assume no matches (graceful degradation)
                completion([], nil)
            }
        }.resume()
    }
    
    /// Query backend to check which profile metrics exist (by UUID)
    private func queryProfileMetrics(_ metrics: [ProfileMetricData], completion: @escaping ([ProfileMetricData]?, Error?) -> Void) {
        let uuids = metrics.map { $0.uuid.uuidString }
        
        guard let url = URL(string: config.profileMetricQueryEndpoint) else {
            completion(nil, NSError(domain: "BackendSyncStore", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid URL"]))
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        if let apiKey = config.apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        
        let payload: [String: Any] = ["uuids": uuids]
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        } catch {
            completion(nil, error)
            return
        }
        
        session.dataTask(with: request) { data, response, error in
            if let error = error {
                // If backend doesn't support query endpoint yet, return empty (all new)
                if (error as NSError).code == NSURLErrorBadServerResponse || 
                   (error as NSError).code == NSURLErrorCannotFindHost {
                    completion([], nil)
                    return
                }
                completion(nil, error)
                return
            }
            
            guard let data = data else {
                completion([], nil)
                return
            }
            
            if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode == 404 {
                    // Endpoint doesn't exist yet - return empty (graceful degradation)
                    completion([], nil)
                    return
                }
                
                guard httpResponse.statusCode >= 200 && httpResponse.statusCode < 300 else {
                    let error = NSError(
                        domain: "BackendSyncStore",
                        code: httpResponse.statusCode,
                        userInfo: [NSLocalizedDescriptionKey: "Backend returned status code \(httpResponse.statusCode)"]
                    )
                    completion(nil, error)
                    return
                }
            }
            
            // Parse response - expect array of metric objects with uuid field
            do {
                if let jsonArray = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                    var fetchedMetrics: [ProfileMetricData] = []
                    
                    for json in jsonArray {
                        if let uuidString = json["uuid"] as? String,
                           let uuid = UUID(uuidString: uuidString),
                           let metric = metrics.first(where: { $0.uuid == uuid }) {
                            // Reconstruct from existing metric data
                            fetchedMetrics.append(metric)
                        }
                    }
                    
                    completion(fetchedMetrics, nil)
                } else {
                    // Empty response or unexpected format - return empty
                    completion([], nil)
                }
            } catch {
                // Parse error - assume no matches (graceful degradation)
                completion([], nil)
            }
        }.resume()
    }
    
    private func syncWorkouts(_ workouts: [WorkoutData], completion: @escaping (SyncResult) -> Void) {
        let startTime = Date()
        let payloads = workouts.map { $0.toBackendPayload() }
        
        guard let url = URL(string: config.workoutEndpoint) else {
            let error = ErrorMapper.networkError(
                message: "Invalid server URL",
                endpoint: config.workoutEndpoint,
                detail: "Failed to create URL from: \(config.workoutEndpoint)"
            )
            completion(SyncResult(
                success: false,
                timestamp: Date(),
                endpoint: config.workoutEndpoint,
                duration: Date().timeIntervalSince(startTime),
                recordsReceived: workouts.count,
                error: error
            ))
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        if let apiKey = config.apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payloads)
        } catch {
            let appError = ErrorMapper.unknownError(
                message: "Failed to create request",
                error: error,
                endpoint: config.workoutEndpoint
            )
            completion(SyncResult(
                success: false,
                timestamp: Date(),
                endpoint: config.workoutEndpoint,
                duration: Date().timeIntervalSince(startTime),
                recordsReceived: workouts.count,
                error: appError
            ))
            return
        }
        
        session.dataTask(with: request) { data, response, error in
            let duration = Date().timeIntervalSince(startTime)
            let responseBody = data != nil ? String(data: data!, encoding: .utf8) : nil
            
            if let error = error {
                let appError = ErrorMapper.networkError(
                    message: "Connection error: \(error.localizedDescription)",
                    endpoint: self.config.workoutEndpoint,
                    detail: error.localizedDescription,
                    duration: duration
                )
                completion(SyncResult(
                    success: false,
                    timestamp: Date(),
                    endpoint: self.config.workoutEndpoint,
                    duration: duration,
                    recordsReceived: workouts.count,
                    error: appError
                ))
                return
            }
            
            guard let httpResponse = response as? HTTPURLResponse else {
                let appError = ErrorMapper.networkError(
                    message: "Invalid server response",
                    endpoint: self.config.workoutEndpoint,
                    detail: "Response is not HTTPURLResponse",
                    duration: duration
                )
                completion(SyncResult(
                    success: false,
                    timestamp: Date(),
                    endpoint: self.config.workoutEndpoint,
                    duration: duration,
                    recordsReceived: workouts.count,
                    error: appError
                ))
                return
            }
            
            let statusCode = httpResponse.statusCode
            
            guard statusCode >= 200 && statusCode < 300 else {
                let appError = ErrorMapper.backendError(
                    message: "Server error",
                    endpoint: self.config.workoutEndpoint,
                    statusCode: statusCode,
                    responseBody: responseBody,
                    detail: "Server returned status code \(statusCode)",
                    duration: duration
                )
                completion(SyncResult(
                    success: false,
                    timestamp: Date(),
                    endpoint: self.config.workoutEndpoint,
                    statusCode: statusCode,
                    duration: duration,
                    recordsReceived: workouts.count,
                    error: appError
                ))
                return
            }
            
            // Parse response to extract sync report
            var recordsInserted = workouts.count
            var duplicatesSkipped = 0
            var warningsCount = 0
            var errorsCount = 0
            var validationErrors: [String] = []
            
            if let data = data {
                do {
                    if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        if let report = json["report"] as? [String: Any] {
                            recordsInserted = report["count_inserted"] as? Int ?? workouts.count
                            duplicatesSkipped = report["duplicates_skipped"] as? Int ?? 0
                            warningsCount = report["warnings_count"] as? Int ?? 0
                            errorsCount = report["errors_count"] as? Int ?? 0
                            
                            if let errors = report["errors"] as? [String] {
                                validationErrors = errors
                            }
                        } else if let count = json["count"] as? Int {
                            recordsInserted = count
                        }
                    }
                } catch {
                    // Ignore parse errors - use defaults
                }
            }
            
            completion(SyncResult(
                success: true,
                timestamp: Date(),
                endpoint: self.config.workoutEndpoint,
                statusCode: statusCode,
                duration: duration,
                recordsReceived: workouts.count,
                recordsInserted: recordsInserted,
                duplicatesSkipped: duplicatesSkipped,
                warningsCount: warningsCount,
                errorsCount: errorsCount,
                validationErrors: validationErrors.isEmpty ? nil : validationErrors
            ))
        }.resume()
    }
    
    private func syncProfileMetrics(_ metrics: [ProfileMetricData], completion: @escaping (SyncResult) -> Void) {
        let startTime = Date()
        let payloads = metrics.map { $0.toBackendPayload() }
        
        guard let url = URL(string: config.profileMetricEndpoint) else {
            let error = ErrorMapper.networkError(
                message: "Invalid server URL",
                endpoint: config.profileMetricEndpoint,
                detail: "Failed to create URL from: \(config.profileMetricEndpoint)"
            )
            completion(SyncResult(
                success: false,
                timestamp: Date(),
                endpoint: config.profileMetricEndpoint,
                duration: Date().timeIntervalSince(startTime),
                recordsReceived: metrics.count,
                error: error
            ))
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        if let apiKey = config.apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payloads)
        } catch {
            let appError = ErrorMapper.unknownError(
                message: "Failed to create request",
                error: error,
                endpoint: config.profileMetricEndpoint
            )
            completion(SyncResult(
                success: false,
                timestamp: Date(),
                endpoint: config.profileMetricEndpoint,
                duration: Date().timeIntervalSince(startTime),
                recordsReceived: metrics.count,
                error: appError
            ))
            return
        }
        
        session.dataTask(with: request) { data, response, error in
            let duration = Date().timeIntervalSince(startTime)
            let responseBody = data != nil ? String(data: data!, encoding: .utf8) : nil
            
            if let error = error {
                let appError = ErrorMapper.networkError(
                    message: "Connection error: \(error.localizedDescription)",
                    endpoint: self.config.profileMetricEndpoint,
                    detail: error.localizedDescription,
                    duration: duration
                )
                completion(SyncResult(
                    success: false,
                    timestamp: Date(),
                    endpoint: self.config.profileMetricEndpoint,
                    duration: duration,
                    recordsReceived: metrics.count,
                    error: appError
                ))
                return
            }
            
            guard let httpResponse = response as? HTTPURLResponse else {
                let appError = ErrorMapper.networkError(
                    message: "Invalid server response",
                    endpoint: self.config.profileMetricEndpoint,
                    detail: "Response is not HTTPURLResponse",
                    duration: duration
                )
                completion(SyncResult(
                    success: false,
                    timestamp: Date(),
                    endpoint: self.config.profileMetricEndpoint,
                    duration: duration,
                    recordsReceived: metrics.count,
                    error: appError
                ))
                return
            }
            
            let statusCode = httpResponse.statusCode
            
            guard statusCode >= 200 && statusCode < 300 else {
                let appError = ErrorMapper.backendError(
                    message: "Server error",
                    endpoint: self.config.profileMetricEndpoint,
                    statusCode: statusCode,
                    responseBody: responseBody,
                    detail: "Server returned status code \(statusCode)",
                    duration: duration
                )
                completion(SyncResult(
                    success: false,
                    timestamp: Date(),
                    endpoint: self.config.profileMetricEndpoint,
                    statusCode: statusCode,
                    duration: duration,
                    recordsReceived: metrics.count,
                    error: appError
                ))
                return
            }
            
            // Parse response to extract sync report
            var recordsInserted = metrics.count
            var duplicatesSkipped = 0
            var warningsCount = 0
            var errorsCount = 0
            var validationErrors: [String] = []
            
            if let data = data {
                do {
                    if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        if let report = json["report"] as? [String: Any] {
                            recordsInserted = report["count_inserted"] as? Int ?? metrics.count
                            duplicatesSkipped = report["duplicates_skipped"] as? Int ?? 0
                            warningsCount = report["warnings_count"] as? Int ?? 0
                            errorsCount = report["errors_count"] as? Int ?? 0
                            
                            if let errors = report["errors"] as? [String] {
                                validationErrors = errors
                            }
                        } else if let count = json["count"] as? Int {
                            recordsInserted = count
                        }
                    }
                } catch {
                    // Ignore parse errors - use defaults
                }
            }
            
            completion(SyncResult(
                success: true,
                timestamp: Date(),
                endpoint: self.config.profileMetricEndpoint,
                statusCode: statusCode,
                duration: duration,
                recordsReceived: metrics.count,
                recordsInserted: recordsInserted,
                duplicatesSkipped: duplicatesSkipped,
                warningsCount: warningsCount,
                errorsCount: errorsCount,
                validationErrors: validationErrors.isEmpty ? nil : validationErrors
            ))
        }.resume()
    }
    
    /// Update existing workouts in backend (PUT/PATCH)
    private func updateWorkouts(_ workouts: [WorkoutData], completion: @escaping (Error?) -> Void) {
        let payloads = workouts.map { $0.toBackendPayload() }
        
        guard let url = URL(string: config.workoutEndpoint) else {
            completion(NSError(domain: "BackendSyncStore", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid URL"]))
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "PUT" // Use PUT for updates
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        if let apiKey = config.apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payloads)
        } catch {
            completion(error)
            return
        }
        
        let task = session.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(error)
                return
            }
            
            if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode >= 200 && httpResponse.statusCode < 300 {
                    completion(nil)
                } else {
                    // If PUT not supported, fall back to POST (idempotent)
                    if httpResponse.statusCode == 405 {
                        self.syncWorkouts(workouts) { (result: SyncResult) in
                            if result.success {
                                completion(nil)
                            } else {
                                completion(result.error ?? NSError(domain: "BackendSyncStore", code: -1, userInfo: [NSLocalizedDescriptionKey: "Sync failed"]))
                            }
                        }
                    } else {
                        let error = NSError(
                            domain: "BackendSyncStore",
                            code: httpResponse.statusCode,
                            userInfo: [NSLocalizedDescriptionKey: "Backend returned status code \(httpResponse.statusCode)"]
                        )
                        completion(error)
                    }
                }
            } else {
                completion(nil)
            }
        }
        task.resume()
    }
    
    /// Update existing profile metrics in backend (PUT/PATCH)
    private func updateProfileMetrics(_ metrics: [ProfileMetricData], completion: @escaping (Error?) -> Void) {
        let payloads = metrics.map { $0.toBackendPayload() }
        
        guard let url = URL(string: config.profileMetricEndpoint) else {
            completion(NSError(domain: "BackendSyncStore", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid URL"]))
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "PUT" // Use PUT for updates
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        if let apiKey = config.apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payloads)
        } catch {
            completion(error)
            return
        }
        
        let task = session.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(error)
                return
            }
            
            if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode >= 200 && httpResponse.statusCode < 300 {
                    completion(nil)
                } else {
                    // If PUT not supported, fall back to POST (idempotent)
                    if httpResponse.statusCode == 405 {
                        self.syncProfileMetrics(metrics) { (result: SyncResult) in
                            if result.success {
                                completion(nil)
                            } else {
                                completion(result.error ?? NSError(domain: "BackendSyncStore", code: -1, userInfo: [NSLocalizedDescriptionKey: "Sync failed"]))
                            }
                        }
                    } else {
                        let error = NSError(
                            domain: "BackendSyncStore",
                            code: httpResponse.statusCode,
                            userInfo: [NSLocalizedDescriptionKey: "Backend returned status code \(httpResponse.statusCode)"]
                        )
                        completion(error)
                    }
                }
            } else {
                completion(nil)
            }
        }
        task.resume()
    }
}

