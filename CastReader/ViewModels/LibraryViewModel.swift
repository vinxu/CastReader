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

    private let visitorService: VisitorService

    init(visitorService: VisitorService = .shared) {
        self.visitorService = visitorService
    }

    func loadDocuments() async {
        print("📚 [LibraryViewModel] loadDocuments called")
        print("📚 [LibraryViewModel] visitorId: \(visitorService.visitorId)")
        isLoading = true
        error = nil

        do {
            documents = try await APIService.shared.fetchDocuments(userId: visitorService.visitorId)
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
