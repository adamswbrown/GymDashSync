//
//  PairingView.swift
//  GymDashSync
//
//  Copyright (c) 2024
//  Licensed under the MIT License.

import SwiftUI
import Combine

struct PairingView: View {
    @StateObject private var viewModel = PairingViewModel()
    @EnvironmentObject var appState: AppState
    @State private var showErrorDetails = false
    
    var body: some View {
        VStack(spacing: 30) {
            // Header
            VStack(spacing: 12) {
                Image(systemName: "link.circle.fill")
                    .font(.system(size: 60))
                    .foregroundColor(.blue)
                
                Text("Connect Your Device")
                    .font(.title)
                    .fontWeight(.bold)
                
                Text("Enter the code provided by your coach to connect your workouts.")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            .padding(.top, 40)
            
            // Error Banner (if error exists)
            if let error = viewModel.lastError {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                        Text("Pairing Failed")
                            .fontWeight(.semibold)
                        Spacer()
                        if DevMode.isEnabled {
                            Button(action: {
                                showErrorDetails.toggle()
                            }) {
                                Text(showErrorDetails ? "Hide Details" : "Show Details")
                                    .font(.caption)
                            }
                        }
                    }
                    
                    Text(error.displayMessage)
                        .font(.body)
                        .foregroundColor(.primary)
                    
                    if DevMode.isEnabled && showErrorDetails {
                        VStack(alignment: .leading, spacing: 4) {
                            Divider()
                            Text(error.technicalDetails)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.secondary)
                                .padding(8)
                                .background(Color(.systemGray6))
                                .cornerRadius(6)
                        }
                    }
                    
                    Button(action: {
                        viewModel.clearError()
                    }) {
                        Text("Dismiss")
                            .font(.caption)
                            .foregroundColor(.blue)
                    }
                }
                .padding()
                .background(Color.red.opacity(0.1))
                .cornerRadius(10)
                .padding(.horizontal)
            }
            
            // Pairing Code Input
            VStack(spacing: 16) {
                TextField("Enter pairing code", text: $viewModel.pairingCode)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .autocapitalization(.allCharacters)
                    .disableAutocorrection(true)
                    .font(.title2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                
                if viewModel.isPairing {
                    ProgressView()
                        .padding()
                } else {
                    Button(action: {
                        viewModel.pair()
                    }) {
                        Text("Connect")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(viewModel.pairingCode.isEmpty ? Color.gray : Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(10)
                    }
                    .disabled(viewModel.pairingCode.isEmpty || viewModel.isPairing)
                    .padding(.horizontal)
                }
            }
            .padding(.top, 20)
            
            Spacer()
        }
        .padding()
        .onChange(of: viewModel.isPaired) { isPaired in
            if isPaired {
                appState.checkClientId()
            }
        }
    }
}

class PairingViewModel: ObservableObject {
    @Published var pairingCode: String = ""
    @Published var isPairing: Bool = false
    @Published var lastError: AppError?
    @Published var isPaired: Bool = false
    
    private let backendConfig = BackendConfig.default
    private let errorHistory = ErrorHistory.shared
    
    func clearError() {
        lastError = nil
    }
    
    func pair() {
        guard !pairingCode.isEmpty else {
            lastError = ErrorMapper.validationError(
                message: "Please enter a pairing code",
                detail: "Pairing code field is empty"
            )
            errorHistory.add(lastError!)
            return
        }
        
        isPairing = true
        lastError = nil
        
        let startTime = Date()
        let endpoint = "\(backendConfig.baseURL)/pair"
        
        // Call pairing API
        guard let url = URL(string: endpoint) else {
            let error = ErrorMapper.networkError(
                message: "Invalid server URL",
                endpoint: endpoint,
                detail: "Failed to create URL from: \(endpoint)"
            )
            lastError = error
            errorHistory.add(error)
            isPairing = false
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        
        let payload: [String: Any] = ["pairing_code": pairingCode.trimmingCharacters(in: .whitespacesAndNewlines)]
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        } catch {
            let appError = ErrorMapper.unknownError(
                message: "Failed to create request",
                error: error,
                endpoint: endpoint
            )
            lastError = appError
            errorHistory.add(appError)
            isPairing = false
            return
        }
        
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            let duration = Date().timeIntervalSince(startTime)
            
            DispatchQueue.main.async {
                self?.isPairing = false
                
                if let error = error {
                    let appError = ErrorMapper.networkError(
                        message: "Connection error: \(error.localizedDescription)",
                        endpoint: endpoint,
                        detail: error.localizedDescription,
                        duration: duration
                    )
                    self?.lastError = appError
                    self?.errorHistory.add(appError)
                    return
                }
                
                guard let httpResponse = response as? HTTPURLResponse else {
                    let appError = ErrorMapper.networkError(
                        message: "Invalid server response",
                        endpoint: endpoint,
                        detail: "Response is not HTTPURLResponse",
                        duration: duration
                    )
                    self?.lastError = appError
                    self?.errorHistory.add(appError)
                    return
                }
                
                let statusCode = httpResponse.statusCode
                let responseBody = data != nil ? String(data: data!, encoding: .utf8) : nil
                
                if statusCode == 404 {
                    let appError = ErrorMapper.pairingError(
                        message: "Invalid pairing code",
                        endpoint: endpoint,
                        statusCode: statusCode,
                        responseBody: responseBody,
                        duration: duration
                    )
                    self?.lastError = appError
                    self?.errorHistory.add(appError)
                    return
                }
                
                guard statusCode >= 200 && statusCode < 300,
                      let data = data else {
                    let appError = ErrorMapper.backendError(
                        message: "Server error",
                        endpoint: endpoint,
                        statusCode: statusCode,
                        responseBody: responseBody,
                        detail: "Server returned status code \(statusCode)",
                        duration: duration
                    )
                    self?.lastError = appError
                    self?.errorHistory.add(appError)
                    return
                }
                
                do {
                    if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let clientId = json["client_id"] as? String {
                        // Store client_id
                        UserDefaults.standard.set(clientId, forKey: "GymDashSync.ClientId")
                        UserDefaults.standard.synchronize()
                        self?.isPaired = true
                    } else {
                        let appError = ErrorMapper.backendError(
                            message: "Invalid server response",
                            endpoint: endpoint,
                            statusCode: statusCode,
                            responseBody: responseBody,
                            detail: "Response missing client_id field",
                            duration: duration
                        )
                        self?.lastError = appError
                        self?.errorHistory.add(appError)
                    }
                } catch {
                    let appError = ErrorMapper.backendError(
                        message: "Failed to parse response",
                        endpoint: endpoint,
                        statusCode: statusCode,
                        responseBody: responseBody,
                        detail: error.localizedDescription,
                        duration: duration
                    )
                    self?.lastError = appError
                    self?.errorHistory.add(appError)
                }
            }
        }.resume()
    }
}


struct PairingView_Previews: PreviewProvider {
    static var previews: some View {
        PairingView()
            .environmentObject(AppState())
    }
}
