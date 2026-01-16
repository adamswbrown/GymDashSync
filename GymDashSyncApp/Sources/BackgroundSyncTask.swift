//
//  BackgroundSyncTask.swift
//  GymDashSync
//
//  Background task for processing queued sync operations with exponential backoff.
//
//  Copyright (c) 2024
//  Licensed under the MIT License.

import Foundation

#if os(iOS)
import BackgroundTasks

/// Background sync task processor
///
/// Runs periodically to process queued sync operations that failed due to network issues.
/// Uses exponential backoff to avoid hammering the server.
public class BackgroundSyncTask {
    static let shared = BackgroundSyncTask()
    
    private let backendStore: BackendSyncStore
    private let syncQueue = SyncQueue.shared
    private var isProcessing = false
    
    public init(backendStore: BackendSyncStore? = nil) {
        self.backendStore = backendStore ?? BackendSyncStore()
    }
    
    /// Registers the background sync task (call from app delegate)
    public func registerBackgroundTask() {
        // Register the background processing task
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: "com.gymdashsync.backgroundsync",
            using: nil
        ) { [weak self] task in
            self?.handleBackgroundSync(task as! BGProcessingTask)
        }
    }
    
    /// Schedules the next background sync
    public func scheduleBackgroundSync() {
        let request = BGProcessingTaskRequest(identifier: "com.gymdashsync.backgroundsync")
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        
        do {
            try BGTaskScheduler.shared.submit(request)
            print("[BackgroundSyncTask] Background sync scheduled")
        } catch {
            print("[BackgroundSyncTask] Failed to schedule background sync: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Private Methods
    
    private func handleBackgroundSync(_ task: BGProcessingTask) {
        guard !isProcessing else {
            print("[BackgroundSyncTask] Already processing - skipping")
            task.setTaskCompleted(success: true)
            return
        }
        
        isProcessing = true
        print("[BackgroundSyncTask] Starting background sync")
        
        // Set expiration handler (called if task runs out of time)
        task.expirationHandler = { [weak self] in
            print("[BackgroundSyncTask] Task expiring - stopping background sync")
            self?.isProcessing = false
            task.setTaskCompleted(success: false)
        }
        
        // Process queued operations
        syncQueue.getPendingOperations { [weak self] (operations: [SyncOperationRecordEntity]) in
            guard let self = self else {
                task.setTaskCompleted(success: false)
                return
            }
            
            guard !operations.isEmpty else {
                print("[BackgroundSyncTask] No pending operations")
                self.isProcessing = false
                task.setTaskCompleted(success: true)
                self.scheduleBackgroundSync() // Schedule next task
                return
            }
            
            print("[BackgroundSyncTask] Processing \(operations.count) pending operation(s)")
            
            // Process operations sequentially to avoid overwhelming the backend
            self.processOperations(operations, task: task)
        }
    }
    
    private func processOperations(_ operations: [SyncOperationRecordEntity], task: BGProcessingTask) {
        guard !operations.isEmpty else {
            print("[BackgroundSyncTask] All operations processed")
            isProcessing = false
            task.setTaskCompleted(success: true)
            scheduleBackgroundSync() // Schedule next task
            return
        }
        
        let operation = operations[0]
        let remainingOperations = Array(operations.dropFirst())
        
        print("[BackgroundSyncTask] Processing operation: \(operation.id ?? "unknown") (type: \(operation.type ?? "unknown"))")
        
        // Reconstruct and send the sync operation
        sendOperation(operation) { [weak self] (success: Bool) in
            guard let self = self else { return }
            
            if success {
                self.syncQueue.markSuccess(operationId: operation.id ?? "")
            } else {
                self.syncQueue.markFailure(operationId: operation.id ?? "", error: "Background sync failed")
            }
            
            // Continue with remaining operations
            self.processOperations(remainingOperations, task: task)
        }
    }
    
    private func sendOperation(_ operation: SyncOperationRecordEntity, completion: @escaping (Bool) -> Void) {
        guard let endpoint = operation.endpoint,
              let payload = operation.payload else {
            print("[BackgroundSyncTask] Missing endpoint or payload")
            completion(false)
            return
        }
        
        // Reconstruct request
        guard let url = URL(string: endpoint) else {
            print("[BackgroundSyncTask] Invalid endpoint URL: \(endpoint)")
            completion(false)
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = payload
        
        // Add auth header if configured
        if let apiKey = backendStore.config.apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                print("[BackgroundSyncTask] Request failed: \(error.localizedDescription)")
                completion(false)
                return
            }
            
            guard let httpResponse = response as? HTTPURLResponse else {
                print("[BackgroundSyncTask] Invalid response")
                completion(false)
                return
            }
            
            let success = (200..<300).contains(httpResponse.statusCode)
            print("[BackgroundSyncTask] Operation completed with status \(httpResponse.statusCode)")
            completion(success)
        }
        
        task.resume()
    }
}

#else
// Stub for non-iOS platforms
public class BackgroundSyncTask {
    static let shared = BackgroundSyncTask()
    
    public func registerBackgroundTask() {}
    public func scheduleBackgroundSync() {}
}
#endif

