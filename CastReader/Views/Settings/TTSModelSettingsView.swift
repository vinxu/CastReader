//
//  TTSModelSettingsView.swift
//  CastReader
//
//  Settings view for managing local TTS model.
//  Note: FluidAudioTTS automatically downloads models on first use.
//

import SwiftUI

struct TTSModelSettingsView: View {
    @StateObject private var downloadService = ModelDownloadService.shared
    @State private var showResetConfirmation = false
    @State private var isInitializing = false
    @State private var initError: String?
    @State private var selectedProvider: TTSProvider = TTSService.shared.currentProvider

    var body: some View {
        List {
            providerSection
            modelStatusSection
            actionsSection
            infoSection
        }
        .navigationTitle("TTS Settings")
        .alert("Reset Model", isPresented: $showResetConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) {
                resetModel()
            }
        } message: {
            Text("This will reset the TTS model status. The model will be re-downloaded on next use.")
        }
        .alert("Initialization Error", isPresented: .constant(initError != nil)) {
            Button("OK") {
                initError = nil
            }
        } message: {
            Text(initError ?? "")
        }
        .onAppear {
            selectedProvider = TTSService.shared.currentProvider
        }
    }

    // MARK: - Provider Selection Section

    private var providerSection: some View {
        Section {
            if TTSService.shared.isLocalModelAvailable {
                // Local model downloaded - user can choose
                Picker("TTS Provider", selection: $selectedProvider) {
                    Text("Local (On-device)").tag(TTSProvider.local)
                    Text("Cloud").tag(TTSProvider.cloud)
                }
                .pickerStyle(.segmented)
                .onChange(of: selectedProvider) { newValue in
                    TTSService.shared.setPreferredProvider(newValue)
                }
            } else {
                // Local model not downloaded - show cloud only
                HStack {
                    Text("Current Provider")
                    Spacer()
                    Text("Cloud")
                        .foregroundColor(.secondary)
                }

                Text("Download the local model to enable offline TTS")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        } header: {
            Text("TTS Provider")
        } footer: {
            if TTSService.shared.isLocalModelAvailable {
                Text("Local: Fast, offline, uses device GPU/ANE. Cloud: Requires internet, processed on server.")
            } else {
                Text("Currently using cloud TTS. Download the local model below to enable offline mode.")
            }
        }
    }

    // MARK: - Model Status Section

    private var modelStatusSection: some View {
        Section {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Kokoro TTS (CoreML)")
                        .font(.headline)
                    Text(statusText)
                        .font(.subheadline)
                        .foregroundColor(statusColor)
                }

                Spacer()

                statusIcon
            }

            if case .downloading(let progress) = downloadService.status {
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)

                    Text("Initializing model...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        } header: {
            Text("Model Status")
        } footer: {
            Text("The local TTS model runs on Apple Neural Engine (ANE) for efficient on-device speech synthesis with low memory usage.")
        }
    }

    // MARK: - Actions Section

    private var actionsSection: some View {
        Section {
            switch downloadService.status {
            case .notDownloaded:
                Button(action: initializeModel) {
                    HStack {
                        Image(systemName: "arrow.down.circle.fill")
                            .foregroundColor(.blue)
                        Text("Initialize Model")
                        Spacer()
                        Text(downloadService.formattedModelSize)
                            .foregroundColor(.secondary)
                    }
                }
                .disabled(isInitializing)

            case .downloading:
                HStack {
                    Image(systemName: "arrow.down.circle")
                        .foregroundColor(.orange)
                    Text("Initializing...")
                        .foregroundColor(.secondary)
                }

            case .downloaded:
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("Model Ready")
                    Spacer()
                    Text("On-device")
                        .foregroundColor(.secondary)
                }

                Button(role: .destructive, action: { showResetConfirmation = true }) {
                    HStack {
                        Image(systemName: "arrow.counterclockwise")
                            .foregroundColor(.orange)
                        Text("Reset Model Status")
                    }
                }

            case .error(let message):
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                        Text("Error")
                            .foregroundColor(.red)
                    }

                    Text(message)
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Button("Retry") {
                        initializeModel()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        } header: {
            Text("Actions")
        }
    }

    // MARK: - Info Section

    private var infoSection: some View {
        Section {
            InfoRow(title: "Model", value: Constants.TTS.LocalModel.modelName)
            InfoRow(title: "Size", value: downloadService.formattedModelSize)
            InfoRow(title: "Engine", value: "CoreML + ANE")
            InfoRow(title: "Storage", value: "~/.cache/fluidaudio/")
        } header: {
            Text("Information")
        } footer: {
            Text("The model is automatically downloaded from Hugging Face on first use. If the model is not initialized, the app will use the cloud TTS service as fallback.")
        }
    }

    // MARK: - Computed Properties

    private var statusText: String {
        switch downloadService.status {
        case .notDownloaded:
            return "Not initialized"
        case .downloading(let progress):
            return "Initializing... \(Int(progress * 100))%"
        case .downloaded:
            return "Ready to use"
        case .error(let message):
            return "Error: \(message)"
        }
    }

    private var statusColor: Color {
        switch downloadService.status {
        case .notDownloaded:
            return .secondary
        case .downloading:
            return .orange
        case .downloaded:
            return .green
        case .error:
            return .red
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch downloadService.status {
        case .notDownloaded:
            Image(systemName: "arrow.down.circle")
                .foregroundColor(.secondary)
                .font(.title2)
        case .downloading:
            ProgressView()
        case .downloaded:
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
                .font(.title2)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.red)
                .font(.title2)
        }
    }

    // MARK: - Actions

    private func initializeModel() {
        isInitializing = true
        Task {
            do {
                try await downloadService.startDownload()
            } catch {
                initError = error.localizedDescription
            }
            isInitializing = false
        }
    }

    private func resetModel() {
        downloadService.resetModel()
    }
}

// MARK: - Info Row

private struct InfoRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
        }
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        TTSModelSettingsView()
    }
}
