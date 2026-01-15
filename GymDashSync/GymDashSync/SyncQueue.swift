//
//  SyncQueue.swift
//  GymDashSync
//
//  Core Data queue for persistent sync operations with exponential backoff retry logic.
//
//  Copyright (c) 2024
//  Licensed under the MIT License.

import Foundation
import CoreData

/// Persistent sync queue backed by Core Data
///
/// Stores failed/pending syncs locally for eventual delivery with exponential backoff.
/// Ensures data is not lost if the app is killed before sync completes.
public class SyncQueue {
    static let shared = SyncQueue()
    
    private let container: NSPersistentContainer
    private let maxRetries = 5
    private let baseRetryDelay: TimeInterval = 2 // seconds
    
    private init() {
        // Initialize Core Data stack for sync queue
        container = NSPersistentContainer(name: "GymDashSyncQueue")
        container.loadPersistentStores { _, error in
            if let error = error {
                print("[SyncQueue] FATAL: Failed to load Core Data: \(error.localizedDescription)")
            }
        }
    }
    
    private var viewContext: NSManagedObjectContext {
        container.viewContext
    }
    
    // MARK: - Queue Management
    
    /// Adds a sync operation to the queue
    public func enqueue(
        type: SyncOperationType,
        clientId: String,
        payload: Data,
        endpoint: String
    ) {
        let backgroundContext = container.newBackgroundContext()
        backgroundContext.perform {
            let operation = NSEntityDescription.insertNewObject(forEntityName: "SyncOperation", into: backgroundContext) as! SyncOperationEntity
            
            operation.id = UUID().uuidString
            operation.type = type.rawValue
            operation.clientId = clientId
            operation.payload = payload
            operation.endpoint = endpoint
            operation.status = "pending"
            operation.retryCount = 0
            operation.createdAt = Date()
            operation.nextRetryAt = Date()
            
            do {
                try backgroundContext.save()
                print("[SyncQueue] Enqueued \(type.rawValue) operation: \(operation.id ?? "unknown")")
            } catch {
                print("[SyncQueue] Failed to enqueue operation: \(error.localizedDescription)")
            }
        }
    }
    
    /// Retrieves pending operations ready to retry
    public func getPendingOperations(completion: @escaping ([SyncOperationEntity]) -> Void) {
        let backgroundContext = container.newBackgroundContext()
        backgroundContext.perform {
            let fetchRequest = NSFetchRequest<SyncOperationEntity>(entityName: "SyncOperationEntity")
            fetchRequest.predicate = NSPredicate(format: "status == 'pending' AND nextRetryAt <= %@", Date() as NSDate)
            fetchRequest.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: true)]
            
            do {
                let operations = try backgroundContext.fetch(fetchRequest)
                DispatchQueue.main.async {
                    completion(operations)
                }
            } catch {
                print("[SyncQueue] Failed to fetch pending operations: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    completion([])
                }
            }
        }
    }
    
    /// Marks an operation as successful and removes it
    public func markSuccess(operationId: String) {
        let backgroundContext = container.newBackgroundContext()
        backgroundContext.perform {
            let fetchRequest = NSFetchRequest<SyncOperationEntity>(entityName: "SyncOperationEntity")
            fetchRequest.predicate = NSPredicate(format: "id == %@", operationId)
            
            do {
                let operations = try backgroundContext.fetch(fetchRequest)
                for operation in operations {
                    operation.status = "completed"
                    operation.completedAt = Date()
                }
                try backgroundContext.save()
                print("[SyncQueue] Marked operation as successful: \(operationId)")
            } catch {
                print("[SyncQueue] Failed to mark operation as successful: \(error.localizedDescription)")
            }
        }
    }
    
    /// Marks an operation as failed and schedules next retry with exponential backoff
    public func markFailure(operationId: String, error: String) {
        let backgroundContext = container.newBackgroundContext()
        backgroundContext.perform {
            let fetchRequest = NSFetchRequest<SyncOperationEntity>(entityName: "SyncOperationEntity")
            fetchRequest.predicate = NSPredicate(format: "id == %@", operationId)
            
            do {
                let operations = try backgroundContext.fetch(fetchRequest)
                for operation in operations {
                    operation.retryCount += 1
                    operation.lastError = error
                    operation.lastErrorAt = Date()
                    
                    if operation.retryCount >= self.maxRetries {
                        operation.status = "failed"
                        print("[SyncQueue] Operation exceeded max retries: \(operationId)")
                    } else {
                        // Calculate exponential backoff: baseDelay * 2^(retryCount-1)
                        let backoffDelay = self.baseRetryDelay * pow(2.0, Double(operation.retryCount - 1))
                        operation.nextRetryAt = Date(timeIntervalSinceNow: backoffDelay)
                        print("[SyncQueue] Scheduled retry for \(operationId) in \(Int(backoffDelay))s (attempt \(operation.retryCount))")
                    }
                }
                try backgroundContext.save()
            } catch {
                print("[SyncQueue] Failed to mark operation as failed: \(error.localizedDescription)")
            }
        }
    }
    
    /// Gets queue statistics
    public func getStats(completion: @escaping (SyncQueueStats) -> Void) {
        let backgroundContext = container.newBackgroundContext()
        backgroundContext.perform {
            let pendingRequest = NSFetchRequest<NSNumber>(entityName: "SyncOperationEntity")
            pendingRequest.predicate = NSPredicate(format: "status == 'pending'")
            pendingRequest.returnsDistinctResults = true
            pendingRequest.resultType = .countResultType
            
            let failedRequest = NSFetchRequest<NSNumber>(entityName: "SyncOperationEntity")
            failedRequest.predicate = NSPredicate(format: "status == 'failed'")
            failedRequest.returnsDistinctResults = true
            failedRequest.resultType = .countResultType
            
            do {
                let pendingCount = try backgroundContext.count(for: pendingRequest)
                let failedCount = try backgroundContext.count(for: failedRequest)
                
                let stats = SyncQueueStats(
                    pendingCount: pendingCount,
                    failedCount: failedCount
                )
                
                DispatchQueue.main.async {
                    completion(stats)
                }
            } catch {
                print("[SyncQueue] Failed to get stats: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    completion(SyncQueueStats(pendingCount: 0, failedCount: 0))
                }
            }
        }
    }
    
    /// Clears all completed operations
    public func clearCompleted() {
        let backgroundContext = container.newBackgroundContext()
        backgroundContext.perform {
            let fetchRequest = NSFetchRequest<NSFetchRequestResult>(entityName: "SyncOperationEntity")
            fetchRequest.predicate = NSPredicate(format: "status == 'completed'")
            
            let deleteRequest = NSBatchDeleteRequest(fetchRequest: fetchRequest)
            
            do {
                try backgroundContext.execute(deleteRequest)
                try backgroundContext.save()
                print("[SyncQueue] Cleared completed operations")
            } catch {
                print("[SyncQueue] Failed to clear completed operations: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - Models

public enum SyncOperationType: String {
    case workouts
    case profile
    case steps
    case sleep
}

public struct SyncQueueStats {
    public let pendingCount: Int
    public let failedCount: Int
}

// MARK: - Core Data Entity

@objc(SyncOperationEntity)
public class SyncOperationEntity: NSManagedObject {
    @NSManaged public var id: String?
    @NSManaged public var type: String?
    @NSManaged public var clientId: String?
    @NSManaged public var payload: Data?
    @NSManaged public var endpoint: String?
    @NSManaged public var status: String? // "pending", "completed", "failed"
    @NSManaged public var retryCount: Int32
    @NSManaged public var lastError: String?
    @NSManaged public var createdAt: Date?
    @NSManaged public var completedAt: Date?
    @NSManaged public var lastErrorAt: Date?
    @NSManaged public var nextRetryAt: Date?
}
