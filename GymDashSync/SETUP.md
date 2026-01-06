# Setup Instructions

## Xcode Project Setup

This project uses the Microsoft Health Data Sync library as a local dependency. To set up the Xcode project:

### Option 1: Create New Xcode Project (Recommended)

1. Open Xcode
2. Create a new iOS App project:
   - Product Name: `GymDashSync`
   - Team: Your development team
   - Organization Identifier: Your organization (e.g., `com.yourcompany`)
   - Interface: SwiftUI
   - Language: Swift
   - Minimum iOS: 13.0

3. Add the HealthDataSync library as a local package:
   - File → Add Packages...
   - Click "Add Local..."
   - Navigate to this directory and select the `HealthDataSync` folder
   - Or add the files directly to your project

4. Add the app source files:
   - Drag `GymDashSyncApp/Sources` folder into your Xcode project
   - Ensure "Copy items if needed" is checked
   - Add to target: `GymDashSync`

5. Configure Info.plist:
   - Copy `GymDashSyncApp/Resources/Info.plist` to your project
   - Or manually add the HealthKit usage descriptions

6. Configure Capabilities:
   - Select your target → Signing & Capabilities
   - Add "HealthKit" capability
   - Ensure "HealthKit" is enabled

### Option 2: Use Swift Package Manager

The project includes a `Package.swift` file for SPM, but iOS apps typically require an Xcode project. You can:

1. Use the Package.swift as a reference for dependencies
2. Create an Xcode project and add the HealthDataSync library as a local package dependency

## Configuration

### Backend Configuration

Configure the backend endpoint in code or via UserDefaults:

```swift
// In AppDelegate or SyncManager initialization
let config = BackendConfig(
    baseURL: "https://your-backend-api.com",
    apiKey: "your-api-key" // Optional
)

// Or set via UserDefaults
UserDefaults.standard.set("https://your-backend-api.com", forKey: "GymDashSync.BackendURL")
UserDefaults.standard.set("your-api-key", forKey: "GymDashSync.APIKey")
```

## Building and Running

1. **Device Required**: HealthKit requires a physical iOS device. The simulator will not work.

2. **Build Settings**:
   - Ensure your deployment target is iOS 13.0 or later
   - Enable HealthKit capability in your target settings

3. **Run**:
   - Connect an iOS device
   - Select your device as the run destination
   - Build and run (⌘R)

## Testing

The app will:
1. Request HealthKit permissions on first launch
2. Show sync status on the main screen
3. Allow manual sync via "Sync Now" button
4. Automatically sync when app comes to foreground

## Troubleshooting

### HealthKit Not Available
- Ensure you're running on a physical device (not simulator)
- Check that HealthKit capability is enabled in your target

### Sync Not Working
- Verify backend URL is configured correctly
- Check network connectivity
- Review debug menu for error messages

### Permissions Denied
- User must grant permissions in iOS Settings → Privacy → Health
- App can request permissions again via the permission buttons

