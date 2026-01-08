//
//  ContentView.swift
//  GymDashSync
//
//  Copyright (c) 2024
//  Licensed under the MIT License.

import SwiftUI
import HealthKit

struct ContentView: View {
    @StateObject private var viewModel = SyncViewModel()
    @EnvironmentObject var appState: AppState
    @State private var showDebugMenu = false
    @State private var showErrorHistory = false
    @State private var showDiagnostics = false
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    // Status Section
                    statusSection
                    
                    // Error Banner (if error exists)
                    if let error = viewModel.lastError {
                        errorBanner(error: error)
                    }
                    
                    // HealthKit Error Banner
                    if let error = viewModel.healthKitError {
                        healthKitErrorBanner(error: error)
                    }
                    
                    // Sync Button
                    syncButton
                    
                    // Sync Summary Section (only shown after successful sync)
                    if !viewModel.isSyncing && viewModel.lastSyncDate != nil {
                        syncSummarySection
                    }
                    
                    // Most Recent Workout Section
                    if let workout = viewModel.mostRecentWorkoutSynced {
                        mostRecentWorkoutSection(workout: workout)
                    }
                    
                    // Permission Buttons
                    if !viewModel.isAuthorized {
                        permissionButtons
                    }
                    
                    // Dev Diagnostics (only in dev mode)
                    if DevMode.isEnabled {
                        devDiagnosticsSection
                    }
                    
                    Spacer()
                }
                .padding()
            }
            .navigationTitle("GymDash Sync")
            .navigationBarItems(trailing: HStack {
                if DevMode.isEnabled {
                    Button("Errors") {
                        showErrorHistory = true
                    }
                }
                Button("Debug") {
                    showDebugMenu = true
                }
            })
            .sheet(isPresented: $showDebugMenu) {
                DebugView(viewModel: viewModel)
                    .environmentObject(appState)
            }
            .sheet(isPresented: $showErrorHistory) {
                ErrorHistoryView()
            }
        }
    }
    
    // MARK: - View Components
    
    private var statusSection: some View {
        VStack(spacing: 16) {
            // HealthKit Availability Warning (dev mode)
            if DevMode.isEnabled && !HKHealthStore.isHealthDataAvailable() {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text("HealthKit Not Available")
                            .font(.caption)
                            .fontWeight(.semibold)
                    }
                    Text("HealthKit requires a physical iPhone. It is not available on iPad or iOS Simulator.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .padding(8)
                .background(Color.orange.opacity(0.1))
                .cornerRadius(6)
            }
            
            // Connection Status Section
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "server.rack")
                        .foregroundColor(.green)
                    Text("Connected to Railway backend")
                        .font(.subheadline)
                        .fontWeight(.medium)
                }
                Text(viewModel.backendHostname)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(12)
            .background(Color.green.opacity(0.1))
            .cornerRadius(8)
            
            // Authorization Status
            HStack {
                Image(systemName: viewModel.isAuthorized ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundColor(viewModel.isAuthorized ? .green : .red)
                    .font(.title2)
                
                Text(viewModel.isAuthorized ? "Authorized" : "Not Authorized")
                    .font(.headline)
            }
            
            // Client ID / Pairing ID
            if let clientId = UserDefaults.standard.string(forKey: "GymDashSync.ClientId"), !clientId.isEmpty {
                VStack(spacing: 6) {
                    HStack {
                        Image(systemName: "person.circle.fill")
                            .foregroundColor(.blue)
                            .font(.title3)
                        Text("Paired Device")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Spacer()
                    }
                    
                    HStack {
                        Text("Client ID:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(clientId)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.primary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color(.systemGray5))
                            .cornerRadius(4)
                    }
                    .padding(.leading, 8)
                }
                .padding(12)
                .background(Color.blue.opacity(0.1))
                .cornerRadius(8)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text("Not Paired")
                            .font(.subheadline)
                            .fontWeight(.medium)
                    }
                    Text("Device is not paired. Please pair your device to sync data.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(12)
                .background(Color.orange.opacity(0.1))
                .cornerRadius(8)
            }
            
            // Permission Denied Warning
            if !viewModel.isAuthorized && HKHealthStore.isHealthDataAvailable() {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text("Permissions Denied")
                            .font(.caption)
                            .fontWeight(.semibold)
                    }
                    
                    Text("HealthKit permissions were previously denied. iOS won't show the permission dialog again.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("To reset permissions:")
                            .font(.caption2)
                            .fontWeight(.medium)
                            .foregroundColor(.secondary)
                        Text("1. Open Settings")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text("2. Go to Privacy & Security → Health")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text("3. Select GymDashSync")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text("4. Enable the data types you want to share")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .padding(.leading, 8)
                }
                .padding(12)
                .background(Color.orange.opacity(0.1))
                .cornerRadius(8)
            }
            
            // Sync State Section
            VStack(spacing: 8) {
                if viewModel.isSyncing {
                    HStack {
                        ProgressView()
                        Text("Syncing...")
                            .font(.headline)
                    }
                } else if let lastSync = viewModel.lastSyncDate {
                    VStack(spacing: 4) {
                        Text("Last synced")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(lastSync, style: .relative)
                            .font(.subheadline)
                            .fontWeight(.medium)
                    }
                } else {
                    Text("No sync yet")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }
            
            // Refresh Status Button (if not authorized)
            if !viewModel.isAuthorized && HKHealthStore.isHealthDataAvailable() {
                Button(action: {
                    viewModel.checkAuthorizationStatus()
                }) {
                    HStack {
                        Image(systemName: "arrow.clockwise")
                        Text("Refresh Status")
                    }
                    .font(.caption)
                    .foregroundColor(.blue)
                }
                .padding(.top, 4)
            }
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }
    
    private func errorBanner(error: AppError) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.red)
                Text("Sync Error")
                    .fontWeight(.semibold)
                Spacer()
                Button(action: {
                    viewModel.clearLastError()
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
            }
            
            Text(error.displayMessage)
                .font(.body)
                .foregroundColor(.primary)
            
            if DevMode.isEnabled {
                Text(error.technicalDetails)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
                    .padding(8)
                    .background(Color(.systemGray6))
                    .cornerRadius(6)
            }
        }
        .padding()
        .background(Color.red.opacity(0.1))
        .cornerRadius(10)
    }
    
    private func healthKitErrorBanner(error: AppError) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "heart.slash.fill")
                    .foregroundColor(.orange)
                Text("HealthKit Error")
                    .fontWeight(.semibold)
                Spacer()
                Button(action: {
                    viewModel.clearHealthKitError()
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
            }
            
            Text(error.displayMessage)
                .font(.body)
                .foregroundColor(.primary)
            
            if DevMode.isEnabled, let detail = error.detail {
                Text(detail)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .background(Color.orange.opacity(0.1))
        .cornerRadius(10)
    }
    
    private var syncButton: some View {
        Button(action: {
            viewModel.syncNow()
        }) {
            HStack {
                if viewModel.isSyncing {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                } else {
                    Image(systemName: "arrow.clockwise")
                }
                Text(viewModel.isSyncing ? "Syncing..." : "Sync Now")
                    .fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(viewModel.isAuthorized && !viewModel.isSyncing ? Color.blue : Color.gray)
            .foregroundColor(.white)
            .cornerRadius(10)
        }
        .disabled(!viewModel.isAuthorized || viewModel.isSyncing)
    }
    
    private var permissionButtons: some View {
        VStack(spacing: 12) {
            Button(action: {
                viewModel.requestWorkoutPermissions()
            }) {
                Text("Authorize Workout Data")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.green)
                    .foregroundColor(.white)
                    .cornerRadius(10)
            }
            
            Button(action: {
                viewModel.requestProfilePermissions()
            }) {
                Text("Authorize Profile Metrics")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(10)
            }
        }
    }
    
    private var syncSummarySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sync Summary")
                .font(.headline)
            
            HStack {
                Text("Workouts synced:")
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(viewModel.workoutsSynced)")
                    .fontWeight(.semibold)
            }
            
            HStack {
                Text("Profile metrics synced:")
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(viewModel.profileMetricsSynced)")
                    .fontWeight(.semibold)
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(8)
    }
    
    private func mostRecentWorkoutSection(workout: WorkoutData) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Most recent workout synced")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(.secondary)
            
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Type:")
                        .foregroundColor(.secondary)
                    Text(workout.workoutType.capitalized)
                        .fontWeight(.medium)
                }
                
                HStack {
                    Text("Start time:")
                        .foregroundColor(.secondary)
                    Text(workout.startTime, style: .date)
                        .fontWeight(.medium)
                    Text(workout.startTime, style: .time)
                        .fontWeight(.medium)
                }
                
                HStack {
                    Text("Duration:")
                        .foregroundColor(.secondary)
                    Text(formatDuration(workout.durationSeconds))
                        .fontWeight(.medium)
                }
            }
        }
        .padding()
        .background(Color.blue.opacity(0.1))
        .cornerRadius(8)
    }
    
    private func formatDuration(_ seconds: Double) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else {
            return "\(minutes)m"
        }
    }
    
    @ViewBuilder
    private var devDiagnosticsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("DEV DIAGNOSTICS")
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundColor(.secondary)
                Spacer()
                Button(action: {
                    showDiagnostics.toggle()
                }) {
                    Image(systemName: showDiagnostics ? "chevron.down" : "chevron.right")
                        .foregroundColor(.secondary)
                }
            }
            
            if showDiagnostics {
                if !viewModel.lastSyncResults.isEmpty {
                    ForEach(Array(viewModel.lastSyncResults.enumerated()), id: \.offset) { index, result in
                        VStack(alignment: .leading, spacing: 8) {
                            if viewModel.lastSyncResults.count > 1 {
                                Text("Sync \(index + 1) of \(viewModel.lastSyncResults.count)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .padding(.bottom, 4)
                            }
                            
                            Text("Last Sync Summary")
                                .font(.headline)
                            
                            HStack {
                                Text("Status:")
                                Spacer()
                                Text(result.success ? "Success" : "Failed")
                                    .foregroundColor(result.success ? .green : .red)
                            }
                            
                            if let endpoint = result.endpoint {
                                HStack {
                                    Text("Endpoint:")
                                    Spacer()
                                    Text(endpoint)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                            
                            if let statusCode = result.statusCode {
                                HStack {
                                    Text("Status Code:")
                                    Spacer()
                                    Text("\(statusCode)")
                                        .foregroundColor(.secondary)
                                }
                            }
                            
                            HStack {
                                Text("Duration:")
                                Spacer()
                                Text(String(format: "%.2fs", result.duration))
                                    .foregroundColor(.secondary)
                            }
                            
                            Divider()
                            
                            Text("Record Counts")
                                .font(.subheadline)
                                .fontWeight(.semibold)
                            
                            HStack {
                                Text("Received:")
                                Spacer()
                                Text("\(result.recordsReceived)")
                                    .foregroundColor(.secondary)
                            }
                            
                            HStack {
                                Text("Inserted:")
                                Spacer()
                                Text("\(result.recordsInserted)")
                                    .foregroundColor(.green)
                            }
                            
                            if result.duplicatesSkipped > 0 {
                                HStack {
                                    Text("Duplicates Skipped:")
                                    Spacer()
                                    Text("\(result.duplicatesSkipped)")
                                        .foregroundColor(.orange)
                                }
                            }
                            
                            if result.warningsCount > 0 {
                                HStack {
                                    Text("Warnings:")
                                    Spacer()
                                    Text("\(result.warningsCount)")
                                        .foregroundColor(.orange)
                                }
                            }
                            
                            if result.errorsCount > 0 {
                                HStack {
                                    Text("Errors:")
                                    Spacer()
                                    Text("\(result.errorsCount)")
                                        .foregroundColor(.red)
                                }
                            }
                            
                            if let validationErrors = result.validationErrors, !validationErrors.isEmpty {
                                Divider()
                                Text("Validation Errors:")
                                    .font(.subheadline)
                                    .fontWeight(.semibold)
                                ForEach(validationErrors, id: \.self) { error in
                                    Text("• \(error)")
                                        .font(.caption)
                                        .foregroundColor(.red)
                                }
                            }
                            
                            if DevMode.isEnabled {
                                Divider()
                                Text(result.diagnostics)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .padding(8)
                                    .background(Color(.systemGray6))
                                    .cornerRadius(6)
                            }
                        }
                        .padding()
                        .background(Color(.systemGray6))
                        .cornerRadius(8)
                    }
                } else {
                    Text("No sync results yet")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding()
                }
            }
        }
        .padding()
        .background(Color(.systemGray6).opacity(0.5))
        .cornerRadius(10)
    }
}

struct DebugView: View {
    @ObservedObject var viewModel: SyncViewModel
    @EnvironmentObject var appState: AppState
    @Environment(\.presentationMode) var presentationMode
    
    var body: some View {
        NavigationView {
            List {
                Section(header: Text("Status")) {
                    HStack {
                        Text("Authorized")
                        Spacer()
                        Text(viewModel.isAuthorized ? "Yes" : "No")
                            .foregroundColor(.secondary)
                    }
                    
                    HStack {
                        Text("Syncing")
                        Spacer()
                        Text(viewModel.isSyncing ? "Yes" : "No")
                            .foregroundColor(.secondary)
                    }
                    
                    if let lastSync = viewModel.lastSyncDate {
                        HStack {
                            Text("Last Sync")
                            Spacer()
                            Text(lastSync, style: .date)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                
                Section(header: Text("Dev Mode")) {
                    HStack {
                        Text("Dev Mode Enabled")
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { DevMode.isEnabled },
                            set: { DevMode.setEnabled($0) }
                        ))
                    }
                }
                
                Section(header: Text("Permissions")) {
                    Button(action: {
                        viewModel.requestWorkoutPermissions()
                    }) {
                        Text("Request Workout Permissions")
                            .foregroundColor(.blue)
                    }
                    
                    Button(action: {
                        viewModel.requestProfilePermissions()
                    }) {
                        Text("Request Profile Permissions")
                            .foregroundColor(.blue)
                    }
                }
                
                Section(header: Text("Actions")) {
                    Button(action: {
                        viewModel.forceResync()
                    }) {
                        HStack {
                            Text("Force Re-Sync All Data")
                                .foregroundColor(.blue)
                            Spacer()
                            if viewModel.isSyncing {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle())
                            }
                        }
                    }
                    .disabled(viewModel.isSyncing || !viewModel.isAuthorized)
                    
                    Button(action: {
                        viewModel.resetAuthorization()
                        presentationMode.wrappedValue.dismiss()
                    }) {
                        Text("Reset Authorization")
                            .foregroundColor(.red)
                    }
                    
                    Button(action: {
                        appState.clearClientId()
                        presentationMode.wrappedValue.dismiss()
                    }) {
                        Text("Reset Pairing")
                            .foregroundColor(.red)
                    }
                    
                    Button(action: {
                        ErrorHistory.shared.clear()
                        presentationMode.wrappedValue.dismiss()
                    }) {
                        Text("Clear Error History")
                            .foregroundColor(.orange)
                    }
                }
                
                Section(header: Text("Configuration")) {
                    HStack {
                        Text("Backend URL")
                        Spacer()
                        Text(BackendConfig.default.baseURL)
                            .foregroundColor(.secondary)
                            .font(.caption)
                    }
                    
                    if let clientId = UserDefaults.standard.string(forKey: "GymDashSync.ClientId"), !clientId.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Client ID")
                                    .fontWeight(.medium)
                                Spacer()
                                Button(action: {
                                    UIPasteboard.general.string = clientId
                                }) {
                                    Image(systemName: "doc.on.doc")
                                        .foregroundColor(.blue)
                                        .font(.caption)
                                }
                            }
                            
                            Text(clientId)
                                .font(.system(.body, design: .monospaced))
                                .foregroundColor(.primary)
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color(.systemGray6))
                                .cornerRadius(6)
                                .textSelection(.enabled)
                        }
                        .padding(.vertical, 4)
                    } else {
                        HStack {
                            Text("Client ID")
                            Spacer()
                            Text("Not set")
                                .foregroundColor(.red)
                                .font(.subheadline)
                        }
                    }
                }
            }
            .navigationTitle("Debug")
            .navigationBarItems(trailing: Button("Done") {
                presentationMode.wrappedValue.dismiss()
            })
        }
    }
}

struct ErrorHistoryView: View {
    @ObservedObject var errorHistory = ErrorHistory.shared
    @Environment(\.presentationMode) var presentationMode
    
    var body: some View {
        NavigationView {
            List {
                if errorHistory.errors.isEmpty {
                    Text("No errors recorded")
                        .foregroundColor(.secondary)
                        .padding()
                } else {
                    ForEach(errorHistory.errors) { error in
                        NavigationLink(destination: ErrorDetailView(error: error)) {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(error.category.rawValue.uppercased())
                                        .font(.caption)
                                        .fontWeight(.bold)
                                        .foregroundColor(colorForCategory(error.category))
                                    Spacer()
                                    Text(error.timestamp, style: .relative)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Text(error.message)
                                    .font(.body)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            .navigationTitle("Error History")
            .navigationBarItems(
                leading: Button("Clear") {
                    errorHistory.clear()
                },
                trailing: Button("Done") {
                    presentationMode.wrappedValue.dismiss()
                }
            )
        }
    }
    
    private func colorForCategory(_ category: ErrorCategory) -> Color {
        switch category {
        case .pairing: return .blue
        case .healthkit: return .orange
        case .network: return .purple
        case .backend: return .red
        case .validation: return .yellow
        case .unknown: return .gray
        }
    }
}

struct ErrorDetailView: View {
    let error: AppError
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Category")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(error.category.rawValue)
                        .font(.headline)
                }
                
                Divider()
                
                VStack(alignment: .leading, spacing: 8) {
                    Text("Message")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(error.message)
                        .font(.body)
                }
                
                if let detail = error.detail {
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Detail")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(detail)
                            .font(.body)
                    }
                }
                
                if let context = error.context {
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Context")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        if let endpoint = context.endpoint {
                            Text("Endpoint: \(endpoint)")
                                .font(.caption)
                        }
                        
                        if let statusCode = context.statusCode {
                            Text("Status Code: \(statusCode)")
                                .font(.caption)
                        }
                        
                        if let responseBody = context.responseBody {
                            Text("Response: \(responseBody)")
                                .font(.system(.caption, design: .monospaced))
                                .padding(8)
                                .background(Color(.systemGray6))
                                .cornerRadius(6)
                        }
                    }
                }
                
                Divider()
                
                VStack(alignment: .leading, spacing: 8) {
                    Text("Timestamp")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(error.timestamp, style: .date)
                        .font(.body)
                }
                
                VStack(alignment: .leading, spacing: 8) {
                    Text("Error ID")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(error.id.uuidString)
                        .font(.system(.caption, design: .monospaced))
                }
            }
            .padding()
        }
        .navigationTitle("Error Details")
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
            .environmentObject(AppState())
    }
}
