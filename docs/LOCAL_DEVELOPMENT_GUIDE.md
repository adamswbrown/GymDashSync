# Local Development Guide

This guide walks you through running the entire GymDashSync system locally on your Mac. This is a **local-only development setup**—no Azure, no cloud services, no production assumptions. The goal is to prove the full pipeline works: iOS app → backend API → SQLite database → coach web UI.

## Prerequisites

Before starting, ensure you have the following installed:

- **macOS** (any recent version)
- **Node.js** (LTS version recommended)
  - Verify: `node -v` (should show v18.x or v20.x)
- **npm** (comes with Node.js)
  - Verify: `npm -v`
  - **Note**: If npm suggests updating (e.g., "New minor version of npm available!"), you can **safely ignore it**. The current version works fine for this guide. Updating npm is optional and not required.
- **Xcode** (latest stable version from the Mac App Store)
  - Verify: `xcode-select --version`
- **iOS Simulator** (included with Xcode)
- **Git** (usually pre-installed on macOS)
  - Verify: `git --version`

If any of these are missing, install them before proceeding.

## Repository Overview

The GymDashSync repository contains two main components:

### Backend
- **Location**: `backend/` directory
- **Technology**: Node.js + Express
- **Database**: SQLite (file-based, created automatically)
- **Features**:
  - HTTP API for data ingestion (`/api/v1/workouts`, `/api/v1/profile-metrics`)
  - Pairing endpoint (`/pair`)
  - Coach web UI (`/ui`)
  - Client management
  - Workout deduplication
  - Data validation

### iOS App
- **Location**: `GymDashSyncApp/` directory
- **Technology**: SwiftUI + HealthKit
- **Features**:
  - HealthKit data collection (workouts, profile metrics)
  - Pairing code authentication
  - Incremental sync to backend
  - Dev mode error diagnostics
  - Minimal UI focused on sync status

## Step 1: Start the Backend Locally

1. **Navigate to the backend directory**:
   ```bash
   cd backend
   ```

2. **Install dependencies**:
   ```bash
   npm install
   ```
   This installs Express, SQLite, and other required packages. You should see a `node_modules/` directory created.

   **Note**: npm may display a notice like "New minor version of npm available! 11.4.2 -> 11.7.0". **You can safely ignore this notice**—the current npm version works perfectly for this guide. The notice is informational only.

   **If you want to update npm anyway** (optional):
   - Use `sudo npm install -g npm@latest` (requires your Mac admin password)
   - Or better: use a node version manager like `nvm` which avoids permission issues
   - But again, **updating is not required**—your current npm version is fine.

3. **Start the server**:
   ```bash
   npm start
   ```
   Or directly:
   ```bash
   node server.js
   ```

4. **Verify the server started**:
   You should see output like:
   ```
   [SERVER] Starting GymDashSync backend...
   [DB] Database initialized: database.sqlite
   [SERVER] Server listening on http://localhost:3000
   [SERVER] API endpoints available at /api/v1/*
   [SERVER] Coach UI available at /ui
   ```

5. **Keep this terminal window open**—the server must remain running.

**Expected behavior**:
- Server listens on port 3000
- SQLite database file `database.sqlite` is created in the `backend/` directory
- All API routes are registered and ready

**Troubleshooting**:
- If port 3000 is in use, edit `server.js` and change the port number
- If you see database errors, ensure you have write permissions in the `backend/` directory
- If `npm install` shows permission errors, ensure you're running it in the project directory (not with `sudo`). Local dependencies don't require admin privileges
- **npm update notices**: If you see "New minor version of npm available!" after `npm install`, you can ignore it. Your current npm version works fine. If you really want to update, use `sudo npm install -g npm@latest`, but it's not necessary for this guide

## Step 2: Open the Coach Web UI

1. **Open your web browser** (Safari, Chrome, or Firefox)

2. **Navigate to**:
   ```
   http://localhost:3000/ui
   ```

3. **You should see**:
   - A list of clients (initially empty)
   - A "Create New Client" button
   - No login required (this is dev-only)

**What the Coach UI is for**:
- Creating clients and generating pairing codes
- Viewing client data (workouts, profile metrics)
- Inspecting data quality (warnings, errors)
- Managing multiple clients in a multi-user setup

**Note**: The UI is server-rendered HTML—no JavaScript framework. It's intentionally simple for development.

## Step 3: Create a Client & Pairing Code

1. **Click "Create New Client"** in the coach UI

2. **Fill in the form**:
   - **Label** (optional): A human-readable name like "Test User" or "John's iPhone"
   - Leave blank if you don't need a label

3. **Click "Create Client"**

4. **You'll see**:
   - A new client entry in the list
   - A **pairing code** (6-8 characters, e.g., "ABC123XY")
   - The `client_id` (UUID)

5. **Copy the pairing code**—you'll need it for the iOS app

**Important notes**:
- Pairing codes are **case-insensitive** (you can enter "abc123xy" or "ABC123XY")
- Pairing codes **do not expire** in dev mode
- Each pairing code maps to exactly one `client_id`
- **Do not reuse pairing codes across different people**—each device/user should have their own

**Alternative**: You can also create clients via the API:
```bash
curl -X POST http://localhost:3000/api/v1/clients \
  -H "Content-Type: application/json" \
  -d '{"label": "Test User"}'
```

## Step 4: Open the iOS App in Xcode

1. **Open Xcode** (from Applications or Spotlight)

2. **Open the project**:
   - File → Open
   - Navigate to the `GymDashSync` directory
   - Select `GymDashSync.code-workspace` (or the `.xcodeproj` if available)
   - Click "Open"

3. **Select the iOS Simulator**:
   - In the toolbar at the top, click the device selector (next to the play button)
   - Choose an iPhone simulator (e.g., "iPhone 15" or "iPhone 15 Pro")
   - **Do not select a real device yet**—simulator is easier for initial testing

4. **Build the project**:
   - Press `Cmd + B` or Product → Build
   - Wait for the build to complete (first build may take a minute)

**First-time iOS development notes**:
- Xcode may ask for permissions (keychain access, etc.)—grant them
- The simulator may take a moment to launch on first use
- If you see signing errors, go to Signing & Capabilities in the project settings and select your Apple ID team

**Simulator quirks**:
- HealthKit is **limited** in the simulator—you may not see real workout data
- The simulator can still test the sync pipeline, but you may need to manually add test data
- For full HealthKit testing, use a real device (covered later)

## Step 5: Configure the Backend Endpoint in the iOS App

The iOS app needs to know where your backend is running.

1. **Locate the backend configuration**:
   - In Xcode, open `GymDashSyncApp/Sources/BackendSyncStore.swift`
   - Find the `BackendConfig.default` property (around line 29-34)

2. **Current default**:
   ```swift
   public static var `default`: BackendConfig {
       let url = UserDefaults.standard.string(forKey: "GymDashSync.BackendURL") ?? "https://api.example.com"
       let key = UserDefaults.standard.string(forKey: "GymDashSync.APIKey")
       return BackendConfig(baseURL: url, apiKey: key)
   }
   ```

3. **Set the backend URL**:
   - The app checks `UserDefaults` for `GymDashSync.BackendURL`
   - For local development, you can either:
     - **Option A**: Set it in code temporarily:
       ```swift
       let url = UserDefaults.standard.string(forKey: "GymDashSync.BackendURL") ?? "http://localhost:3000"
       ```
     - **Option B**: Set it at runtime (requires adding a settings screen, or use the debug menu)

4. **For simulator testing**:
   - `localhost:3000` works in the iOS Simulator
   - The simulator shares the host machine's network, so `localhost` resolves correctly

5. **For real device testing** (later):
   - Replace `localhost` with your Mac's IP address (e.g., `http://192.168.1.100:3000`)
   - Find your Mac's IP: System Preferences → Network → Wi-Fi → Advanced → TCP/IP

**Note**: The backend URL is stored in `UserDefaults`, so it persists between app launches. You can change it later via the debug menu or by modifying the code.

## Step 6: Pair the iOS App

1. **Launch the app** in the simulator:
   - Press `Cmd + R` or click the Play button
   - The app will launch and show the **PairingView** (since no `client_id` is stored yet)

2. **Enter the pairing code**:
   - Type the pairing code you copied from the coach UI (e.g., "ABC123XY")
   - The code is case-insensitive

3. **Tap "Connect"**

4. **Success**:
   - The app transitions to the main `ContentView`
   - The `client_id` is stored locally in `UserDefaults`
   - You won't see the pairing screen again unless you reset pairing

**Common errors**:

- **"Invalid pairing code"**:
  - Check that the backend is running (`http://localhost:3000`)
  - Verify the pairing code matches exactly (case doesn't matter)
  - Check the backend terminal for error logs

- **"Connection error"**:
  - Ensure the backend URL is set to `http://localhost:3000`
  - Verify the backend server is running
  - Check that no firewall is blocking port 3000

- **"Invalid server URL"**:
  - The backend URL may be malformed
  - Ensure it starts with `http://` or `https://`

**Dev mode**: If dev mode is enabled, you'll see detailed error messages including HTTP status codes and response bodies, which helps debug pairing issues.

## Step 7: Grant HealthKit Permissions

After successful pairing, the app will request HealthKit permissions.

1. **Workout permissions**:
   - Tap "Authorize Workout Data"
   - iOS will show a HealthKit permission dialog
   - Tap "Allow" or "Turn All Categories On"
   - The app requests read access to:
     - Workouts
     - Active energy burned
     - Distance
     - Heart rate

2. **Profile permissions**:
   - Tap "Authorize Profile Metrics"
   - iOS will show another HealthKit permission dialog
   - Tap "Allow"
   - The app requests read access to:
     - Height
     - Body mass (weight)
     - Body fat percentage

3. **Verify authorization**:
   - The status should change to "Authorized"
   - The "Sync Now" button becomes enabled

**Simulator limitations**:
- The iOS Simulator has **limited HealthKit data**
- You may not see real workouts unless you've manually added them
- To test with real data:
  - Use a real iPhone/iPad
  - Or manually add test workouts in the Health app (Settings → Health → Data)

**Note**: HealthKit permissions are **read-only**. The app never writes to HealthKit.

## Step 8: Trigger a Sync

1. **Tap "Sync Now"** in the iOS app

2. **What happens**:
   - The app queries HealthKit for new/updated data
   - Data is formatted into JSON payloads
   - Payloads are sent to the backend API (`POST /api/v1/workouts`, `POST /api/v1/profile-metrics`)
   - The backend validates, deduplicates, and stores the data

3. **Success indicators**:
   - "Last Sync" timestamp updates
   - No error banners appear
   - In dev mode, the diagnostics panel shows:
     - Records received
     - Records inserted
     - Duplicates skipped (if any)
     - Warnings count

4. **Failure indicators**:
   - Red error banner appears
   - In dev mode, detailed error information is shown:
     - HTTP status code
     - Endpoint URL
     - Response body
     - Validation errors (if any)

**Dev mode diagnostics**:
- Expand the "DEV DIAGNOSTICS" section to see:
  - Last request endpoint and status
  - Request duration
  - Record counts (received, inserted, duplicates, warnings, errors)
  - Full technical diagnostics (monospaced text)

**What gets synced**:
- Workouts (running, walking, cycling, strength, HIIT, other)
- Profile metrics (height, weight, body fat percentage)
- Only new or updated records (incremental sync)

## Step 9: Verify Data in the Coach UI

1. **Refresh the coach UI** in your browser (`http://localhost:3000/ui`)

2. **Click on the client** you created earlier

3. **You should see**:
   - **Recent Workouts** section:
     - Table of workouts with start time, duration, type, distance, calories, heart rate
     - ⚠️ indicators if there are warnings
   - **Profile Metrics** section:
     - Table of height, weight, body fat measurements
     - Timestamps for each measurement
   - **Data Quality** section:
     - List of warnings/errors (if any)
     - Validation messages

4. **Verify data integrity**:
   - Workouts have correct `client_id` (no data leakage)
   - Timestamps are reasonable
   - No duplicate workouts (deduplication working)
   - Profile metrics are associated with the correct client

**Multi-client testing**:
- Create a second client with a different pairing code
- Pair a second simulator instance (or use a real device)
- Verify that data from one client doesn't appear in the other client's view

## Debugging & Common Issues

### Backend Not Reachable

**Symptoms**: Pairing fails, sync fails, "Connection error" messages

**Solutions**:
1. Verify the backend is running: `curl http://localhost:3000/dev/health`
2. Check the backend terminal for error messages
3. Verify the iOS app's backend URL is set to `http://localhost:3000`
4. For real devices, use your Mac's IP address instead of `localhost`
5. Check firewall settings (port 3000 should be open)

### Pairing Fails

**Symptoms**: "Invalid pairing code" error, 404 response

**Solutions**:
1. Verify the pairing code exists in the coach UI
2. Check the backend logs for pairing attempts
3. Ensure the pairing code is entered correctly (case-insensitive)
4. Verify the `/pair` endpoint is working: `curl -X POST http://localhost:3000/pair -H "Content-Type: application/json" -d '{"pairing_code": "YOUR_CODE"}'`

### HealthKit Permissions Denied

**Symptoms**: "Not Authorized" status, permission dialogs don't appear

**Solutions**:
1. Go to iOS Settings → Privacy & Security → Health → GymDashSync
2. Enable the required data types manually
3. Restart the app
4. In the simulator, HealthKit permissions may be limited—use a real device for full testing

### No Workouts Appearing

**Symptoms**: Sync succeeds but no data in coach UI

**Solutions**:
1. **Simulator limitation**: The simulator has limited HealthKit data
   - Add test workouts manually in the Health app
   - Or use a real device with actual workout data
2. Check the backend logs for ingest requests
3. Verify the `client_id` is correct in the sync payloads
4. Check the coach UI for the specific client (data is client-scoped)
5. In dev mode, check the sync diagnostics for record counts

### Duplicate Workouts Skipped

**Symptoms**: Sync shows "Duplicates Skipped: N" in diagnostics

**This is expected behavior**:
- The backend deduplicates workouts based on:
  - Same `client_id`
  - Start time within ±120 seconds
  - Duration within ±10% tolerance
- If a workout matches these criteria, it's skipped (not inserted again)
- This prevents duplicate data from multiple syncs

**To test deduplication**:
- Trigger multiple syncs with the same workout data
- Verify duplicates are skipped in the diagnostics
- Check the coach UI—only one instance of the workout should appear

### Simulator vs Real Device Caveats

**Simulator**:
- ✅ Good for testing UI, pairing, sync pipeline
- ✅ `localhost` works for backend URL
- ❌ Limited HealthKit data
- ❌ May not reflect real-world HealthKit behavior

**Real Device**:
- ✅ Full HealthKit data access
- ✅ Real workout data from Apple Watch/iPhone
- ✅ Accurate permission flows
- ❌ Requires backend URL to be your Mac's IP address (not `localhost`)
- ❌ Requires device to be on the same network as your Mac

**Recommendation**: Start with the simulator to verify the pipeline, then test on a real device for full HealthKit integration.

### Dev Mode Error Diagnostics

**Enable dev mode**:
- Dev mode is enabled by default
- Toggle it in the Debug menu (tap "Debug" → "Dev Mode Enabled")

**What dev mode shows**:
- Detailed error messages with HTTP status codes
- Endpoint URLs and response bodies
- Full technical diagnostics
- Error history viewer (tap "Errors" in navigation bar)
- Sync result details (record counts, duplicates, warnings)

**Use dev mode to**:
- Debug pairing failures
- Understand sync errors
- Verify backend communication
- Inspect validation errors

## Resetting State (Dev Only)

Sometimes you need to start fresh. Here's how to reset various components:

### Reset iOS App Pairing

1. **In the app**: Tap "Debug" → "Reset Pairing"
   - This clears the stored `client_id`
   - Next app launch will show the pairing screen again

2. **Or manually**: Delete the app from the simulator and reinstall
   - This clears all `UserDefaults` data

### Clear Error History

1. **In the app**: Tap "Debug" → "Clear Error History"
   - Or tap "Errors" → "Clear"

### Restart Backend

1. **Stop the server**: Press `Ctrl + C` in the backend terminal

2. **Restart**: `npm start` or `node server.js`

3. **Database persists**: The SQLite database file remains, so data is preserved

### Delete Database (Fresh Start)

1. **Stop the backend server**

2. **Delete the database file**:
   ```bash
   rm backend/database.sqlite
   ```

3. **Restart the backend**: The database will be recreated with empty tables

4. **Recreate clients** in the coach UI

**Warning**: This deletes all data. Only do this if you want a completely fresh start.

### Reset HealthKit Permissions (iOS)

1. **iOS Settings** → Privacy & Security → Health → GymDashSync
2. **Turn off all categories**
3. **Restart the app**
4. **Re-grant permissions** when prompted

**Note**: HealthKit doesn't provide a programmatic way to revoke permissions—you must use Settings.

## What This Proves

By completing this guide, you've validated:

✅ **Identity model**: Pairing codes correctly map to `client_id`s  
✅ **Data ownership**: All records are tagged with the correct `client_id`  
✅ **Ingestion pipeline**: iOS app → backend API → SQLite database  
✅ **Deduplication**: Duplicate workouts are correctly identified and skipped  
✅ **Data validation**: Invalid data is caught and logged  
✅ **Multi-client isolation**: Data doesn't leak between clients  
✅ **Coach visibility**: Web UI correctly displays client data  
✅ **Error handling**: Dev mode provides clear diagnostics  

**You're now ready to**:
- Test on real iOS devices
- Deploy the backend to Azure (or another cloud provider)
- Add production authentication
- Scale to multiple users
- Add additional data types

The local development setup proves the core functionality works end-to-end. Production deployment is primarily about:
- Moving SQLite → Azure SQL (or PostgreSQL)
- Adding authentication (replacing pairing codes)
- Hardening security
- Scaling infrastructure

But the data model, sync logic, and validation are all proven to work locally.

