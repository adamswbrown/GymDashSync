# iOS App V2 Setup Guide

This guide covers creating a new iOS app target (e.g., "PulseRelay") by duplicating the existing GymDashSync target in the same Xcode project.

## Overview

Instead of creating a separate Xcode project, we duplicate the target within the same project. This allows:
- Sharing source files between targets (no duplication)
- Same HealthDataSync framework reference
- Easier maintenance and sync during development

## Prerequisites

- Xcode 14.0 or later
- Existing `GymDashSync.xcodeproj` project

## Step 1: Duplicate Target in Xcode

1. Open `GymDashSync/GymDashSync.xcodeproj` in Xcode
2. In Project Navigator, select the "GymDashSync" target
3. Right-click on the target → Select "Duplicate"
   - Alternatively: Product → Scheme → Manage Schemes → Select "GymDashSync" scheme → Edit → Duplicate
4. Xcode creates a new target with "-copy" suffix (e.g., "GymDashSync-copy")
5. Rename the duplicated target:
   - Select the new target in Project Navigator
   - Click the target name (should be editable)
   - Rename to "PulseRelay" (or your desired name)

## Step 2: Configure Build Settings

1. Select the "PulseRelay" target in Project Navigator
2. Go to Build Settings (ensure "All" and "Combined" are selected)
3. Update the following settings:

### Product Name
- Search for "Product Name"
- Set value to: `PulseRelay` (or your desired name)

### Bundle Identifier
- Search for "Product Bundle Identifier"
- Set value to: `com.askadam.PulseRelay` (or your custom domain/name)

### Info.plist Settings
- Search for "Info.plist Values" → Expand
- Set `PRODUCT_BUNDLE_IDENTIFIER` to: `com.askadam.PulseRelay`
- Set `PRODUCT_NAME` to: `PulseRelay`

## Step 3: Configure Info.plist

If Xcode duplicated the Info.plist file:

1. Find the duplicated Info.plist (may be named `PulseRelay-Info.plist` or similar)
2. Update the following keys:
   - `CFBundleIdentifier`: `com.askadam.PulseRelay`
   - `CFBundleName`: `PulseRelay`
   - `CFBundleDisplayName`: `PulseRelay` (or your display name)

**OR** if Info.plist is shared:
- Use build setting variables: `$(PRODUCT_BUNDLE_IDENTIFIER)` and `$(PRODUCT_NAME)`
- Xcode will automatically substitute values based on target

## Step 4: Duplicate Entitlements File

1. In Project Navigator, find `GymDashSync.entitlements`
2. Right-click → "Duplicate"
3. Rename to `PulseRelay.entitlements`
4. Select the "PulseRelay" target
5. Go to Build Settings
6. Search for "Code Signing Entitlements"
7. Set value to: `PulseRelay/PulseRelay.entitlements` (or path to your entitlements file)
8. Verify all HealthKit permissions are present (same as GymDashSync)

## Step 5: Configure Source File Membership

Most source files should be shared between targets:

### Shared Files (Both Targets)
- `SyncManager.swift`
- `BackendSyncStore.swift`
- `WorkoutData.swift`
- `ProfileMetricData.swift`
- `SyncViewModel.swift`
- `SyncResult.swift`
- `AppError.swift`
- `ErrorHistory.swift`
- `DevMode.swift`
- `PairingView.swift`
- `OnboardingView.swift`
- `AppDelegate.swift`
- `ContentView.swift`

To verify/update membership:
1. Select a file in Project Navigator
2. Open File Inspector (right panel)
3. Check "Target Membership" section
4. Ensure both "GymDashSync" and "PulseRelay" are checked

### App.swift Handling

You have two options:

#### Option A: Separate App.swift Files (Recommended)

1. Create `GymDashSync/PulseRelay/App.swift` (new file)
2. Copy content from `GymDashSync/GymDashSync/App.swift`
3. Update `struct GymDashSyncApp` to `struct PulseRelayApp`
4. Set target membership:
   - `GymDashSync/GymDashSync/App.swift` → Only "GymDashSync" target
   - `GymDashSync/PulseRelay/App.swift` → Only "PulseRelay" target

#### Option B: Single File with Conditionals

Use compiler conditionals in a single `App.swift`:

```swift
#if TARGET_PulseRelay
@main
struct PulseRelayApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
#else
@main
struct GymDashSyncApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
#endif
```

## Step 6: Create Build Scheme

1. Product → Scheme → Manage Schemes
2. Click "+" to add new scheme
3. Name it "PulseRelay"
4. Select "PulseRelay" target from dropdown
5. Click "OK"

Alternatively, if Xcode auto-created a scheme when duplicating:
1. Find the scheme with "-copy" suffix
2. Edit the scheme name to "PulseRelay"

## Step 7: Configure Backend URL

The `BackendSyncStore.swift` uses UserDefaults key `GymDashSync.BackendURL`:

1. For Railway deployment, update the default URL in `BackendConfig.default`
2. Or configure via UserDefaults in the app
3. Both targets can use the same backend URL (recommended)

Example update in `BackendSyncStore.swift`:
```swift
static let default = BackendConfig(
    baseURL: UserDefaults.standard.string(forKey: "GymDashSync.BackendURL") ?? 
             "https://your-app.railway.app"
)
```

## Step 8: Verify Build

1. Select "PulseRelay" scheme from scheme dropdown (top toolbar)
2. Select a simulator or device
3. Product → Build (⌘B)
4. Verify build succeeds without errors
5. Product → Run (⌘R) to test the app

## Step 9: Test Both Apps Side-by-Side

You can now run both apps:

1. Build and run "GymDashSync" target
2. Stop the app
3. Switch to "PulseRelay" scheme
4. Build and run "PulseRelay" target

Both apps should work independently with:
- Different bundle identifiers
- Same shared source code
- Same backend (if configured)

## Troubleshooting

### Build Errors

**Issue:** "No such module 'HealthDataSync'"

**Solution:**
- Verify HealthDataSync framework is linked to both targets
- Select target → Build Phases → Link Binary With Libraries
- Ensure HealthDataSync.framework is present for both targets

**Issue:** "Duplicate symbol" errors

**Solution:**
- Check that source files are not added twice to the project
- Verify target membership (file should be in both targets, not duplicated)

**Issue:** "Bundle identifier already in use"

**Solution:**
- Ensure unique bundle identifier for PulseRelay target
- Check Build Settings → Product Bundle Identifier

### Runtime Issues

**Issue:** App crashes on launch

**Solution:**
- Verify `App.swift` is properly configured for the target
- Check that `@main` attribute is present
- Ensure only one `@main` struct per target

**Issue:** HealthKit permissions not working

**Solution:**
- Verify `PulseRelay.entitlements` is configured correctly
- Check that entitlements file is set in Build Settings
- Ensure all HealthKit read permissions are present

## Notes

- UserDefaults keys remain `GymDashSync.*` for compatibility (both targets can share backend)
- Pairing codes work the same for both apps
- HealthKit permissions are requested independently per app (separate bundle IDs)
- Backend treats both apps as separate clients (different bundle IDs)

## Next Steps

- See `docs/railway-deployment.md` for backend deployment
- See `README.md` for overall project architecture

