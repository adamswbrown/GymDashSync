//
//  OnboardingView.swift
//  GymDashSync
//
//  Copyright (c) 2024
//  Licensed under the MIT License.

import SwiftUI
import HealthKit

struct OnboardingView: View {
    @StateObject private var pairingViewModel = PairingViewModel()
    @StateObject private var syncViewModel = SyncViewModel()
    @EnvironmentObject var appState: AppState
    @State private var currentStep: OnboardingStep = .pairing
    @State private var showErrorDetails = false
    
    enum OnboardingStep {
        case pairing
        case permissions
        case complete
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Progress Indicator
            if currentStep != .complete {
                progressIndicator
            }
            
            // Content for current step
            ScrollView {
                VStack(spacing: 30) {
                    switch currentStep {
                    case .pairing:
                        pairingStep
                    case .permissions:
                        permissionsStep
                    case .complete:
                        completeStep
                    }
                }
                .padding()
            }
        }
        .onChange(of: pairingViewModel.isPaired) { oldValue, newValue in
            if newValue {
                // Move to permissions step after successful pairing
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    withAnimation {
                        currentStep = .permissions
                    }
                    // Auto-check permissions status
                    syncViewModel.checkAuthorizationStatus()
                }
            }
        }
        .onChange(of: syncViewModel.isAuthorized) { oldValue, newValue in
            if newValue && currentStep == .permissions {
                // Permissions granted, complete onboarding
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    withAnimation {
                        currentStep = .complete
                    }
                    // Mark onboarding as complete
                    appState.completeOnboarding()
                }
            }
        }
    }
    
    // MARK: - Progress Indicator
    
    private var progressIndicator: some View {
        HStack(spacing: 12) {
            // Step 1: Pairing
            progressStep(
                number: 1,
                title: "Pair Device",
                isActive: currentStep == .pairing,
                isComplete: pairingViewModel.isPaired
            )
            
            // Connector
            progressConnector(isActive: pairingViewModel.isPaired)
            
            // Step 2: Permissions
            progressStep(
                number: 2,
                title: "Permissions",
                isActive: currentStep == .permissions,
                isComplete: syncViewModel.isAuthorized
            )
        }
        .padding()
        .background(Color(.systemBackground))
    }
    
    private func progressStep(number: Int, title: String, isActive: Bool, isComplete: Bool) -> some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(isComplete ? Color.green : (isActive ? Color.blue : Color.gray.opacity(0.3)))
                    .frame(width: 40, height: 40)
                
                if isComplete {
                    Image(systemName: "checkmark")
                        .foregroundColor(.white)
                        .font(.system(size: 16, weight: .bold))
                } else {
                    Text("\(number)")
                        .foregroundColor(isActive ? .white : .gray)
                        .font(.system(size: 18, weight: .bold))
                }
            }
            
            Text(title)
                .font(.caption)
                .foregroundColor(isActive ? .primary : .secondary)
                .fontWeight(isActive ? .semibold : .regular)
        }
    }
    
    private func progressConnector(isActive: Bool) -> some View {
        Rectangle()
            .fill(isActive ? Color.blue : Color.gray.opacity(0.3))
            .frame(height: 2)
            .frame(maxWidth: 40)
    }
    
    // MARK: - Pairing Step
    
    private var pairingStep: some View {
        VStack(spacing: 30) {
            // Header
            VStack(spacing: 12) {
                Image(systemName: "link.circle.fill")
                    .font(.system(size: 80))
                    .foregroundColor(.blue)
                
                Text("Connect Your Device")
                    .font(.title)
                    .fontWeight(.bold)
                
                Text("Enter the pairing code provided by your coach to connect your device and start syncing your workouts.")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            .padding(.top, 40)
            
            // Error Banner (if error exists)
            if let error = pairingViewModel.lastError {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                        Text("Connection Failed")
                            .fontWeight(.semibold)
                        Spacer()
                    }
                    
                    Text(error.displayMessage)
                        .font(.body)
                        .foregroundColor(.primary)
                    
                    Button(action: {
                        pairingViewModel.clearError()
                    }) {
                        Text("Dismiss")
                            .font(.caption)
                            .foregroundColor(.blue)
                    }
                }
                .padding()
                .background(Color.red.opacity(0.1))
                .cornerRadius(10)
            }
            
            // Pairing Code Input
            VStack(spacing: 16) {
                TextField("Enter pairing code", text: $pairingViewModel.pairingCode)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .autocapitalization(.allCharacters)
                    .disableAutocorrection(true)
                    .font(.title2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                
                if pairingViewModel.isPairing {
                    HStack {
                        ProgressView()
                        Text("Connecting...")
                            .foregroundColor(.secondary)
                    }
                    .padding()
                } else {
                    Button(action: {
                        pairingViewModel.pair()
                    }) {
                        Text("Connect")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(pairingViewModel.pairingCode.isEmpty ? Color.gray : Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(10)
                    }
                    .disabled(pairingViewModel.pairingCode.isEmpty || pairingViewModel.isPairing)
                    .padding(.horizontal)
                }
            }
            
            Spacer()
        }
        .onAppear {
            // Check if already paired - if so, skip to permissions step
            if appState.hasClientId {
                currentStep = .permissions
                // Also update pairing view model to reflect paired state
                pairingViewModel.isPaired = true
            }
        }
    }
    
    // MARK: - Permissions Step
    
    private var permissionsStep: some View {
        VStack(spacing: 30) {
            // Header
            VStack(spacing: 12) {
                Image(systemName: "heart.circle.fill")
                    .font(.system(size: 80))
                    .foregroundColor(.red)
                
                Text("Enable HealthKit Access")
                    .font(.title)
                    .fontWeight(.bold)
                
                Text("GymDash Sync needs access to your workout and health data to sync with your coach. Your data stays private and secure.")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            .padding(.top, 40)
            
            // Status
            VStack(spacing: 16) {
                if syncViewModel.isAuthorized {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.title2)
                        Text("Permissions Granted")
                            .font(.headline)
                            .foregroundColor(.green)
                    }
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(Color.green.opacity(0.1))
                    .cornerRadius(10)
                } else {
                    // What we need access to
                    VStack(alignment: .leading, spacing: 12) {
                        Text("We'll request access to:")
                            .font(.headline)
                        
                        VStack(alignment: .leading, spacing: 8) {
                            permissionItem(icon: "figure.run", text: "Workouts")
                            permissionItem(icon: "ruler", text: "Height")
                            permissionItem(icon: "scalemass", text: "Weight")
                            permissionItem(icon: "percent", text: "Body Fat Percentage")
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.systemGray6))
                    .cornerRadius(10)
                    
                    // Request Permissions Button
                    Button(action: {
                        requestAllPermissions()
                    }) {
                        HStack {
                            Image(systemName: "hand.raised.fill")
                            Text("Enable HealthKit Access")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                    }
                    .padding(.horizontal)
                }
            }
            
            // Info about permissions
            if !syncViewModel.isAuthorized {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "info.circle.fill")
                            .foregroundColor(.blue)
                        Text("About Permissions")
                            .fontWeight(.semibold)
                    }
                    
                    Text("You can change these permissions anytime in Settings → Privacy & Security → Health → GymDashSync")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding()
                .background(Color.blue.opacity(0.1))
                .cornerRadius(10)
            }
            
            Spacer()
        }
        .onAppear {
            // Check authorization status when this step appears
            syncViewModel.checkAuthorizationStatus()
        }
    }
    
    private func permissionItem(icon: String, text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(.blue)
                .frame(width: 24)
            Text(text)
                .font(.body)
        }
    }
    
    private func requestAllPermissions() {
        // Request all permissions in a single HealthKit authorization call
        // This will show ONE permission dialog with all types (workouts + profile metrics)
        syncViewModel.requestAllPermissions()
    }
    
    // MARK: - Complete Step
    
    private var completeStep: some View {
        VStack(spacing: 30) {
            Spacer()
            
            // Success animation
            VStack(spacing: 20) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 100))
                    .foregroundColor(.green)
                
                Text("You're All Set!")
                    .font(.title)
                    .fontWeight(.bold)
                
                Text("Your device is connected and HealthKit permissions are enabled. You can now sync your workouts.")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            
            // Client ID display
            if let clientId = UserDefaults.standard.string(forKey: "GymDashSync.ClientId"), !clientId.isEmpty {
                VStack(spacing: 8) {
                    Text("Device ID")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(clientId)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.primary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color(.systemGray6))
                        .cornerRadius(8)
                }
                .padding()
                .background(Color(.systemBackground))
                .cornerRadius(10)
                .shadow(color: Color.black.opacity(0.05), radius: 5, x: 0, y: 2)
            }
            
            // Continue button
            Button(action: {
                appState.completeOnboarding()
            }) {
                Text("Start Syncing")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(10)
            }
            .padding(.horizontal)
            
            Spacer()
        }
    }
}

