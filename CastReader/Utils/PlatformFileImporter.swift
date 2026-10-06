import SwiftUI
import UniformTypeIdentifiers

extension View {
    /// Catalyst's SwiftUI importer opens in place and requests a read/write
    /// sandbox extension. Import a copy so our read-only entitlement suffices.
    @ViewBuilder
    func castReaderFileImporter(
        isPresented: Binding<Bool>,
        allowedContentTypes: [UTType],
        allowsMultipleSelection: Bool = false,
        onCompletion: @escaping (Result<[URL], Error>) -> Void
    ) -> some View {
        #if targetEnvironment(macCatalyst)
        modifier(MacFileImporterModifier(isPresented: isPresented, types: allowedContentTypes,
                                          multiple: allowsMultipleSelection, completion: onCompletion))
        #else
        fileImporter(isPresented: isPresented, allowedContentTypes: allowedContentTypes,
                     allowsMultipleSelection: allowsMultipleSelection, onCompletion: onCompletion)
        #endif
    }
}

#if targetEnvironment(macCatalyst)
private struct MacFileImporterModifier: ViewModifier {
    @Binding var isPresented: Bool
    let types: [UTType]
    let multiple: Bool
    let completion: (Result<[URL], Error>) -> Void
    // The native Open panel may dismiss the representable before delivering
    // its delegate callback. Keep its delegate in the presenting view's state.
    @StateObject private var delegate = MacFileImportDelegate()
    func body(content: Content) -> some View {
        content.sheet(isPresented: $isPresented) {
            MacFileImporter(types: types, multiple: multiple, delegate: delegate) { result in
                isPresented = false
                completion(result)
            }
        }
    }
}

private struct MacFileImporter: UIViewControllerRepresentable {
    let types: [UTType]
    let multiple: Bool
    let delegate: MacFileImportDelegate
    let completion: (Result<[URL], Error>) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        picker.allowsMultipleSelection = multiple
        delegate.completion = completion
        picker.delegate = delegate
        ReaderRunLog.write("IMPORT native picker created")
        return picker
    }
    func updateUIViewController(_ picker: UIDocumentPickerViewController, context: Context) {}
}

private final class MacFileImportDelegate: NSObject, ObservableObject, UIDocumentPickerDelegate {
    var completion: ((Result<[URL], Error>) -> Void)?
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        ReaderRunLog.write("IMPORT native picker selected count=\(urls.count)")
        finish(.success(urls))
    }
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        finish(.failure(CocoaError(.userCancelled)))
    }
    private func finish(_ result: Result<[URL], Error>) {
        let handler = completion
        completion = nil
        handler?(result)
    }
}
#endif
