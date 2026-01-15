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
    public enum Environment: String {
        case dev
        case prod
        
        var baseURL: String {
            switch self {
            case .dev:
                return "http://localhost:3000"
            case .prod:
                return "https://coach-fit-eight.vercel.app"
            }
        }
    }
    
    public let environment: Environment
    public let baseURL: String
    public let apiKey: String?
    public let workoutEndpoint: String
    public let profileMetricEndpoint: String
    public let stepsEndpoint: String
    public let sleepEndpoint: String
    public let workoutQueryEndpoint: String
    public let profileMetricQueryEndpoint: String
    
    public init(baseURL: String, apiKey: String? = nil, environment: Environment = .prod) {
        self.environment = environment
        self.baseURL = baseURL
        self.apiKey = apiKey
        // CoachFit ingest endpoints
        self.workoutEndpoint = "\(baseURL)/api/ingest/workouts"
        self.profileMetricEndpoint = "\(baseURL)/api/ingest/profile"
        self.stepsEndpoint = "\(baseURL)/api/ingest/steps"
        self.sleepEndpoint = "\(baseURL)/api/ingest/sleep"
        // Query endpoints are optional; leave pointed at ingest for graceful 404 handling
        self.workoutQueryEndpoint = "\(baseURL)/api/ingest/workouts/query"
        self.profileMetricQueryEndpoint = "\(baseURL)/api/ingest/profile/query"
    }
    
    public static var `default`: BackendConfig {
        // Environment override via UserDefaults key "GymDashSync.Environment" ("dev"|"prod")
        let storedEnv = UserDefaults.standard.string(forKey: "GymDashSync.Environment")
        let environment = Environment(rawValue: storedEnv ?? "") ?? {
            #if DEBUG
            return .prod  // Default to production even in debug mode
            #else
            return .prod
            #endif
        }()
        // URL override still supported for manual testing
        let overrideURL = UserDefaults.standard.string(forKey: "GymDashSync.BackendURL")
        let resolvedBase = overrideURL ?? environment.baseURL
        let key = UserDefaults.standard.string(forKey: "GymDashSync.APIKey")
        return BackendConfig(baseURL: resolvedBase, apiKey: key, environment: environment)
    }
    
    /// Extract hostname from baseURL for display purposes
    public var hostname: String {
        guard let url = URL(string: baseURL),
              let host = url.host else {
            return baseURL
        }
        return host
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
    public let config: BackendConfig
    private let session: URLSession
    
    // Dev mode: Track last sync results
    public var lastSyncResults: [SyncResult] = []
    public var onSyncComplete: (([SyncResult]) -> Void)?
    
    // Track most recent workout synced
    public var mostRecentWorkoutSynced: WorkoutData? = nil
    public var onMostRecentWorkoutChanged: ((WorkoutData?) -> Void)?
    
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
            // Even if no objects, create a result entry to track that the query ran
            // This helps with diagnostics when force re-sync returns 0 records
            let emptyResult = SyncResult(
                success: true,
                timestamp: Date(),
                recordsReceived: 0,
                recordsInserted: 0,
                duplicatesSkipped: 0
            )
            self.lastSyncResults = [emptyResult]
            self.onSyncComplete?([emptyResult])
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
            if let firstFailure = failedResults.first, let appError = firstFailure.error {
                print("[BackendSyncStore] Sync failed with error: \(appError)")
                print("[BackendSyncStore] AppError details: category=\(appError.category.rawValue), message=\(appError.message)")
                if let detail = appError.detail {
                    print("[BackendSyncStore] Error detail: \(detail)")
                }
                if let context = appError.context {
                    print("[BackendSyncStore] Error context: endpoint=\(context.endpoint ?? "nil"), statusCode=\(context.statusCode?.description ?? "nil")")
                }
                completion(appError)
            } else {
                let successCount = syncResults.filter { $0.success }.count
                print("[BackendSyncStore] All syncs completed successfully (\(successCount)/\(syncResults.count))")
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
        guard let firstClientId = workouts.first?.clientId else {
            let result = SyncResult(
                success: false,
                timestamp: Date(),
                endpoint: config.workoutEndpoint,
                duration: Date().timeIntervalSince(startTime),
                recordsReceived: workouts.count,
                error: ErrorMapper.unknownError(message: "Missing client_id for workouts", error: nil, endpoint: config.workoutEndpoint)
            )
            SyncQueue.shared.logFailure(result)
            completion(result)
            return
        }
        // Ensure all workouts share the same client_id (CoachFit expects one client per payload)
        guard workouts.allSatisfy({ $0.clientId == firstClientId }) else {
            let result = SyncResult(
                success: false,
                timestamp: Date(),
                endpoint: config.workoutEndpoint,
                duration: Date().timeIntervalSince(startTime),
                recordsReceived: workouts.count,
                error: ErrorMapper.unknownError(message: "Multiple client_ids in workout batch", error: nil, endpoint: config.workoutEndpoint)
            )
            SyncQueue.shared.logFailure(result)
            completion(result)
            return
        }
        let formatter = ISO8601DateFormatter()
        let workoutPayloads: [[String: Any]] = workouts.map { workout in
            return [
                "workout_type": workout.workoutType,
                "start_time": formatter.string(from: workout.startTime),
                "end_time": formatter.string(from: workout.endTime),
                "duration_seconds": Int(workout.durationSeconds.rounded()),
                "calories_active": workout.activeEnergyBurned as Any,
                "distance_meters": workout.distanceMeters as Any,
                "avg_heart_rate": workout.averageHeartRate as Any,
                "max_heart_rate": workout.averageHeartRate as Any, // placeholder until max HR collected separately
                "source_device": workout.sourceDevice as Any,
                "metadata": ["healthkit_uuid": workout.uuid.uuidString]
            ].compactMapValues { $0 }
        }

        let requestBody: [String: Any] = [
            "client_id": firstClientId,
            "workouts": workoutPayloads
        ]

        guard let url = URL(string: config.workoutEndpoint) else {
            let error = ErrorMapper.networkError(
                message: "Invalid server URL",
                endpoint: config.workoutEndpoint,
                detail: "Failed to create URL from: \(config.workoutEndpoint)"
            )
            let result = SyncResult(
                success: false,
                timestamp: Date(),
                endpoint: config.workoutEndpoint,
                duration: Date().timeIntervalSince(startTime),
                recordsReceived: workouts.count,
                error: error
            )
            SyncQueue.shared.logFailure(result)
            completion(result)
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        if let apiKey = config.apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        } catch {
            let appError = ErrorMapper.unknownError(
                message: "Failed to create request",
                error: error,
                endpoint: config.workoutEndpoint
            )
            let result = SyncResult(
                success: false,
                timestamp: Date(),
                endpoint: config.workoutEndpoint,
                duration: Date().timeIntervalSince(startTime),
                recordsReceived: workouts.count,
                error: appError
            )
            SyncQueue.shared.logFailure(result)
            completion(result)
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
                let result = SyncResult(
                    success: false,
                    timestamp: Date(),
                    endpoint: self.config.workoutEndpoint,
                    duration: duration,
                    recordsReceived: workouts.count,
                    error: appError
                )
                SyncQueue.shared.logFailure(result)
                completion(result)
                return
            }
            
            guard let httpResponse = response as? HTTPURLResponse else {
                let appError = ErrorMapper.networkError(
                    message: "Invalid server response",
                    endpoint: self.config.workoutEndpoint,
                    detail: "Response is not HTTPURLResponse",
                    duration: duration
                )
                let result = SyncResult(
                    success: false,
                    timestamp: Date(),
                    endpoint: self.config.workoutEndpoint,
                    duration: duration,
                    recordsReceived: workouts.count,
                    error: appError
                )
                SyncQueue.shared.logFailure(result)
                completion(result)
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
                let result = SyncResult(
                    success: false,
                    timestamp: Date(),
                    endpoint: self.config.workoutEndpoint,
                    statusCode: statusCode,
                    duration: duration,
                    recordsReceived: workouts.count,
                    error: appError
                )
                SyncQueue.shared.logFailure(result)
                completion(result)
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
                        // Backend returns count_inserted, duplicates_skipped, etc. directly
                        if let inserted = json["count_inserted"] as? Int {
                            recordsInserted = inserted
                        }
                        if let duplicates = json["duplicates_skipped"] as? Int {
                            duplicatesSkipped = duplicates
                        }
                        if let warnings = json["warnings_count"] as? Int {
                            warningsCount = warnings
                        }
                        if let errors = json["errors_count"] as? Int {
                            errorsCount = errors
                        }
                        if let errors = json["errors"] as? [String] {
                            validationErrors = errors
                        }
                    }
                } catch {
                    // Ignore parse errors - use defaults
                }
            }
            
            // After successful completion, find most recent workout
            if !workouts.isEmpty {
                let mostRecent = workouts.max(by: { $0.startTime < $1.startTime })
                self.mostRecentWorkoutSynced = mostRecent
                DispatchQueue.main.async {
                    self.onMostRecentWorkoutChanged?(mostRecent)
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
        guard let firstClientId = metrics.first?.clientId else {
            let result = SyncResult(
                success: false,
                timestamp: Date(),
                endpoint: config.profileMetricEndpoint,
                duration: Date().timeIntervalSince(startTime),
                recordsReceived: metrics.count,
                error: ErrorMapper.unknownError(message: "Missing client_id for profile metrics", error: nil, endpoint: config.profileMetricEndpoint)
            )
            SyncQueue.shared.logFailure(result)
            completion(result)
            return
        }
        guard metrics.allSatisfy({ $0.clientId == firstClientId }) else {
            let result = SyncResult(
                success: false,
                timestamp: Date(),
                endpoint: config.profileMetricEndpoint,
                duration: Date().timeIntervalSince(startTime),
                recordsReceived: metrics.count,
                error: ErrorMapper.unknownError(message: "Multiple client_ids in profile metric batch", error: nil, endpoint: config.profileMetricEndpoint)
            )
            SyncQueue.shared.logFailure(result)
            completion(result)
            return
        }
        let formatter = ISO8601DateFormatter()
        let metricPayloads: [[String: Any]] = metrics.map { metric in
            [
                "metric": metric.metric,
                "value": metric.value,
                "unit": metric.unit,
                "measured_at": formatter.string(from: metric.measuredAt),
                "source": metric.source,
                "healthkit_uuid": metric.uuid.uuidString
            ]
        }
        let requestBody: [String: Any] = [
            "client_id": firstClientId,
            "metrics": metricPayloads
        ]

        guard let url = URL(string: config.profileMetricEndpoint) else {
            let error = ErrorMapper.networkError(
                message: "Invalid server URL",
                endpoint: config.profileMetricEndpoint,
                detail: "Failed to create URL from: \(config.profileMetricEndpoint)"
            )
            let result = SyncResult(
                success: false,
                timestamp: Date(),
                endpoint: config.profileMetricEndpoint,
                duration: Date().timeIntervalSince(startTime),
                recordsReceived: metrics.count,
                error: error
            )
            SyncQueue.shared.logFailure(result)
            completion(result)
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        if let apiKey = config.apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        } catch {
            let appError = ErrorMapper.unknownError(
                message: "Failed to create request",
                error: error,
                endpoint: config.profileMetricEndpoint
            )
            let result = SyncResult(
                success: false,
                timestamp: Date(),
                endpoint: config.profileMetricEndpoint,
                duration: Date().timeIntervalSince(startTime),
                recordsReceived: metrics.count,
                error: appError
            )
            SyncQueue.shared.logFailure(result)
            completion(result)
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
                let result = SyncResult(
                    success: false,
                    timestamp: Date(),
                    endpoint: self.config.profileMetricEndpoint,
                    duration: duration,
                    recordsReceived: metrics.count,
                    error: appError
                )
                SyncQueue.shared.logFailure(result)
                completion(result)
                return
            }
            
            guard let httpResponse = response as? HTTPURLResponse else {
                let appError = ErrorMapper.networkError(
                    message: "Invalid server response",
                    endpoint: self.config.profileMetricEndpoint,
                    detail: "Response is not HTTPURLResponse",
                    duration: duration
                )
                let result = SyncResult(
                    success: false,
                    timestamp: Date(),
                    endpoint: self.config.profileMetricEndpoint,
                    duration: duration,
                    recordsReceived: metrics.count,
                    error: appError
                )
                SyncQueue.shared.logFailure(result)
                completion(result)
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
                let result = SyncResult(
                    success: false,
                    timestamp: Date(),
                    endpoint: self.config.profileMetricEndpoint,
                    statusCode: statusCode,
                    duration: duration,
                    recordsReceived: metrics.count,
                    error: appError
                )
                SyncQueue.shared.logFailure(result)
                completion(result)
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
                        // Backend returns count_inserted, etc. directly
                        if let inserted = json["count_inserted"] as? Int {
                            recordsInserted = inserted
                        }
                        if let duplicates = json["duplicates_skipped"] as? Int {
                            duplicatesSkipped = duplicates
                        }
                        if let warnings = json["warnings_count"] as? Int {
                            warningsCount = warnings
                        }
                        if let errors = json["errors_count"] as? Int {
                            errorsCount = errors
                        }
                        if let errors = json["errors"] as? [String] {
                            validationErrors = errors
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

    // MARK: - Steps
    public func syncSteps(_ steps: [StepData], completion: @escaping (SyncResult) -> Void) {
        let startTime = Date()
        guard let firstClientId = steps.first?.clientId else {
            let result = SyncResult(
                success: false,
                timestamp: Date(),
                endpoint: config.stepsEndpoint,
                duration: Date().timeIntervalSince(startTime),
                recordsReceived: steps.count,
                error: ErrorMapper.unknownError(message: "Missing client_id for steps", error: nil, endpoint: config.stepsEndpoint)
            )
            SyncQueue.shared.logFailure(result)
            completion(result)
            return
        }
        guard steps.allSatisfy({ $0.clientId == firstClientId }) else {
            let result = SyncResult(
                success: false,
                timestamp: Date(),
                endpoint: config.stepsEndpoint,
                duration: Date().timeIntervalSince(startTime),
                recordsReceived: steps.count,
                error: ErrorMapper.unknownError(message: "Multiple client_ids in steps batch", error: nil, endpoint: config.stepsEndpoint)
            )
            SyncQueue.shared.logFailure(result)
            completion(result)
            return
        }
        let isoFormatter = ISO8601DateFormatter()
        let stepPayloads = steps.map { $0.toBackendPayload(formatter: isoFormatter) }
        let requestBody: [String: Any] = [
            "client_id": firstClientId,
            "steps": stepPayloads
        ]
        guard let url = URL(string: config.stepsEndpoint) else {
            let error = ErrorMapper.networkError(
                message: "Invalid server URL",
                endpoint: config.stepsEndpoint,
                detail: "Failed to create URL from: \(config.stepsEndpoint)"
            )
            let result = SyncResult(success: false, timestamp: Date(), endpoint: config.stepsEndpoint, duration: Date().timeIntervalSince(startTime), recordsReceived: steps.count, error: error)
            SyncQueue.shared.logFailure(result)
            completion(result)
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey = config.apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        } catch {
            let appError = ErrorMapper.unknownError(message: "Failed to create request", error: error, endpoint: config.stepsEndpoint)
            let result = SyncResult(success: false, timestamp: Date(), endpoint: config.stepsEndpoint, duration: Date().timeIntervalSince(startTime), recordsReceived: steps.count, error: appError)
            SyncQueue.shared.logFailure(result)
            completion(result)
            return
        }
        session.dataTask(with: request) { data, response, error in
            let duration = Date().timeIntervalSince(startTime)
            let responseBody = data != nil ? String(data: data!, encoding: .utf8) : nil
            if let error = error {
                let appError = ErrorMapper.networkError(message: "Connection error: \(error.localizedDescription)", endpoint: self.config.stepsEndpoint, detail: error.localizedDescription, duration: duration)
                let result = SyncResult(success: false, timestamp: Date(), endpoint: self.config.stepsEndpoint, duration: duration, recordsReceived: steps.count, error: appError)
                SyncQueue.shared.logFailure(result)
                completion(result)
                return
            }
            guard let httpResponse = response as? HTTPURLResponse else {
                let appError = ErrorMapper.networkError(message: "Invalid server response", endpoint: self.config.stepsEndpoint, detail: "Response is not HTTPURLResponse", duration: duration)
                let result = SyncResult(success: false, timestamp: Date(), endpoint: self.config.stepsEndpoint, duration: duration, recordsReceived: steps.count, error: appError)
                SyncQueue.shared.logFailure(result)
                completion(result)
                return
            }
            let statusCode = httpResponse.statusCode
            guard statusCode >= 200 && statusCode < 300 else {
                let appError = ErrorMapper.backendError(message: "Server error", endpoint: self.config.stepsEndpoint, statusCode: statusCode, responseBody: responseBody, detail: "Server returned status code \(statusCode)", duration: duration)
                let result = SyncResult(success: false, timestamp: Date(), endpoint: self.config.stepsEndpoint, statusCode: statusCode, duration: duration, recordsReceived: steps.count, error: appError)
                SyncQueue.shared.logFailure(result)
                completion(result)
                return
            }
            completion(SyncResult(success: true, timestamp: Date(), endpoint: self.config.stepsEndpoint, statusCode: statusCode, duration: duration, recordsReceived: steps.count))
        }.resume()
    }

    // MARK: - Sleep
    public func syncSleep(_ sleepRecords: [SleepData], completion: @escaping (SyncResult) -> Void) {
        let startTime = Date()
        guard let firstClientId = sleepRecords.first?.clientId else {
            let result = SyncResult(success: false, timestamp: Date(), endpoint: config.sleepEndpoint, duration: Date().timeIntervalSince(startTime), recordsReceived: sleepRecords.count, error: ErrorMapper.unknownError(message: "Missing client_id for sleep", error: nil, endpoint: config.sleepEndpoint))
            SyncQueue.shared.logFailure(result)
            completion(result)
            return
        }
        guard sleepRecords.allSatisfy({ $0.clientId == firstClientId }) else {
            let result = SyncResult(success: false, timestamp: Date(), endpoint: config.sleepEndpoint, duration: Date().timeIntervalSince(startTime), recordsReceived: sleepRecords.count, error: ErrorMapper.unknownError(message: "Multiple client_ids in sleep batch", error: nil, endpoint: config.sleepEndpoint))
            SyncQueue.shared.logFailure(result)
            completion(result)
            return
        }
        let isoFormatter = ISO8601DateFormatter()
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let sleepPayloads = sleepRecords.map { $0.toBackendPayload(formatter: isoFormatter, dateOnlyFormatter: dateFormatter) }
        let requestBody: [String: Any] = [
            "client_id": firstClientId,
            "sleep_records": sleepPayloads
        ]
        guard let url = URL(string: config.sleepEndpoint) else {
            let error = ErrorMapper.networkError(message: "Invalid server URL", endpoint: config.sleepEndpoint, detail: "Failed to create URL from: \(config.sleepEndpoint)")
            let result = SyncResult(success: false, timestamp: Date(), endpoint: config.sleepEndpoint, duration: Date().timeIntervalSince(startTime), recordsReceived: sleepRecords.count, error: error)
            SyncQueue.shared.logFailure(result)
            completion(result)
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey = config.apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        } catch {
            let appError = ErrorMapper.unknownError(message: "Failed to create request", error: error, endpoint: config.sleepEndpoint)
            let result = SyncResult(success: false, timestamp: Date(), endpoint: config.sleepEndpoint, duration: Date().timeIntervalSince(startTime), recordsReceived: sleepRecords.count, error: appError)
            SyncQueue.shared.logFailure(result)
            completion(result)
            return
        }
        session.dataTask(with: request) { data, response, error in
            let duration = Date().timeIntervalSince(startTime)
            let responseBody = data != nil ? String(data: data!, encoding: .utf8) : nil
            if let error = error {
                let appError = ErrorMapper.networkError(message: "Connection error: \(error.localizedDescription)", endpoint: self.config.sleepEndpoint, detail: error.localizedDescription, duration: duration)
                let result = SyncResult(success: false, timestamp: Date(), endpoint: self.config.sleepEndpoint, duration: duration, recordsReceived: sleepRecords.count, error: appError)
                SyncQueue.shared.logFailure(result)
                completion(result)
                return
            }
            guard let httpResponse = response as? HTTPURLResponse else {
                let appError = ErrorMapper.networkError(message: "Invalid server response", endpoint: self.config.sleepEndpoint, detail: "Response is not HTTPURLResponse", duration: duration)
                let result = SyncResult(success: false, timestamp: Date(), endpoint: self.config.sleepEndpoint, duration: duration, recordsReceived: sleepRecords.count, error: appError)
                SyncQueue.shared.logFailure(result)
                completion(result)
                return
            }
            let statusCode = httpResponse.statusCode
            guard statusCode >= 200 && statusCode < 300 else {
                let appError = ErrorMapper.backendError(message: "Server error", endpoint: self.config.sleepEndpoint, statusCode: statusCode, responseBody: responseBody, detail: "Server returned status code \(statusCode)", duration: duration)
                let result = SyncResult(success: false, timestamp: Date(), endpoint: self.config.sleepEndpoint, statusCode: statusCode, duration: duration, recordsReceived: sleepRecords.count, error: appError)
                SyncQueue.shared.logFailure(result)
                completion(result)
                return
            }
            completion(SyncResult(success: true, timestamp: Date(), endpoint: self.config.sleepEndpoint, statusCode: statusCode, duration: duration, recordsReceived: sleepRecords.count))
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

