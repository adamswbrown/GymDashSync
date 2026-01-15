# Phase 5 Implementation Plan: Integration Hooks

**Status:** Ready for Implementation  
**Estimated Duration:** 45 minutes  
**Priority:** High (blocks production deployment)

---

## Overview

This document provides step-by-step implementation guidance for Phase 5 of the GymDashSync iOS integration. All code components exist and compile successfully—this phase focuses on wiring them together to create an end-to-end sync system with offline-first capabilities.

---

## Task 1: Wire SyncQueue into BackendSyncStore Error Handlers

**File:** `GymDashSync/GymDashSync/BackendSyncStore.swift`  
**Duration:** 15 minutes  
**Impact:** Enables automatic queuing of failed sync operations

### 1.1 Update syncWorkouts Method

**Location:** Search for `private func syncWorkouts`

**Pattern:** In every network error block, add SyncQueue.enqueue() before returning the error completion:

```swift
// EXISTING CODE:
if let error = error {
    let appError = ErrorMapper.networkError(...)
    completion(SyncResult(success: false, ..., error: appError))
    return
}

// ADD THIS BLOCK BEFORE completion():
if let error = error {
    let appError = ErrorMapper.networkError(...)
    
    // QUEUE FOR RETRY
    if !workouts.isEmpty, let clientId = workouts.first?.clientId {
        do {
            let payload = try JSONSerialization.data(withJSONObject: requestBody)
            SyncQueue.shared.enqueue(
                type: .workouts,
                clientId: clientId,
                payload: payload,
                endpoint: self.config.workoutEndpoint
            )
        } catch {
            print("[BackendSyncStore] Failed to queue workouts: \(error)")
        }
    }
    
    completion(SyncResult(success: false, ..., error: appError))
    return
}
```

**Locations to update in syncWorkouts:**
- Line ~960: Connection error handling
- Line ~980: Invalid response handling
- Line ~1000: Server error (statusCode >= 300)

### 1.2 Update syncProfileMetrics Method

**Location:** Search for `private func syncProfileMetrics`  
**Type:** `.profile`  
**Same pattern as syncWorkouts**

**Locations:**
- Line ~1060: Connection error
- Line ~1080: Invalid response
- Line ~1100: Server error

### 1.3 Update syncSteps Method

**Location:** Search for `public func syncSteps`  
**Type:** `.steps`  
**Same pattern, using config.stepsEndpoint**

**Locations:**
- Around line 1160: Network errors
- Around line 1170: Response errors

### 1.4 Update syncSleep Method

**Location:** Search for `public func syncSleep`  
**Type:** `.sleep`  
**Same pattern, using config.sleepEndpoint**

**Locations:**
- Similar to syncSteps pattern

---

## Task 2: Wire SyncQueue into SyncManager Collection Error Paths

**File:** `GymDashSync/GymDashSync/SyncManager.swift`  
**Duration:** 10 minutes  
**Impact:** Ensures collection failures are also queued for retry

### 2.1 Update collectAndSyncSteps Method

**Location:** Search for `public func collectAndSyncSteps`

**Current Code (around line 1315):**
```swift
self.collectAndSyncSteps { success, error in
    if let error = error {
        // Handle error - currently just logs
        print("[SyncManager] Steps sync failed: \(error)")
    }
    group.leave()
}
```

**Updated Code:**
```swift
self.collectAndSyncSteps { success, error in
    if let error = error {
        // Queue for retry if client_id exists
        if let clientId = UserDefaults.standard.string(forKey: "GymDashSync.ClientId"),
           let stepsPayload = self.lastStepsPayload {  // Store payload after collection
            SyncQueue.shared.enqueue(
                type: .steps,
                clientId: clientId,
                payload: stepsPayload,
                endpoint: self.backendStore.config.stepsEndpoint
            )
        }
        print("[SyncManager] Steps sync failed and queued: \(error)")
    }
    group.leave()
}
```

**Note:** You'll need to store the steps payload during collection:
```swift
private var lastStepsPayload: Data?

// In collectAndSyncSteps, before calling backendStore.syncSteps():
if let payload = try? JSONSerialization.data(withJSONObject: requestBody) {
    self.lastStepsPayload = payload
}
```

### 2.2 Update collectAndSyncSleep Method

**Location:** Search for `public func collectAndSyncSleep`  
**Type:** `.sleep`  
**Same pattern as collectAndSyncSteps**

---

## Task 3: Register BackgroundSyncTask in AppDelegate

**File:** `GymDashSync/GymDashSync/AppDelegate.swift`  
**Duration:** 5 minutes  
**Impact:** Enables background processing of queued operations

### 3.1 Update application(_:didFinishLaunchingWithOptions:)

**Current Code:**
```swift
func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
    syncManager = SyncManager()
    syncManager?.startObserving()
    
    return true
}
```

**Updated Code:**
```swift
func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
    syncManager = SyncManager()
    syncManager?.startObserving()
    
    // REGISTER BACKGROUND SYNC TASK
    BackgroundSyncTask.shared.registerBackgroundTask()
    
    return true
}
```

---

## Task 4: Testing & Validation

**Duration:** 15 minutes  
**Acceptance Criteria:** All 5 scenarios pass

### 4.1 Scenario 1: Network Failure Auto-Queues

**Setup:**
1. Run app in simulator/device
2. Disable WiFi (Settings → WiFi off)
3. Trigger manual sync button
4. Observe console for "[SyncQueue]" messages

**Expected:**
- Sync fails with network error
- "[SyncQueue] Enqueued steps operation" logged
- No crash

**Validation:**
```swift
// Add to SyncQueue.swift for debugging:
print("[SyncQueue] Operation count: \(getPendingOperations().count)")
```

### 4.2 Scenario 2: Queue Persists Across App Kill

**Setup:**
1. Disable WiFi
2. Trigger sync (queue operation)
3. Force quit app: Cmd+Shift+K in Xcode, or Settings → Force Close
4. Relaunch app
5. Check Core Data

**Expected:**
- Operation still in queue after relaunch
- BackgroundSyncTask attempts to process if WiFi is on

**Validation:**
- Check Xcode Core Data inspector
- Or add debug view in Settings showing queue count

### 4.3 Scenario 3: Background Sync on WiFi Reconnect

**Setup:**
1. Disable WiFi
2. Queue operation (see 4.1)
3. Enable WiFi
4. Put app in background
5. System triggers background task (varies by device, typically within 15 min)
6. Or manually test with device logs: `log stream --predicate 'eventMessage contains[c] "BGProcessingTask"'`

**Expected:**
- "[BackgroundSyncTask] Processing operation" appears in logs
- Operation marked as success/failed
- No infinite retry on permanent failures

### 4.4 Scenario 4: Exponential Backoff Timing

**Setup:**
1. Queue multiple operations
2. Trigger background sync with network disabled
3. Monitor retry timing

**Expected:**
- Attempt 1: immediate
- Attempt 2: 4s delay (2 * 2^0)
- Attempt 3: 8s delay (2 * 2^1)
- Attempt 4: 16s delay
- Attempt 5: 32s delay
- Attempt 6+: marked as failed

**Validation:**
- Check SyncQueue.nextRetryAt timestamps in Core Data
- Formula: baseDelay * 2^(retryCount - 1) = 2 * 2^(n-1)

### 4.5 Scenario 5: High Volume Performance

**Setup:**
1. Trigger 50+ sync operations
2. Queue all with network disabled
3. Re-enable network and monitor memory/CPU

**Expected:**
- App does not crash
- Memory stays < 200MB increase
- Background sync completes within 1 minute
- No UI freezing

---

## Task 5: Production Deployment Checklist

Before shipping Phase 5 changes:

### Code Quality
- [ ] No compiler warnings in BackendSyncStore.swift
- [ ] No compiler warnings in SyncManager.swift
- [ ] No compiler warnings in AppDelegate.swift
- [ ] SyncQueue.shared references check for nil safely

### Xcode Configuration
- [ ] Background Modes: "Processing" enabled
- [ ] Capabilities: Background Processing checked
- [ ] Info.plist key `com.apple.developer.backgroundtasks` present
- [ ] BGProcessing entitlement in signing

### Testing
- [ ] All 5 scenarios pass locally
- [ ] Tested on physical device (not just simulator)
- [ ] Tested with production CoachFit endpoint
- [ ] Tested with slow network (throttle in Network Link Conditioner)
- [ ] Tested with timeout scenarios (kill network mid-sync)

### Documentation
- [ ] Update README with offline-first explanation
- [ ] Document SyncQueue behavior in code comments
- [ ] Add troubleshooting guide for common issues

### Deployment
- [ ] Bump app version number (Phase 5 designation)
- [ ] Create release notes mentioning offline-first sync
- [ ] Test TestFlight build before App Store submission
- [ ] Monitor crash logs post-release for queue-related issues

---

## Expected Outcomes

After Phase 5 implementation and testing:

### System Behavior
- ✅ User triggers sync → network unavailable → operation queued locally
- ✅ App backgrounded → system triggers background sync → queue processes with backoff
- ✅ App killed with queued operations → relaunch → operations persist and retry
- ✅ Coach sees no data loss → all sync attempts eventually succeed or are marked failed

### User Experience
- ✅ Sync failures are transparent (error shown, but not blocking)
- ✅ Future syncs automatically retry without user action
- ✅ Network disruptions do not cause data loss
- ✅ Background sync is silent (no notifications unless failures)

### Reliability Metrics
- ✅ 99%+ operation success rate (after retries)
- ✅ < 5s additional latency from queueing overhead
- ✅ < 10MB persistent storage for queue (10,000+ operations)
- ✅ Zero false positives in sync reporting

---

## Rollback Plan

If Phase 5 causes issues post-deployment:

1. **If queuing breaks syncs:** Comment out SyncQueue.enqueue() calls, redeploy
2. **If background task crashes app:** Remove BackgroundSyncTask.registerBackgroundTask() line
3. **If Core Data migration fails:** Delete app and reinstall (user data safe on backend)

---

## Timeline

| Task | Duration | Dependencies |
|------|----------|--------------|
| 1. BackendSyncStore wiring | 15 min | None |
| 2. SyncManager wiring | 10 min | Task 1 complete |
| 3. AppDelegate registration | 5 min | Task 1-2 complete |
| 4. Testing | 15 min | Task 1-3 complete |
| 5. Code review | 10 min | Task 1-4 complete |
| **Total** | **55 min** | — |

---

## Questions & Support

Refer to:
- [EVALUATION_REPORT.md](EVALUATION_REPORT.md) - Detailed completion breakdown
- [SyncQueue.swift](GymDashSync/GymDashSync/SyncQueue.swift) - API documentation
- [BackgroundSyncTask.swift](GymDashSync/GymDashSync/BackgroundSyncTask.swift) - BGTask implementation
- Copilot Instructions in `.github/copilot-instructions.md`

---

**Ready to start? Begin with Task 1 and follow this guide sequentially.**
