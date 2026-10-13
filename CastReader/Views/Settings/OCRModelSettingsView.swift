import SwiftUI

/// Explicit preparation before travelling/offline use; downloading a model never
/// changes the document's language or starts OCR/TTS on the user's content.
struct OCRModelSettingsView: View {
    @State private var ready: Set<String> = []
    @State private var active: String?
    @State private var failed: String?
    @State private var work: Task<Void, Never>?

    private var languages: [(SupportedTTSLanguage, String)] {
        let models = ["en": "eng", "zh": "chi_sim", "ja": "jpn", "es": "spa", "fr": "fra",
                      "de": "deu", "pt": "por", "it": "ita", "hi": "hin", "nl": "nld",
                      "ko": "kor", "ar": "ara", "ru": "rus", "pl": "pol", "sv": "swe",
                      "da": "dan", "nb": "nor", "fi": "fin", "cs": "ces", "el": "ell",
                      "hu": "hun", "fil": "fil", "he": "heb", "id": "ind", "ms": "msa",
                      "ro": "ron", "tr": "tur", "vi": "vie"]
        return SupportedTTSLanguage.currentServiceLanguages.compactMap { language in
            guard let model = models[language.rawValue], OCRModelCatalog.assets[model] != nil else { return nil }
            return (language, model)
        }
    }

    var body: some View {
        List {
            Section {
                Text("提前下载后，可离线识别图片。主应用和 Safari 共用语言文件。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                ForEach(languages, id: \.0.rawValue) { language, model in
                    row(language.nativeName, model: model)
                }
                if SupportedTTSLanguage.currentServiceLanguages.contains(.chinese) {
                    row("繁體中文", model: "chi_tra")
                }
            }
            if failed != nil {
                Section {
                    Text("语言文件下载失败，请联网重试。也可在设置中提前下载。")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(AppLocalized("识别语言文件"))
        .task {
            for model in OCRModelCatalog.assets.keys {
                if (try? await OCRModelStore.shared.cached(model)) != nil { ready.insert(model) }
            }
        }
        .onDisappear { work?.cancel() }
    }

    private func row(_ name: String, model: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(name)
                if let asset = OCRModelCatalog.assets[model] {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(asset.bytes), countStyle: .file))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if ready.contains(model) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    .accessibilityLabel(AppLocalized("可离线使用"))
                    .accessibilityIdentifier("ocrModelReady_" + model)
            } else if active == model {
                ProgressView().accessibilityLabel(AppLocalized("正在下载…"))
            } else {
                Button(AppLocalized(failed == model ? "重试" : "下载")) { prepare(model) }
                    .disabled(active != nil)
                    .accessibilityIdentifier("ocrModelDownload_" + model)
            }
        }
    }

    private func prepare(_ model: String) {
        active = model
        failed = nil
        work = Task {
            defer { active = nil }
            do {
                _ = try await OCRModelStore.shared.prepare(model, retry: true)
                try Task.checkCancellation()
                ready.insert(model)
            } catch is CancellationError { }
            catch { failed = model }
        }
    }
}
