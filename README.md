# GymDashSync

A lightweight iOS companion app for the **CoachFit** platform that reads Apple Health (HealthKit) data and syncs it to the CoachFit backend. This is **not** a fitness app or visual dashboard—it's a minimal sync client focused solely on data synchronization between iOS devices and the coaching platform.

## Application Purpose

GymDashSync is the iOS client for **CoachFit**, a coaching platform that helps clients track fitness data and coaches manage their client base. The app's sole responsibility is to:

1. **Collect HealthKit data** - Automatically read steps, sleep, and workout data from Apple Health
2. **Sync to CoachFit** - Send collected data to the CoachFit backend via secure APIs
3. **Support manual entries** - Allow coaches to override or correct HealthKit data via the CoachFit web dashboard
4. **Handle sync failures** - Queue failed syncs locally and retry with exponential backoff when connectivity is restored
5. **Display sync status** - Show users connection status and last sync time

The app is designed to work **exclusively with the CoachFit platform**—it has no standalone functionality.

## CoachFit Integration (Current Status: In Progress)

### Critical Path Implementation (Jan 15, 2026) ✅ Complete

GymDashSync is currently being migrated from a legacy backend to the **CoachFit API**. The following critical path items have been completed:

**Backend Enhancement (Items 1-3):**
- ✅ `/api/ingest/steps` endpoint - Receives HealthKit step counts with manual > HealthKit data priority
- ✅ `/api/ingest/sleep` endpoint - Receives HealthKit sleep data with manual > HealthKit data priority
- ✅ Entry model dataSources field - Tracks data source (manual vs HealthKit) for transparency

**iOS Implementation (Item 4):**
- ✅ **SyncQueue** - Core Data-backed persistent queue for failed syncs with exponential backoff retry
- ✅ **BackgroundSyncTask** - iOS 13+ background processor for automatic retry during idle periods
- ✅ **Step Collection** - HKStatisticsCollectionQuery for 365-day daily aggregation
- ✅ **Sleep Collection** - HKSampleQuery for 365-day daily aggregation
- ✅ **Backend Sync Methods** - syncSteps() and syncSleep() methods in BackendSyncStore

### Data Priority: Manual > HealthKit

A key feature of the CoachFit integration is **data priority control**:

- **Manual entries take precedence** - When a coach manually enters or corrects data via the CoachFit dashboard, that data is preserved
- **HealthKit as default** - If no manual data exists for a date, HealthKit data is synced automatically
- **Transparent tracking** - The Entry.dataSources field tracks whether data came from manual entry or HealthKit
- **Coach control** - Coaches can see and control which data source is active for each client's metrics

**Example:** If a client's Apple Watch incorrectly records 50,000 steps due to a glitch, the coach can manually correct it to 8,000 steps. Future HealthKit syncs won't overwrite that correction.

## CoachFit API Endpoints

GymDashSync communicates with the following CoachFit backend endpoints:

| Endpoint | Method | Purpose | Status |
|----------|--------|---------|--------|
| `/api/pair` | POST | Exchange pairing code for client_id | ✅ Complete |
| `/api/ingest/workouts` | POST | Send workout data | ✅ Complete |
| `/api/ingest/profile` | POST | Send height/weight metrics | ✅ Complete |
| `/api/ingest/steps` | POST | Send daily step counts | ✅ Complete (Enhanced) |
| `/api/ingest/sleep` | POST | Send sleep records with stages | ✅ Complete (Enhanced) |

### Background Sync Mechanism

When network failures occur or the app is backgrounded:

1. **Sync Failure** → Operation added to SyncQueue (Core Data persistence)
2. **iOS Background Period** → BackgroundSyncTask automatically processes queue when device is idle + connected
3. **Exponential Backoff** → Retries with increasing delays: 2s, 4s, 8s, 16s, 32s (max 5 retries)
4. **Auto-Cleanup** → Successful syncs removed from queue; permanent failures marked for manual review

### Remaining Integration Work

**Not yet implemented (for next session):**
- [ ] Wire SyncQueue into BackendSyncStore error handlers
- [ ] Register BackgroundSyncTask in AppDelegate lifecycle
- [ ] E2E testing with network failure scenarios

## Identity Model: Pairing Codes

GymDashSync uses a **pairing code** system for multi-user identity:

- **No Apple Sign-In**: The app does not use Apple ID or any authentication
- **Pairing Codes**: Users enter a short code (6-8 characters) provided by their coach
- **Client ID**: The pairing code is exchanged for a backend-issued `client_id` (UUID)
- **Ownership**: All HealthKit data is tagged with `client_id` - ownership is determined entirely by this identifier
- **One-Time Setup**: Pairing happens once per device, then the `client_id` is persisted locally

**Why Pairing Codes Instead of Apple Sign-In?**

This is a developer-first system designed for iterative development. Pairing codes provide:
- Simple identity bootstrap without OAuth complexity
- Easy testing and development
- Clear path to migrate to Apple Sign-In later (same data schema, same `client_id` model)
- No cloud dependencies during development

The pairing logic is isolated from the sync pipeline and database schema, making it easy to replace with Apple Sign-In or other authentication methods later.

## Project Goal

GymDashSync is a headless sync client that:
- Requests HealthKit permissions (read-only)
- Reads specific HealthKit data types
- Incrementally syncs that data to a configurable backend endpoint
- Shows only connection and sync status to the user

**This is NOT:**
- A fitness tracking app
- A visual dashboard
- A workout analysis tool
- A health monitoring application

## Platform Scope

### Current (V1)
- **iOS only** - Apple Health / HealthKit integration

### Future (Placeholders Only)
- Android (Google Fit ingestion) - *not implemented*
- Shared backend payload schema - *documented but not implemented*

## Data Collection (Current Scope)

GymDashSync collects the following HealthKit data **to sync with CoachFit**:

### Workouts
- Workout type (running, walking, cycling, strength, HIIT, other)
- Start time and end time
- Duration
- Active energy burned (calories)
- Distance (walking/running, cycling)
- Heart rate (summary only, if available)

### Steps
- Daily step count aggregations (365-day history)
- Source devices (iPhone, Apple Watch, etc.)

### Sleep
- Daily sleep records with stage breakdown:
  - Total sleep minutes
  - In bed minutes
  - Awake minutes
  - Light sleep (core) minutes
  - Deep sleep minutes
  - REM sleep minutes
  - Sleep start/end timestamps
- Source devices
- **Stored in CoachFit as:** Detailed SleepRecord model + daily Entry summary

### Profile / Body Metrics
- Height
- Body mass (weight)
- Body fat percentage (if available)

### Explicitly NOT Collected
- ❌ VO2 max
- ❌ HRV (Heart Rate Variability)
- ❌ Recovery metrics
- ❌ Medical data
- ❌ Any write permissions to HealthKit

**Read-only access only.**

## Permissions UX

Health permissions are requested in two logical steps:

1. **Workout data** - Requests permission for workout types and related metrics
2. **Profile / body measurements** - Requests permission for height, weight, and body fat

Permission copy explains:
- Data is read-only
- Data is synced to a coach-managed system
- No medical or recovery claims

## UI Requirements

The UI is intentionally minimal:

### Main Screen
- Connection status (authorized / not authorized)
- Last successful sync timestamp
- "Sync now" button
- Permission request buttons (if not authorized)

### Debug Screen (Optional)
- Reset authorization
- View enabled data types
- Backend configuration status
- Dev mode toggle
- Error history viewer
- Clear error history

## Development Mode

GymDashSync includes a **verbose development mode** that makes failures obvious and debuggable without requiring Xcode logs.

### Dev Mode Features

When `DevMode.isEnabled == true` (default during development):

- **Structured Error Display**: All errors are mapped to `AppError` with categories (pairing, healthkit, network, backend, validation, unknown)
- **Detailed Error Messages**: Shows HTTP status codes, endpoint URLs, response bodies, and technical details
- **Sync Diagnostics Panel**: Collapsible section showing:
  - Last request endpoint and status code
  - Request duration
  - Record counts (received, inserted, duplicates skipped, warnings, errors)
  - Validation error details
  - Full technical diagnostics
- **Error History**: Maintains a rolling list of last 10 errors with full details
- **HealthKit Error Surfacing**: Explicitly shows permission denials, partial permissions, and HealthKit unavailability
- **Pairing Error Details**: Shows HTTP status, endpoint, and response body for pairing failures
- **Sync Result Tracking**: Tracks detailed sync results with counts and validation errors

### Disabling Dev Mode for Production

To reduce verbosity for production builds:

1. **Runtime Toggle**: Use the Debug menu to toggle dev mode on/off
2. **Code Change**: Set `DevMode.isEnabled = false` in `DevMode.swift`
3. **UserDefaults**: Dev mode state persists in `UserDefaults` under `GymDashSync.DevMode`

When dev mode is disabled:
- Shows short, friendly error messages only
- Hides technical details (status codes, endpoints, response bodies)
- Hides diagnostics panel
- Hides error history viewer
- Minimal error information

### Error Model

All failures are mapped into structured `AppError` objects with:

- **ID**: UUID for tracking
- **Category**: pairing, healthkit, network, backend, validation, unknown
- **Message**: Short, human-readable message
- **Detail**: Optional verbose technical detail
- **Timestamp**: When the error occurred
- **Context**: Optional endpoint, status code, response body, HealthKit error codes

### Error History

The app maintains an in-memory rolling list of the last 10 errors. Access via:
- "Errors" button in navigation bar (dev mode only)
- Error history viewer shows all errors with full details
- Errors are also logged to console for Xcode debugging

### Logging Alignment

- What is shown on-screen matches what is logged to console
- Error IDs are consistent between UI and logs
- All errors are automatically added to error history

### What's NOT Included
- ❌ Charts
- ❌ Workout lists
- ❌ Graphs
- ❌ Progress visuals
- ❌ Any fitness tracking UI

## Sync Behavior

GymDashSync syncs data to CoachFit using incremental sync patterns from the Microsoft Health Data Sync library:
- **Anchored queries** - Only fetches new or updated records from HealthKit
- **Last-sync tracking** - Maintains state between syncs
- **Incremental updates** - Only sends changed data to CoachFit

### Sync Triggers
- Manual "Sync now" button in the app
- Automatic sync when app becomes active (foreground)
- Background sync via iOS 13+ BGProcessingTask (when device is idle + connected)

### Sync Failure Handling
- Failed syncs are queued locally via SyncQueue
- Exponential backoff retry: 2s → 4s → 8s → 16s → 32s (max 5 attempts)
- Automatic retry during background sync periods
- Manual retry option via app settings (when fully integrated)

## Backend Expectations

GymDashSync **requires the CoachFit backend** to function. It relies on:

### Authentication
- **Pairing Code Exchange** - 6-digit pairing codes are exchanged for a client_id (UUID) via `/api/pair`
- **Bearer Token** - Subsequent API calls use the client_id as authentication
- **Ownership Model** - All data is tagged with client_id; backend uses this for ownership verification

### Payload Format

#### Step Data Payload
```json
{
  "client_id": "uuid",
  "steps": [
    {
      "date": "2026-01-15",
      "total_steps": 12543,
      "source_devices": ["iPhone 15 Pro", "Apple Watch"]
    }
  ]
}
```

#### Sleep Data Payload
```json
{
  "client_id": "uuid",
  "sleep_records": [
    {
      "date": "2026-01-15",
      "total_sleep_minutes": 450,
      "in_bed_minutes": 480,
      "awake_minutes": 30,
      "asleep_core_minutes": 180,
      "asleep_deep_minutes": 90,
      "asleep_rem_minutes": 60,
      "sleep_start": "2026-01-15T23:15:00Z",
      "sleep_end": "2026-01-16T07:30:00Z",
      "source_devices": ["Apple Watch"]
    }
  ]
}
```

#### Workout Payload
```json
{
  "client_id": "uuid",
  "workouts": [
    {
      "workout_type": "Running",
      "start_time": "2026-01-15T10:00:00Z",
      "end_time": "2026-01-15T10:30:00Z",
      "duration_seconds": 1800,
      "calories_active": 200,
      "distance_meters": 5000,
      "avg_heart_rate": 150,
      "source_device": "Apple Watch"
    }
  ]
}
```

#### Profile Metrics Payload
```json
{
  "client_id": "uuid",
  "metrics": [
    {
      "metric": "weight",
      "value": 75.5,
      "unit": "kg",
      "measured_at": "2026-01-15T07:00:00Z"
    }
  ]
}
```

## Architecture

### CoachFit Dependency

GymDashSync is **entirely dependent on the CoachFit platform**:

```
GymDashSync (iOS App)
    ↓
    Syncs HealthKit data via HTTPS
    ↓
CoachFit Backend (/api/ingest/*)
    ↓
    Stores in PostgreSQL database
    ↓
CoachFit Web Dashboard
    ↓
    Coaches view/override client data
```

**Without CoachFit:**
- No pairing mechanism (backend generates codes)
- No data persistence (no backend to sync to)
- No way to view or analyze data (no dashboard)
- App cannot function

### HealthKit Best Practices (Validated)

This app follows Apple's HealthKit best practices and architectural principles:

#### ✅ Confirmed Architectural Decisions

1. **HealthKit as Data Source Only**
   - HealthKit is used exclusively to read health data
   - No identity, no user management, no authentication from HealthKit
   - All data is tagged with `client_id` from pairing (UserDefaults), not from HealthKit

2. **Identity Separate from HealthKit**
   - Identity is managed via pairing codes → `client_id` (UUID) stored in UserDefaults
   - Pairing happens BEFORE HealthKit access (see `App.swift`)
   - Backend owns identity; HealthKit owns data

3. **client_id as Sole Ownership Key**
   - Every record sent to backend includes `client_id`
   - Backend uses `client_id` for ownership, isolation, and deduplication
   - HealthKit data is never used to infer ownership

4. **Permissions Requested After Pairing**
   - App flow: Pairing → HealthKit Permissions → Sync
   - `PairingView` shown if no `client_id` exists
   - Permission buttons appear only after pairing completes

5. **Missing/Partial Data Expected and Tolerated**
   - Returns `nil` if `client_id` missing (expected - pairing required)
   - Handles partial authorization (user may grant some types, deny others)
   - Optional fields (calories, distance, heart rate) are nullable
   - Backend accepts partial records

6. **Replayed Data Expected**
   - Backend deduplicates workouts by `client_id` + `start_time` ±120s + `duration_seconds` ±10%
   - HDS framework uses anchor queries for incremental sync
   - Re-running queries may return same data (expected, handled by backend)

#### HealthKit Constraints (Apple Documentation)

These constraints are correctly handled:

- ✅ **HealthKit is NOT an identity provider** - We use pairing codes
- ✅ **Data is user-controlled** - We request read-only permissions
- ✅ **Partial/missing data expected** - Backend handles optional fields
- ✅ **Queries may return overlapping samples** - Backend deduplicates
- ✅ **Characteristic data is read-only** - We only read, never write
- ✅ **Simulator limitations** - Surfaces warnings in dev mode

#### Why Pairing Codes Instead of Apple Sign-In?

This is a developer-first system designed for iterative development:

- **Simple identity bootstrap** - No OAuth complexity during development
- **Easy testing** - Pairing codes can be generated and shared easily
- **Clear migration path** - Same data schema, same `client_id` model works with Apple Sign-In later
- **No cloud dependencies** - Works entirely locally during development
- **Isolated from sync pipeline** - Pairing logic is separate from data sync

The pairing logic is isolated from the sync pipeline and database schema, making it easy to replace with Apple Sign-In or other authentication methods later.

#### Why Deduplication Exists

HealthKit queries may return overlapping or repeated samples:
- Re-running queries may return the same data
- Anchor queries may replay data if anchor is lost
- Multiple devices (iPhone + Apple Watch) may create duplicate entries

Backend deduplication ensures data integrity without requiring complex client-side logic.

#### Why Verbose Error UI in Development

During development, failures must be obvious and debuggable:
- HealthKit errors are often silent or unclear
- Network failures need detailed diagnostics
- Backend validation errors must be visible
- Simulator limitations must be explained

Production builds can disable dev mode for user-friendly messages.

#### Expected HealthKit Limitations (Not Bugs)

These are expected behaviors, not bugs:

- **Simulator limitations** - HealthKit is not fully available on iOS Simulator
- **Partial authorization** - User may grant some types, deny others
- **Permission persistence** - Permissions may be revoked by user at any time
- **Missing data** - User may not have all data types (e.g., no body fat measurements)
- **Replayed queries** - Re-running queries may return same data (backend deduplicates)

### Foundation Library
This project uses the [Microsoft Health Data Sync](https://github.com/microsoft/health-data-sync) library as its foundation. The library is vendored locally in the `HealthDataSync/` directory.

### Project Structure
```
GymDashSync/
├── HealthDataSync/              # Vendored Microsoft Health Data Sync library
│   ├── Sources/                 # Library source files
│   └── Package.swift            # SPM package definition
│
├── GymDashSync/
│   ├── GymDashSync.swift        # SwiftUI app entry point
│   ├── SyncManager.swift        # HealthKit data collection orchestration
│   │                            # - requestStepPermissions() / requestSleepPermissions()
│   │                            # - collectAndSyncSteps() / collectAndSyncSleep()
│   │                            # - Integration with syncNow() pipeline
│   │
│   ├── BackendSyncStore.swift   # CoachFit API client
│   │                            # - syncSteps() → POST /api/ingest/steps
│   │                            # - syncSleep() → POST /api/ingest/sleep
│   │                            # - syncWorkouts() → POST /api/ingest/workouts
│   │                            # - syncProfileMetrics() → POST /api/ingest/profile
│   │
│   ├── SyncQueue.swift          # Core Data-backed persistent sync queue [NEW]
│   │                            # - enqueue() / getPendingOperations()
│   │                            # - markSuccess() / markFailure()
│   │                            # - getStats() / clearCompleted()
│   │                            # - Exponential backoff retry logic
│   │
│   ├── BackgroundSyncTask.swift # iOS 13+ background sync processor [NEW]
│   │                            # - registerBackgroundTask()
│   │                            # - scheduleBackgroundSync()
│   │                            # - handleBackgroundSync()
│   │
│   ├── Models/
│   │   ├── WorkoutData.swift           # Workout data model
│   │   ├── ProfileMetricData.swift     # Profile metrics data models
│   │   ├── StepData.swift              # Step aggregation model [NEW]
│   │   └── SleepData.swift             # Sleep aggregation model [NEW]
│   │
│   ├── UI/
│   │   ├── ContentView.swift           # Main UI
│   │   ├── SyncViewModel.swift         # UI state management
│   │   └── ...                         # Other UI components
│   │
│   └── Resources/
│       ├── Info.plist                  # App configuration
│       └── GymDashSyncQueue.xcdatamodel  # Core Data model [NEW]
│
├── .gitignore
├── README.md                    # This file
├── SETUP.md                     # Setup instructions
└── docs/
    ├── COACHFIT_INTEGRATION_PLAN.md
    └── IMPLEMENTATION_LOG.md
```

## Setup

### Prerequisites
- Xcode 14.0 or later
- iOS 13.0 or later target
- Swift 5.5 or later
- Access to CoachFit backend (required to use app)

### Requirements for Development
- Xcode 12.0 or later
- iOS 13.0 or later
- Swift 5.0 or later

### Pairing with CoachFit

To use GymDashSync, you must first obtain a **pairing code** from your coach via the CoachFit web dashboard:

1. Coach logs into CoachFit web app
2. Coach navigates to `/client-dashboard/pairing` (for clients) or `/coach-dashboard/pairing`
3. Coach generates a 6-digit pairing code
4. Coach shares the code with the client
5. Client enters code into GymDashSync on their iOS device
6. GymDashSync exchanges code for `client_id` and begins syncing

**Note:** GymDashSync cannot function without a valid pairing code. The code establishes the relationship between the iOS device and the client's CoachFit account.

### Building
1. Open the project in Xcode
2. Select the `GymDashSync` target
3. Build and run on a physical iOS device (HealthKit requires a device; simulator support is limited)

### Configuration
Backend configuration is auto-discovered from CoachFit:
- Backend URL is set to CoachFit backend endpoint
- Authentication uses client_id from pairing
- Endpoints are hardcoded for CoachFit compatibility

## Implementation Details

### Sync Logic & HealthKit Integration

The implementation uses the Health Data Sync framework's intended patterns:

1. **HealthKit Queries** - Anchored queries fetch only new/updated data
2. **Daily Aggregation** - Raw HealthKit samples are aggregated into daily summaries
3. **Backend Sync** - Daily summaries are sent to CoachFit via REST API
4. **Failure Handling** - Failed syncs are queued locally and retried with exponential backoff
5. **Background Processing** - iOS background tasks automatically retry failed syncs

### Step Collection (365-day history)
- Uses `HKStatisticsCollectionQuery` for efficient daily aggregation
- Queries 365 days of history on each sync
- Sends only changed/new daily summaries
- Syncs to CoachFit via `/api/ingest/steps`
- On failure: Operation queued with exponential backoff

### Sleep Collection (365-day history)
- Uses `HKSampleQuery` with manual daily grouping of sleep samples
- Queries 365 days of history on each sync
- Aggregates sleep stages (deep, light, REM, core, in_bed, awake)
- Syncs to CoachFit via `/api/ingest/sleep`
- Stored in CoachFit as both detailed SleepRecord + daily Entry summary
- On failure: Operation queued with exponential backoff

### Data Priority Logic

When syncing to CoachFit, the app respects the **manual > HealthKit** priority:

```
iOS sends: { client_id, steps: 12000, dataSources: ["healthkit"] }
       ↓
CoachFit backend checks:
  - Does Entry exist for this date with "manual" in dataSources?
  - If YES: Preserve manual value, add "healthkit" to dataSources
  - If NO: Store HealthKit value, mark as ["healthkit"] source
```

This ensures coaches can correct data without it being overwritten by HealthKit on the next sync.

### Graceful Degradation

If CoachFit backend endpoints are temporarily unavailable:
- Sync failure is captured and queued
- BackgroundSyncTask will retry up to 5 times with exponential backoff
- All data is preserved locally until successful transmission

## Development Notes

### What's Implemented
- ✅ Pairing code exchange with CoachFit backend
- ✅ HealthKit permission requests (two-step flow)
- ✅ Workout data collection and sync
- ✅ Profile metrics collection and sync
- ✅ **NEW:** Step collection (365-day history, daily aggregation)
- ✅ **NEW:** Sleep collection (365-day history with sleep stages)
- ✅ **NEW:** SyncQueue (Core Data, exponential backoff, 5 retries)
- ✅ **NEW:** BackgroundSyncTask (iOS 13+ BGProcessingTask)
- ✅ Incremental sync using anchored queries
- ✅ Minimal status UI (connection, sync button, error display)
- ✅ Two-step permission flow
- ✅ Read-only HealthKit access
- ✅ Verbose development mode with error diagnostics

### What's NOT Implemented (By Design)
- ❌ Android support (iOS only)
- ❌ Standalone functionality (requires CoachFit backend)
- ❌ Charts or visualizations
- ❌ Workout analysis features
- ❌ Social features
- ❌ Medical claims or recovery metrics
- ❌ **Pending:** Integration hooks (SyncQueue wiring, AppDelegate lifecycle)
- ❌ **Pending:** E2E testing with network failure scenarios

## Future Iterations

This project is designed for iterative development with the CoachFit platform:

### Phase 2: Integration Completion (Pending)
- [ ] Wire SyncQueue into BackendSyncStore error handlers
- [ ] Register BackgroundSyncTask in AppDelegate
- [ ] E2E testing with network failures
- [ ] Real device testing with background sync

### Phase 3: UI Enhancements (Optional)
- [ ] Display SyncQueue stats (pending/failed counts)
- [ ] Manual retry button for failed syncs
- [ ] Retry timing display
- [ ] Local notifications for sync completion

### Phase 4: Advanced Features (Deferred)
- [ ] Configurable sync intervals
- [ ] Selective data collection (user can disable steps/sleep/workouts)
- [ ] Data usage analytics
- [ ] Coach-side data validation UI

## Dependencies

### Required
- **CoachFit Backend** - App is entirely dependent on CoachFit for pairing, API endpoints, and data storage
- **Apple HealthKit** - iOS 13+ required for HealthKit access
- **Microsoft Health Data Sync** - Vendored library for HealthKit query and incremental sync patterns

### Optional
- **None** - App has no external dependencies beyond iOS system frameworks

## Support & Issues

GymDashSync is part of the **CoachFit** suite of tools. For issues, features, or questions:

1. **Integration Issues** - See [GymDashSync GitHub Issue #1](https://github.com/adamswbrown/GymDashSync/issues/1)
2. **Backend Issues** - See [CoachFit GitHub Issue #3](https://github.com/adamswbrown/CoachFit/issues/3)
3. **Feature Requests** - Open an issue on the appropriate GitHub repo




