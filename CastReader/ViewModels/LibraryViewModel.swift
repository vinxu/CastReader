//
//  LibraryViewModel.swift
//  CastReader
//

import Foundation

@MainActor
class LibraryViewModel: ObservableObject {
    @Published var documents: [Document] = []
    @Published var isLoading = false
    @Published var error: String?

    func loadDocuments() async {
        print("📚 [LibraryViewModel] loadDocuments called")
        isLoading = true
        error = nil

        do {
            documents = try await APIService.shared.fetchDocuments()
            print("📚 [LibraryViewModel] Loaded \(documents.count) documents")
        } catch {
            print("📚 [LibraryViewModel] Error: \(error)")
            self.error = error.localizedDescription
        }

        isLoading = false
    }

    func refresh() async {
        await loadDocuments()
    }

    var savedDocuments: [Document] {
        documents.filter { $0.processingStatus == .completed }
    }

    var processingDocuments: [Document] {
        documents.filter { $0.processingStatus == .processing || $0.processingStatus == .pending }
    }

    var failedDocuments: [Document] {
        documents.filter { $0.processingStatus == .failed }
    }
}
