//
//  ImportSheet.swift
//  CastReader
//

import SwiftUI
import UniformTypeIdentifiers
import PhotosUI

struct ImportSheet: View {
    @Environment(\.dismiss) var dismiss
    @StateObject private var viewModel = ImportViewModel()

    @State private var showFilePicker = false
    @State private var showTextInput = false
    @State private var showPhotoPicker = false
    @State private var showError = false
    @State private var showUploadSuccess = false

    /// Callback for text input direct playback
    var onTextSubmit: ((TextInputData) -> Void)?

    /// Callback for EPUB upload - triggers navigation to PlayerView
    var onEPUBUploaded: ((EPUBUploadResult) -> Void)?

    var body: some View {
        NavigationView {
            importOptionsList
                .navigationTitle("Add Content")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Cancel") {
                            dismiss()
                        }
                    }
                }
        }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: supportedFileTypes,
            allowsMultipleSelection: false,
            onCompletion: handleFileImport
        )
        .sheet(isPresented: $showPhotoPicker) {
            ImagePicker { imageData, filename in
                handleImageSelected(imageData: imageData, filename: filename)
            }
        }
        .sheet(isPresented: $showTextInput) {
            TextInputView { inputData in
                print("🟢 [ImportSheet] Received TextInputData from TextInputView")
                print("🟢 [ImportSheet] inputData.id: \(inputData.id)")
                print("🟢 [ImportSheet] inputData.title: \(inputData.title)")

                // Background upload (fire-and-forget)
                print("🟢 [ImportSheet] Starting background upload task...")
                Task {
                    await viewModel.uploadText(inputData.content)
                }

                // Pass data to parent for immediate playback
                print("🟢 [ImportSheet] Calling onTextSubmit callback...")
                onTextSubmit?(inputData)
                print("🟢 [ImportSheet] onTextSubmit callback done, dismissing...")

                // Dismiss ImportSheet
                dismiss()
            }
        }
        .alert("Upload Error", isPresented: $showError) {
            Button("OK") {
                viewModel.error = nil
            }
        } message: {
            Text(viewModel.error ?? "Unknown error")
        }
        .alert("Upload Successful", isPresented: $showUploadSuccess) {
            Button("View in Library") {
                dismiss()
            }
        } message: {
            Text("Your file has been uploaded and is being processed. You can view the progress in your Library.")
        }
        .onChange(of: viewModel.error) { newValue in
            showError = newValue != nil
        }
        .overlay(uploadingOverlay)
    }

    // MARK: - Subviews

    private var importOptionsList: some View {
        List {
            ImportOptionRow(
                icon: "doc.fill",
                title: "Upload File",
                subtitle: "PDF, EPUB, DOCX, TXT",
                action: { showFilePicker = true }
            )

            ImportOptionRow(
                icon: "camera.fill",
                title: "Scan Text",
                subtitle: "Import from photo",
                action: { showPhotoPicker = true }
            )

            ImportOptionRow(
                icon: "text.cursor",
                title: "Input Text",
                subtitle: "Paste or type content",
                action: { showTextInput = true }
            )
        }
        .listStyle(.insetGrouped)
    }

    @ViewBuilder
    private var uploadingOverlay: some View {
        if viewModel.isUploading {
            Color.black.opacity(0.3)
                .ignoresSafeArea()
                .overlay(
                    VStack(spacing: 16) {
                        ProgressView()
                            .scaleEffect(1.5)
                        Text("Uploading...")
                            .font(.headline)
                    }
                    .padding(32)
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(Color(.systemBackground))
                    )
                )
        }
    }

    // MARK: - Helpers

    private var supportedFileTypes: [UTType] {
        var types: [UTType] = []

        // PDF - try multiple identifiers
        if let pdf = UTType("com.adobe.pdf") {
            types.append(pdf)
        } else {
            types.append(.pdf)
        }

        // Plain text
        types.append(.plainText)

        // EPUB
        if let epub = UTType("org.idpf.epub-container") {
            types.append(epub)
        }

        // DOCX
        if let docx = UTType("org.openxmlformats.wordprocessingml.document") {
            types.append(docx)
        }

        // Add generic types as fallback
        types.append(.data)
        types.append(.content)

        print("📄 [ImportSheet] Supported file types: \(types.map { $0.identifier })")
        return types
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let filename = url.lastPathComponent.lowercased()
            let isEPUB = filename.hasSuffix(".epub")

            Task {
                await viewModel.uploadFile(url)

                if viewModel.uploadSuccess {
                    if isEPUB, let epubResult = viewModel.epubUploadResult {
                        // EPUB: Call callback to navigate to PlayerView
                        print("📗 [ImportSheet] EPUB upload success, triggering navigation")
                        onEPUBUploaded?(epubResult)
                        dismiss()
                    } else {
                        // PDF: Show success alert
                        showUploadSuccess = true
                    }
                }
            }
        case .failure(let error):
            viewModel.error = error.localizedDescription
        }
    }

    private func handleImageSelected(imageData: Data, filename: String) {
        print("📷 [ImportSheet] Image selected: \(filename), size: \(imageData.count) bytes")

        Task {
            await viewModel.uploadImage(imageData: imageData, filename: filename)

            if viewModel.uploadSuccess {
                // Image OCR is async like PDF - show success alert
                showUploadSuccess = true
            }
        }
    }
}

// MARK: - Import Option Row
struct ImportOptionRow: View {
    let icon: String
    let title: String
    let subtitle: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundColor(AppTheme.primary)
                    .frame(width: 40)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .foregroundColor(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 8)
        }
    }
}

// MARK: - Text Input View
struct TextInputView: View {
    @Environment(\.dismiss) var dismiss
    @State private var text = ""
    @State private var title = ""

    var onSubmit: (TextInputData) -> Void

    var body: some View {
        NavigationView {
            VStack(spacing: 16) {
                TextField("Title (optional)", text: $title)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal)

                TextEditor(text: $text)
                    .frame(minHeight: 200)
                    .padding(8)
                    .background(Color(.systemGray6))
                    .cornerRadius(8)
                    .padding(.horizontal)

                Text("\(text.count) characters")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()
            }
            .padding(.top, 16)
            .navigationTitle("Input Text")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Submit") {
                        print("🔵 [TextInputView] Submit clicked")
                        print("🔵 [TextInputView] Title: \(title)")
                        print("🔵 [TextInputView] Content length: \(text.count) chars")
                        print("🔵 [TextInputView] Content preview: \(String(text.prefix(100)))...")

                        let inputData = TextInputData(title: title, content: text)
                        print("🔵 [TextInputView] Created TextInputData with id: \(inputData.id)")

                        onSubmit(inputData)
                        print("🔵 [TextInputView] Callback triggered, dismissing...")
                        dismiss()
                    }
                    .disabled(text.isEmpty)
                }
            }
        }
    }
}

struct ImportSheet_Previews: PreviewProvider {
    static var previews: some View {
        ImportSheet()
    }
}

// MARK: - Half-Screen Import Sheet Overlay
struct ImportSheetOverlay: View {
    @Binding var isPresented: Bool
    var onDismiss: (() -> Void)?
    var onTextSubmit: ((TextInputData) -> Void)?
    var onEPUBUploaded: ((EPUBUploadResult) -> Void)?

    @StateObject private var viewModel = ImportViewModel()

    @State private var showFilePicker = false
    @State private var showTextInput = false
    @State private var showPhotoPicker = false
    @State private var showError = false
    @State private var showUploadSuccess = false
    @State private var dragOffset: CGFloat = 0

    private let sheetHeight: CGFloat = 380
    private let dismissThreshold: CGFloat = 100

    var body: some View {
        ZStack {
            // Semi-transparent background
            if isPresented {
                Color.black.opacity(0.4)
                    .ignoresSafeArea()
                    .onTapGesture {
                        dismissSheet()
                    }
                    .transition(.opacity)
            }

            // Bottom sheet content
            VStack {
                Spacer()

                if isPresented {
                    sheetContent
                        .offset(y: max(0, dragOffset))
                        .gesture(
                            DragGesture()
                                .onChanged { value in
                                    // Only allow dragging down
                                    if value.translation.height > 0 {
                                        dragOffset = value.translation.height
                                    }
                                }
                                .onEnded { value in
                                    if value.translation.height > dismissThreshold {
                                        // Dismiss if dragged past threshold
                                        dismissSheet()
                                    }
                                    // Reset offset
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                        dragOffset = 0
                                    }
                                }
                        )
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .ignoresSafeArea(edges: .bottom)
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: isPresented)
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: supportedFileTypes,
            allowsMultipleSelection: false,
            onCompletion: handleFileImport
        )
        .sheet(isPresented: $showPhotoPicker) {
            ImagePicker { imageData, filename in
                handleImageSelected(imageData: imageData, filename: filename)
            }
        }
        .sheet(isPresented: $showTextInput) {
            TextInputView { inputData in
                print("🟢 [ImportSheetOverlay] Received TextInputData from TextInputView")
                Task {
                    await viewModel.uploadText(inputData.content)
                }
                onTextSubmit?(inputData)
                dismissSheet()
            }
        }
        .alert("Upload Error", isPresented: $showError) {
            Button("OK") {
                viewModel.error = nil
            }
        } message: {
            Text(viewModel.error ?? "Unknown error")
        }
        .alert("Upload Successful", isPresented: $showUploadSuccess) {
            Button("View in Library") {
                dismissSheet()
            }
        } message: {
            Text("Your file has been uploaded and is being processed. You can view the progress in your Library.")
        }
        .onChange(of: viewModel.error) { newValue in
            showError = newValue != nil
        }
    }

    private var sheetContent: some View {
        VStack(spacing: 0) {
            // Drag indicator
            RoundedRectangle(cornerRadius: 2.5)
                .fill(Color.gray.opacity(0.4))
                .frame(width: 36, height: 5)
                .padding(.top, 10)
                .padding(.bottom, 20)

            // Title
            Text("Add Content")
                .font(.headline)
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.bottom, 20)

            // Options
            VStack(spacing: 12) {
                ImportOptionButton(
                    icon: "doc.fill",
                    title: "Upload File",
                    subtitle: "PDF, EPUB, DOCX, TXT",
                    action: { showFilePicker = true }
                )

                ImportOptionButton(
                    icon: "camera.fill",
                    title: "Scan Text",
                    subtitle: "Import from photo",
                    action: { showPhotoPicker = true }
                )

                ImportOptionButton(
                    icon: "text.cursor",
                    title: "Input Text",
                    subtitle: "Paste or type content",
                    action: { showTextInput = true }
                )
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 50)
        }
        .frame(height: sheetHeight)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color(.systemBackground))
                .shadow(color: .black.opacity(0.15), radius: 10, y: -5)
        )
        .overlay(uploadingOverlay)
    }

    @ViewBuilder
    private var uploadingOverlay: some View {
        if viewModel.isUploading {
            RoundedRectangle(cornerRadius: 20)
                .fill(Color.black.opacity(0.3))
                .overlay(
                    VStack(spacing: 16) {
                        ProgressView()
                            .scaleEffect(1.5)
                        Text("Uploading...")
                            .font(.headline)
                    }
                    .padding(32)
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(Color(.systemBackground))
                    )
                )
        }
    }

    private func dismissSheet() {
        isPresented = false
        onDismiss?()
    }

    // MARK: - File Handling

    private var supportedFileTypes: [UTType] {
        var types: [UTType] = []
        if let pdf = UTType("com.adobe.pdf") {
            types.append(pdf)
        } else {
            types.append(.pdf)
        }
        types.append(.plainText)
        if let epub = UTType("org.idpf.epub-container") {
            types.append(epub)
        }
        if let docx = UTType("org.openxmlformats.wordprocessingml.document") {
            types.append(docx)
        }
        types.append(.data)
        types.append(.content)
        return types
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let filename = url.lastPathComponent.lowercased()
            let isEPUB = filename.hasSuffix(".epub")

            Task {
                await viewModel.uploadFile(url)

                if viewModel.uploadSuccess {
                    if isEPUB, let epubResult = viewModel.epubUploadResult {
                        onEPUBUploaded?(epubResult)
                        dismissSheet()
                    } else {
                        showUploadSuccess = true
                    }
                }
            }
        case .failure(let error):
            viewModel.error = error.localizedDescription
        }
    }

    private func handleImageSelected(imageData: Data, filename: String) {
        Task {
            await viewModel.uploadImage(imageData: imageData, filename: filename)
            if viewModel.uploadSuccess {
                showUploadSuccess = true
            }
        }
    }
}

// MARK: - Import Option Button (for half-screen sheet)
struct ImportOptionButton: View {
    let icon: String
    let title: String
    let subtitle: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundColor(AppTheme.primary)
                    .frame(width: 44, height: 44)
                    .background(AppTheme.primary.opacity(0.1))
                    .cornerRadius(10)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body)
                        .fontWeight(.medium)
                        .foregroundColor(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(.secondarySystemBackground))
            .cornerRadius(12)
        }
    }
}

// MARK: - Image Picker (PHPicker wrapper for iOS 15)
struct ImagePicker: UIViewControllerRepresentable {
    var onImageSelected: (Data, String) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 1

        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: ImagePicker

        init(_ parent: ImagePicker) {
            self.parent = parent
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)

            guard let result = results.first else { return }

            // Load image data
            if result.itemProvider.canLoadObject(ofClass: UIImage.self) {
                result.itemProvider.loadObject(ofClass: UIImage.self) { [weak self] object, error in
                    if let error = error {
                        print("📷 [ImagePicker] Error loading image: \(error)")
                        return
                    }

                    guard let image = object as? UIImage else {
                        print("📷 [ImagePicker] Failed to cast to UIImage")
                        return
                    }

                    // Convert to JPEG data
                    guard let imageData = image.jpegData(compressionQuality: 0.8) else {
                        print("📷 [ImagePicker] Failed to convert image to JPEG")
                        return
                    }

                    // Generate filename
                    let filename = "image_\(Int(Date().timeIntervalSince1970)).jpg"

                    print("📷 [ImagePicker] Image loaded: \(filename), size: \(imageData.count) bytes")

                    DispatchQueue.main.async {
                        self?.parent.onImageSelected(imageData, filename)
                    }
                }
            }
        }
    }
}
