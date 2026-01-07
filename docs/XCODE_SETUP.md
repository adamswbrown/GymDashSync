# Xcode Project Setup Guide

This guide walks you through creating the Xcode project for the GymDashSync iOS app.

## Quick Start

**In Xcode, you need to:**

1. **Create a new iOS App project** in the `/Users/adambrown/Developer/GymDashSync` directory
2. **Add the source files** from `GymDashSyncApp/Sources/`
3. **Add HealthDataSync as a local package**
4. **Configure HealthKit capability**
5. **Set the backend URL** (already defaults to `http://localhost:3001`)

## Step-by-Step Instructions

### Step 1: Create New Xcode Project

1. **In Xcode**: File → New → Project (or press `⌘⇧N`)

2. **Select template**: 
   - Choose **iOS** tab
   - Select **App**
   - Click **Next**

3. **Configure project**:
   - **Product Name**: `GymDashSync`
   - **Team**: Select your development team (or "None" for now)
   - **Organization Identifier**: `com.gymdashsync` (or your own)
   - **Bundle Identifier**: Will auto-fill as `com.gymdashsync.GymDashSync`
   - **Interface**: **SwiftUI**
   - **Language**: **Swift**
   - **Storage**: None (we'll add files manually)
   - **Include Tests**: Optional (uncheck if you want)

4. **Save location**:
   - Navigate to `/Users/adambrown/Developer/GymDashSync`
   - **Important**: Save the project **inside** the GymDashSync directory
   - Click **Create**

### Step 2: Delete Default Files

Xcode created some default files. Delete them:

1. In the Project Navigator, find and **delete**:
   - `ContentView.swift` (we have our own)
   - `GymDashSyncApp.swift` (we have `App.swift` instead)
   - Any default assets or preview files

2. Right-click → Delete → Move to Trash

### Step 3: Add App Source Files

1. **In Xcode Project Navigator**, right-click on the `GymDashSync` folder (or your project root)

2. **Select**: "Add Files to GymDashSync..."

3. **Navigate to**: `/Users/adambrown/Developer/GymDashSync/GymDashSyncApp/Sources/`

4. **Select all files** in that directory:
   - `App.swift`
   - `AppDelegate.swift`
   - `AppError.swift`
   - `BackendSyncStore.swift`
   - `ContentView.swift`
   - `DevMode.swift`
   - `ErrorHistory.swift`
   - `PairingView.swift`
   - `ProfileMetricData.swift`
   - `SyncManager.swift`
   - `SyncResult.swift`
   - `SyncViewModel.swift`
   - `WorkoutData.swift`

5. **Options**:
   - ✅ **Copy items if needed** (checked)
   - ✅ **Create groups** (selected)
   - ✅ **Add to targets**: `GymDashSync` (checked)

6. Click **Add**

### Step 4: Add Info.plist

1. **Right-click** on your project in the navigator
2. **Select**: "Add Files to GymDashSync..."
3. **Navigate to**: `/Users/adambrown/Developer/GymDashSync/GymDashSyncApp/Resources/`
4. **Select**: `Info.plist`
5. **Options**:
   - ✅ **Copy items if needed** (checked)
   - ✅ **Add to targets**: `GymDashSync` (checked)
6. Click **Add**

7. **Configure Info.plist in project**:
   - Select your target (`GymDashSync`)
   - Go to **Build Settings** tab
   - Search for "Info.plist"
   - Set **Info.plist File** to: `GymDashSyncApp/Resources/Info.plist` (or the path relative to your project)

### Step 5: Add HealthDataSync as Local Package

1. **In Xcode**: File → Add Packages... (or press `⌘⇧⌘`)

2. **Click**: "Add Local..."

3. **Navigate to**: `/Users/adambrown/Developer/GymDashSync/HealthDataSync/`

4. **Select the `HealthDataSync` folder** and click **Add Package**

5. **In the package dialog**:
   - Select the `HealthDataSync` library
   - Add it to your `GymDashSync` target
   - Click **Add Package**

### Step 6: Configure HealthKit Capability

1. **Select your project** in the Project Navigator (top-level "GymDashSync")

2. **Select the `GymDashSync` target**

3. **Go to**: **Signing & Capabilities** tab

4. **Click**: **+ Capability**

5. **Add**: **HealthKit**

6. **Verify**:
   - HealthKit capability appears
   - "HealthKit" is listed in capabilities

### Step 7: Configure Backend URL (Already Done!)

The backend URL is already configured to default to `http://localhost:3001` in `BackendSyncStore.swift`.

**For iOS Simulator**: `http://localhost:3001` works perfectly.

**For real device**: You'll need to use your Mac's IP address (e.g., `http://192.168.1.100:3001`). You can change this later in the Debug menu.

### Step 8: Build Settings

1. **Select your target** → **Build Settings**

2. **Verify**:
   - **iOS Deployment Target**: 13.0 or later
   - **Swift Language Version**: Swift 5

3. **If needed, set**:
   - **Product Bundle Identifier**: `com.gymdashsync.GymDashSync` (or your own)

### Step 9: Build and Run

1. **Select a simulator** (e.g., iPhone 15) from the device selector

2. **Build**: Press `⌘B` or Product → Build

3. **Fix any errors**:
   - Missing imports
   - File not found errors
   - Any build issues

4. **Run**: Press `⌘R` or Product → Run

## Verification Checklist

After setup, verify:

- ✅ Project builds without errors
- ✅ All source files are in the project
- ✅ HealthDataSync package is linked
- ✅ HealthKit capability is added
- ✅ Info.plist is included with HealthKit usage descriptions
- ✅ Backend URL defaults to `http://localhost:3001`

## Troubleshooting

### "No such module 'HealthDataSync'"
- Ensure HealthDataSync is added as a package dependency
- Clean build folder: Product → Clean Build Folder (`⌘⇧K`)
- Rebuild: Product → Build (`⌘B`)

### "Cannot find 'App' in scope"
- Ensure `App.swift` is added to the target
- Check that `@main` attribute is on the `GymDashSyncApp` struct

### HealthKit errors
- Verify HealthKit capability is added
- Check Info.plist has HealthKit usage descriptions
- Note: HealthKit requires a real device for full functionality (simulator has limited support)

### Backend connection errors
- Verify backend is running on port 3001
- For simulator: `http://localhost:3001` works
- For real device: Use your Mac's IP address

## Next Steps

Once the project is set up:

1. **Build and run** in the simulator
2. **Pair the app** using one of the pairing codes from the coach UI:
   - `U9DBAJ` (Browser Test Client - has test data)
   - `KXHS5Q` (Test Client)
3. **Grant HealthKit permissions**
4. **Trigger a sync** and verify data appears in the coach UI

