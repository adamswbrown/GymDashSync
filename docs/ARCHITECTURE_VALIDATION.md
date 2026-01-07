# Architecture Validation: HealthKit Best Practices

This document confirms the architectural decisions and validates them against Apple's HealthKit best practices.

## ✅ Confirmed Architectural Principles

### 1. HealthKit as Data Source Only
- **Status**: ✅ CORRECT
- **Implementation**: HealthKit is used exclusively to read health data. No identity, no user management, no authentication.
- **Evidence**: 
  - `WorkoutData.externalObject()` and `ProfileMetricData.*ExternalObject()` methods read from HealthKit
  - All data is tagged with `client_id` from UserDefaults (pairing), not from HealthKit
  - HealthKit queries return data; identity is applied separately

### 2. Identity Separate from HealthKit
- **Status**: ✅ CORRECT
- **Implementation**: Identity is managed via pairing codes → `client_id` (UUID) stored in UserDefaults
- **Evidence**:
  - `App.swift` shows pairing screen BEFORE HealthKit access
  - `client_id` is obtained from backend via `/pair` endpoint
  - All sync payloads include `client_id` field
  - Backend owns identity; HealthKit owns data

### 3. client_id as Sole Ownership Key
- **Status**: ✅ CORRECT
- **Implementation**: Every record sent to backend includes `client_id`. Backend uses this for ownership, isolation, and deduplication.
- **Evidence**:
  - `WorkoutData.toBackendPayload()` includes `client_id`
  - `ProfileMetricData.toBackendPayload()` includes `client_id`
  - Backend validates `client_id` exists in `clients` table
  - Backend deduplicates by `client_id` + timestamp

### 4. Permissions Requested After Pairing
- **Status**: ✅ CORRECT
- **Implementation**: App flow is: Pairing → HealthKit Permissions → Sync
- **Evidence**:
  - `App.swift` shows `PairingView` if no `client_id`
  - `ContentView` (main sync screen) only shown after pairing
  - Permission buttons appear after pairing is complete

### 5. Missing/Partial Data Expected and Tolerated
- **Status**: ⚠️ PARTIALLY CORRECT (needs improvement)
- **Current**: Returns `nil` if `client_id` missing (good), but doesn't explicitly handle partial permissions
- **Needs**: Explicit handling of partial authorization states

### 6. Replayed Data Expected
- **Status**: ✅ CORRECT
- **Implementation**: Backend deduplicates workouts by `client_id` + `start_time` ±120s + `duration_seconds` ±10%
- **Evidence**: Backend `isDuplicateWorkout()` function handles this
- **Note**: HDS framework uses anchor queries for incremental sync, but re-runs may replay data (expected)

## HealthKit Constraints (Apple Documentation)

These constraints are correctly handled:

1. ✅ **HealthKit is NOT an identity provider** - We use pairing codes
2. ✅ **Data is user-controlled** - We request read-only permissions
3. ✅ **Partial/missing data expected** - Backend handles optional fields
4. ✅ **Queries may return overlapping samples** - Backend deduplicates
5. ✅ **Characteristic data is read-only** - We only read, never write
6. ⚠️ **Simulator limitations** - Need to surface this in dev mode

## Remediation Applied

### ✅ Step 1: Architectural Correctness
- Added comprehensive documentation comments explaining HealthKit as data source only
- Confirmed identity separation (pairing codes → client_id)
- Documented that permissions are requested after pairing
- Added comments explaining missing/partial data handling

### ✅ Step 2: Demo-Style Patterns Remediated
- **No queries in viewDidLoad** - Using HDS framework with proper lifecycle management ✓
- **No one-off queries** - Using incremental anchor queries via HDS framework ✓
- **No assumptions data exists** - All data access guarded with nil checks ✓
- **Partial authorization handled** - Updated `checkAuthorizationStatus()` to distinguish states ✓
- **No silent failures** - All errors mapped to `AppError` and surfaced in dev mode ✓

### ✅ Step 3: Permission Handling Aligned
- **Availability checks** - Added `HKHealthStore.isHealthDataAvailable()` checks before all operations
- **Partial authorization** - Updated logic to distinguish `.notDetermined`, `.sharingDenied`, `.sharingAuthorized`
- **Denied types surfaced** - Added dev mode warnings for denied types
- **No permission persistence assumptions** - Always checks status before operations

### ✅ Step 4: Data Types & Queries Validated
- **Workouts use HKWorkout** - Correct type (not HKQuantitySample) ✓
- **Profile metrics use HKQuantityType** - Correct type (not characteristic types) ✓
- **Units normalized**:
  - Height: meters → centimeters ✓
  - Weight: grams (kilo) → kg ✓
  - Body fat: percent → percent (preserved) ✓
  - Distance: meters (preserved) ✓
  - Duration: seconds (calculated) ✓
  - Calories: kcal (preserved) ✓
- **Timestamps preserved** - Using ISO8601DateFormatter, no timezone conversion ✓

### ✅ Step 5: Error Surfacing Confirmed
- **HealthKit failures → AppError** - All mapped with detailed context ✓
- **Network failures visible** - Shown on-screen with HTTP status, endpoint, response body ✓
- **Backend validation visible** - Detailed validation errors shown in dev mode ✓
- **Simulator limitations explained** - Added UI warning in dev mode when HealthKit unavailable ✓

### ✅ Step 6: Assumptions Documented
- Added comprehensive section to README explaining:
  - Why pairing codes instead of Apple Sign-In
  - Why HealthKit is not trusted for identity
  - Why deduplication exists
  - Why verbose error UI is intentional
  - Which HealthKit limitations are expected, not bugs

