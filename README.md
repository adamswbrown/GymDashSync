# GymDashSync

A lightweight iOS companion app that reads Apple Health (HealthKit) data and syncs it to a backend API. This is **not** a fitness app or visual dashboard—it's a minimal sync client focused solely on data synchronization.

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

## Data Collection (Locked Scope)

GymDashSync collects **ONLY** the following HealthKit data:

### Workouts
- Workout type (running, walking, cycling, strength, HIIT, other)
- Start time and end time
- Duration
- Activity type
- Active energy burned (calories)
- Distance (walking/running, cycling)
- Heart rate (summary only, if available)

### Profile / Body Metrics
- Height
- Body mass (weight)
- Body fat percentage (if available)

### Explicitly NOT Collected
- ❌ VO2 max
- ❌ HRV (Heart Rate Variability)
- ❌ Sleep data
- ❌ Recovery metrics
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

Uses incremental sync patterns from the Microsoft Health Data Sync library:
- **Anchored queries** - Only fetches new or updated records
- **Last-sync tracking** - Maintains state between syncs
- **Incremental updates** - Only sends changed data

### Sync Triggers
- Manual "Sync now" button
- App foreground (when app becomes active)
- Background refresh (where supported by iOS)

## Backend Expectations

**Note:** No backend exists yet. The app is designed to work with a configurable endpoint.

### Configuration
- Backend URL is configurable (defaults to placeholder)
- Authentication uses Bearer token (placeholder for now)
- Endpoints are configurable via `BackendConfig`

### Payload Format

#### Workout Payload
```json
{
  "client_id": "uuid",
  "source": "apple_health",
  "workout_type": "run | walk | cycle | strength | hiit | other",
  "start_time": "ISO8601",
  "end_time": "ISO8601",
  "duration_seconds": 3600,
  "calories_active": 500.0,
  "distance_meters": 5000.0,
  "avg_heart_rate": 150.0,
  "source_device": "apple_watch | iphone"
}
```

#### Profile Metric Payload
```json
{
  "client_id": "uuid",
  "metric": "height | weight | body_fat",
  "value": 175.0,
  "unit": "cm | kg | percent",
  "measured_at": "ISO8601",
  "source": "apple_health"
}
```

### Endpoints

**Workouts:**
- `POST /api/v1/workouts` - Create new workouts
- `PUT /api/v1/workouts` - Update existing workouts (falls back to POST if not supported)
- `POST /api/v1/workouts/query` - Query existing workouts by UUID (optional, graceful degradation)

**Profile Metrics:**
- `POST /api/v1/profile-metrics` - Create new profile metrics
- `PUT /api/v1/profile-metrics` - Update existing profile metrics (falls back to POST if not supported)
- `POST /api/v1/profile-metrics/query` - Query existing metrics by UUID (optional, graceful degradation)

**Note:** The query endpoints are optional. If they don't exist or return 404, the sync will gracefully degrade to always creating new records (previous behavior). This allows the app to work with backends that haven't implemented the query endpoints yet.

## Architecture

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
├── HealthDataSync/          # Vendored Microsoft Health Data Sync library
│   ├── Sources/             # Library source files
│   └── Package.swift        # SPM package definition
├── GymDashSyncApp/
│   ├── Sources/
│   │   ├── WorkoutData.swift           # Workout data model
│   │   ├── ProfileMetricData.swift     # Profile metrics data models
│   │   ├── BackendSyncStore.swift      # Backend sync implementation
│   │   ├── SyncManager.swift           # Sync orchestration
│   │   ├── ContentView.swift           # Main UI
│   │   ├── SyncViewModel.swift         # UI state management
│   │   ├── App.swift                   # SwiftUI app entry point
│   │   └── AppDelegate.swift           # App lifecycle
│   └── Resources/
│       └── Info.plist                  # App configuration
├── Package.swift            # Root SPM package (optional)
├── .gitignore              # Git ignore rules
├── README.md               # This file
├── SETUP.md                # Setup instructions
└── temp_repo/              # Original Microsoft repo (can be removed)
```

## Setup

### Requirements
- Xcode 12.0 or later
- iOS 13.0 or later
- Swift 5.0 or later

### Building
1. Open the project in Xcode
2. Configure the backend URL in `BackendConfig` (or via UserDefaults)
3. Build and run on a device (HealthKit requires a physical device)

### Backend Configuration
Backend configuration is stored in `UserDefaults`:
- `GymDashSync.BackendURL` - Backend base URL
- `GymDashSync.APIKey` - Optional API key for authentication

## Implementation Details

### Sync Logic Improvements

The implementation now properly uses the Health Data Sync framework's intended patterns:

1. **fetchObjects()** - Queries the backend to check which objects already exist by UUID. This allows the framework to:
   - Call `update()` for existing objects
   - Call `add()` for new objects
   - Properly handle HealthKit data changes

2. **Update Methods** - Data models implement `update(with:)` to handle changes from HealthKit. The framework automatically:
   - Fetches existing objects from backend
   - Compares UUIDs to determine updates vs creates
   - Calls appropriate methods (update vs add)

3. **Graceful Degradation** - If the backend doesn't support query endpoints yet:
   - `fetchObjects()` returns empty array (all treated as new)
   - Sync continues to work (previous behavior)
   - No breaking changes for existing backends

4. **HTTP Methods** - Uses proper REST semantics:
   - `POST` for creating new records
   - `PUT` for updating existing records
   - Falls back to POST if PUT not supported (405 error)

## Development Notes

### What Was Done
- ✅ Stripped down Microsoft Health Data Sync to core sync functionality
- ✅ Implemented workout data collection
- ✅ Implemented profile metrics collection (height, weight, body fat)
- ✅ Created minimal UI for sync status
- ✅ Two-step permission flow
- ✅ Incremental sync using anchored queries
- ✅ Configurable backend endpoint
- ✅ Read-only HealthKit access
- ✅ **Proper fetchObjects() implementation** - Queries backend to check existing records
- ✅ **Update vs Add separation** - Framework properly distinguishes creates from updates
- ✅ **PUT endpoints for updates** - Uses PUT for updates, POST for creates (with graceful fallback)
- ✅ **Graceful degradation** - Works even if backend doesn't support query/update endpoints yet

### What Was NOT Done (By Design)
- ❌ Android implementation
- ❌ Backend service implementation
- ❌ Charts or visualizations
- ❌ Workout analysis features
- ❌ Medical claims or recovery metrics

## Future Iterations

This project is prepared for iterative development:
- Backend integration can be added when ready
- UI can be enhanced with branding
- Additional data types can be added (if needed)
- Android support can be added (placeholders exist)

## License

This project uses the Microsoft Health Data Sync library, which is licensed under the MIT License. See the `HealthDataSync/` directory for license details.

## Contributing

This is a private project. For questions or issues, please contact the project maintainer.


