//
//  StudyBoostView.swift
//  CastReader
//
//  Back-to-School 2026: a real, time-limited seven-study-day challenge.
//  The App Store event deep link, Home discovery card and persisted progress
//  all share the same source of truth in this file.
//

import Foundation
import SwiftUI

enum StudyBoostDeepLink {
    static func matches(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "castreader",
              url.host?.lowercased() == "study" else {
            return false
        }
        return url.path.isEmpty || url.path == "/"
    }
}

@MainActor
final class StudyBoostRouter: ObservableObject {
    static let shared = StudyBoostRouter()

    @Published private(set) var isPresented = false

    private init() {
        #if DEBUG
        isPresented = ProcessInfo.processInfo.arguments.contains("-CastReaderOpenStudyBoost")
        #endif
    }

    func open() {
        isPresented = true
    }

    func dismiss() {
        isPresented = false
    }
}

enum StudyBoostPhase: Equatable {
    case upcoming
    case active
    case completed
    case ended
}

struct StudyBoostCampaign {
    static let identifier = "back-to-school-2026"
    static let goalDays = 7

    /// The challenge is available for the whole local day on September 15.
    /// An exclusive September 16 boundary avoids ambiguous 23:59:59 logic.
    static func startDate(in calendar: Calendar) -> Date {
        campaignDate(year: 2026, month: 8, day: 18, in: calendar)
    }

    static func endDateExclusive(in calendar: Calendar) -> Date {
        campaignDate(year: 2026, month: 9, day: 16, in: calendar)
    }

    static func phase(
        at date: Date,
        completedDays: Int,
        calendar: Calendar
    ) -> StudyBoostPhase {
        if completedDays >= goalDays { return .completed }
        if date < startDate(in: calendar) { return .upcoming }
        if date < endDateExclusive(in: calendar) { return .active }
        return .ended
    }

    static func isDiscoverable(at date: Date, calendar: Calendar) -> Bool {
        date < endDateExclusive(in: calendar)
    }

    private static func campaignDate(
        year: Int,
        month: Int,
        day: Int,
        in calendar: Calendar
    ) -> Date {
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.year = year
        components.month = month
        components.day = day
        return calendar.date(from: components)!
    }
}

@MainActor
final class StudyBoostStore: ObservableObject {
    static let shared = StudyBoostStore()

    @Published private(set) var completedDayKeys: Set<String>

    private let defaults: UserDefaults
    private let calendar: Calendar
    private let now: () -> Date
    private let storageKey = "studyBoost.\(StudyBoostCampaign.identifier).completedDays.v1"

    init(
        defaults: UserDefaults = .standard,
        calendar: Calendar = .autoupdatingCurrent,
        now: @escaping () -> Date = Date.init
    ) {
        self.defaults = defaults
        self.calendar = calendar
        self.now = now
        completedDayKeys = Set(defaults.stringArray(forKey: storageKey) ?? [])
    }

    var completedDays: Int {
        min(completedDayKeys.count, StudyBoostCampaign.goalDays)
    }

    var progress: Double {
        Double(completedDays) / Double(StudyBoostCampaign.goalDays)
    }

    var phase: StudyBoostPhase {
        StudyBoostCampaign.phase(
            at: now(),
            completedDays: completedDays,
            calendar: calendar
        )
    }

    var isDiscoverable: Bool {
        StudyBoostCampaign.isDiscoverable(at: now(), calendar: calendar)
    }

    var isTodayComplete: Bool {
        completedDayKeys.contains(dayKey(for: now()))
    }

    /// Opening successfully imported material in the Study scenario completes
    /// one study day. Repeated imports on the same local day stay idempotent.
    @discardableResult
    func recordStudySession(at date: Date? = nil) -> Bool {
        let sessionDate = date ?? now()
        guard sessionDate >= StudyBoostCampaign.startDate(in: calendar),
              sessionDate < StudyBoostCampaign.endDateExclusive(in: calendar) else {
            return false
        }

        let key = dayKey(for: sessionDate)
        let inserted = completedDayKeys.insert(key).inserted
        guard inserted else { return false }
        defaults.set(completedDayKeys.sorted(), forKey: storageKey)
        return true
    }

    private func dayKey(for date: Date) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }
}

struct StudyBoostCopy: Equatable {
    let title: String
    let badge: String
    let subtitle: String
    let dateRange: String
    let progressTitle: String
    let progressRule: String
    let todayComplete: String
    let upcomingStatus: String
    let activeStatus: String
    let completedStatus: String
    let endedStatus: String
    let stepImportTitle: String
    let stepImportDetail: String
    let stepListenTitle: String
    let stepListenDetail: String
    let stepExplainTitle: String
    let stepExplainDetail: String
    let startCTA: String
    let previewCTA: String
    let continueCTA: String
    let close: String

    static let supportedLanguages: [AppLanguage] = [
        .english, .simplifiedChinese, .japanese, .spanish, .french,
        .german, .brazilianPortuguese, .italian, .hindi
    ]

    static func localized(
        for selectedLanguage: AppLanguage,
        locale: Locale = .autoupdatingCurrent
    ) -> StudyBoostCopy {
        switch resolvedLanguage(selectedLanguage, locale: locale) {
        case .simplifiedChinese:
            return .init(
                title: "开学季 · 学习加速", badge: "限时挑战",
                subtitle: "在 9 月 15 日前完成 7 个不同学习日",
                dateRange: "8 月 18 日 – 9 月 15 日",
                progressTitle: "你的学习日", progressRule: "每天打开一份学习材料，即计为 1 个学习日。",
                todayComplete: "今天的学习日已完成",
                upcomingStatus: "8 月 18 日开始；现在可以先体验学习模式。",
                activeStatus: "导入今天的材料，继续向 7 日目标前进。",
                completedStatus: "挑战完成！你已经达成 7 个学习日。",
                endedStatus: "本期挑战已结束，你仍可继续使用学习模式。",
                stepImportTitle: "导入学习材料", stepImportDetail: "支持文件、拍照、图片、网址和文本",
                stepListenTitle: "边听边看", stepListenDetail: "词级同步高亮帮你保持专注",
                stepExplainTitle: "弄懂难点", stepExplainDetail: "用 AI 解读概念并提炼重点",
                startCTA: "开始今天的学习", previewCTA: "体验学习模式", continueCTA: "继续学习", close: "关闭"
            )
        case .japanese:
            return .init(
                title: "新学期・学習ブースト", badge: "期間限定チャレンジ",
                subtitle: "9月15日までに別々の7日間学習しよう", dateRange: "8月18日〜9月15日",
                progressTitle: "学習した日", progressRule: "学習素材を開いた日は、1学習日として記録されます。",
                todayComplete: "今日の学習日は完了しました",
                upcomingStatus: "8月18日開始。今すぐ学習モードを試せます。",
                activeStatus: "今日の素材を読み込み、7日間の目標を進めましょう。",
                completedStatus: "達成！7日間の学習を完了しました。",
                endedStatus: "チャレンジは終了しましたが、学習モードは引き続き使えます。",
                stepImportTitle: "学習素材を読み込む", stepImportDetail: "ファイル、カメラ、画像、URL、テキストに対応",
                stepListenTitle: "見ながら聴く", stepListenDetail: "単語ごとの同期ハイライトで集中",
                stepExplainTitle: "難所を理解する", stepExplainDetail: "AI解説で概念と要点を整理",
                startCTA: "今日の学習を始める", previewCTA: "学習モードを試す", continueCTA: "学習を続ける", close: "閉じる"
            )
        case .spanish:
            return .init(
                title: "Impulso para la vuelta a clase", badge: "RETO POR TIEMPO LIMITADO",
                subtitle: "Estudia 7 días distintos hasta el 15 de septiembre", dateRange: "18 ago – 15 sep",
                progressTitle: "Tus días de estudio", progressRule: "Cada día que abras material de estudio cuenta una vez.",
                todayComplete: "El día de hoy ya está completado",
                upcomingStatus: "Empieza el 18 de agosto. Ya puedes probar el modo Estudio.",
                activeStatus: "Importa el material de hoy y avanza hacia los 7 días.",
                completedStatus: "¡Reto completado! Has alcanzado 7 días de estudio.",
                endedStatus: "El reto ha terminado, pero puedes seguir usando el modo Estudio.",
                stepImportTitle: "Importa material", stepImportDetail: "Archivos, cámara, imágenes, URL y texto",
                stepListenTitle: "Escucha y sigue", stepListenDetail: "Resaltado sincronizado palabra por palabra",
                stepExplainTitle: "Aclara lo difícil", stepExplainDetail: "Explicaciones con IA para conceptos clave",
                startCTA: "Empezar el estudio de hoy", previewCTA: "Probar modo Estudio", continueCTA: "Seguir estudiando", close: "Cerrar"
            )
        case .french:
            return .init(
                title: "Boost de rentrée", badge: "DÉFI À DURÉE LIMITÉE",
                subtitle: "Étudiez 7 jours différents d’ici au 15 septembre", dateRange: "18 août – 15 sept.",
                progressTitle: "Vos jours d’étude", progressRule: "Chaque jour où vous ouvrez un support compte une fois.",
                todayComplete: "La journée d’aujourd’hui est validée",
                upcomingStatus: "Début le 18 août. Vous pouvez déjà essayer le mode Étude.",
                activeStatus: "Importez le support du jour et progressez vers les 7 jours.",
                completedStatus: "Défi réussi ! Vous avez atteint 7 jours d’étude.",
                endedStatus: "Le défi est terminé, mais le mode Étude reste disponible.",
                stepImportTitle: "Importez vos supports", stepImportDetail: "Fichiers, appareil photo, images, URL et texte",
                stepListenTitle: "Écoutez et suivez", stepListenDetail: "Surlignage synchronisé mot par mot",
                stepExplainTitle: "Comprenez les difficultés", stepExplainDetail: "L’IA explique les notions et points clés",
                startCTA: "Commencer aujourd’hui", previewCTA: "Essayer le mode Étude", continueCTA: "Continuer à étudier", close: "Fermer"
            )
        case .german:
            return .init(
                title: "Lernboost zum Schulstart", badge: "ZEITLICH BEGRENZTE CHALLENGE",
                subtitle: "Lerne bis 15. September an 7 verschiedenen Tagen", dateRange: "18. Aug. – 15. Sept.",
                progressTitle: "Deine Lerntage", progressRule: "Jeder Tag mit geöffnetem Lernmaterial zählt einmal.",
                todayComplete: "Der heutige Lerntag ist geschafft",
                upcomingStatus: "Start am 18. August. Den Lernmodus kannst du jetzt testen.",
                activeStatus: "Importiere das heutige Material und komm deinem 7-Tage-Ziel näher.",
                completedStatus: "Geschafft! Du hast 7 Lerntage erreicht.",
                endedStatus: "Die Challenge ist vorbei, der Lernmodus bleibt verfügbar.",
                stepImportTitle: "Lernmaterial importieren", stepImportDetail: "Dateien, Kamera, Bilder, URLs und Text",
                stepListenTitle: "Hören und mitlesen", stepListenDetail: "Wortgenaue Hervorhebung hält dich fokussiert",
                stepExplainTitle: "Schwieriges verstehen", stepExplainDetail: "KI erklärt Begriffe und Kernaussagen",
                startCTA: "Heute lernen", previewCTA: "Lernmodus testen", continueCTA: "Weiterlernen", close: "Schließen"
            )
        case .brazilianPortuguese:
            return .init(
                title: "Impulso de volta às aulas", badge: "DESAFIO POR TEMPO LIMITADO",
                subtitle: "Estude em 7 dias diferentes até 15 de setembro", dateRange: "18 de ago. – 15 de set.",
                progressTitle: "Seus dias de estudo", progressRule: "Cada dia em que você abrir um material conta uma vez.",
                todayComplete: "O dia de estudo de hoje está concluído",
                upcomingStatus: "Começa em 18 de agosto. Você já pode testar o modo Estudo.",
                activeStatus: "Importe o material de hoje e avance rumo aos 7 dias.",
                completedStatus: "Desafio concluído! Você alcançou 7 dias de estudo.",
                endedStatus: "O desafio terminou, mas o modo Estudo continua disponível.",
                stepImportTitle: "Importe materiais", stepImportDetail: "Arquivos, câmera, imagens, URLs e texto",
                stepListenTitle: "Ouça e acompanhe", stepListenDetail: "Destaque sincronizado palavra por palavra",
                stepExplainTitle: "Entenda o difícil", stepExplainDetail: "A IA explica conceitos e pontos principais",
                startCTA: "Começar o estudo de hoje", previewCTA: "Testar modo Estudo", continueCTA: "Continuar estudando", close: "Fechar"
            )
        case .italian:
            return .init(
                title: "Sprint per il rientro", badge: "SFIDA A TEMPO LIMITATO",
                subtitle: "Studia in 7 giorni diversi entro il 15 settembre", dateRange: "18 ago – 15 set",
                progressTitle: "I tuoi giorni di studio", progressRule: "Ogni giorno in cui apri del materiale viene conteggiato una volta.",
                todayComplete: "Il giorno di studio di oggi è completato",
                upcomingStatus: "Inizia il 18 agosto. Puoi già provare la modalità Studio.",
                activeStatus: "Importa il materiale di oggi e avanza verso i 7 giorni.",
                completedStatus: "Sfida completata! Hai raggiunto 7 giorni di studio.",
                endedStatus: "La sfida è terminata, ma puoi continuare a usare la modalità Studio.",
                stepImportTitle: "Importa il materiale", stepImportDetail: "File, fotocamera, immagini, URL e testo",
                stepListenTitle: "Ascolta e segui", stepListenDetail: "Evidenziazione sincronizzata parola per parola",
                stepExplainTitle: "Capisci i passaggi difficili", stepExplainDetail: "L’IA spiega concetti e punti chiave",
                startCTA: "Inizia lo studio di oggi", previewCTA: "Prova modalità Studio", continueCTA: "Continua a studiare", close: "Chiudi"
            )
        case .hindi:
            return .init(
                title: "बैक-टू-स्कूल स्टडी बूस्ट", badge: "सीमित समय की चुनौती",
                subtitle: "15 सितंबर तक 7 अलग-अलग दिनों में पढ़ें", dateRange: "18 अगस्त – 15 सितंबर",
                progressTitle: "आपके पढ़ाई के दिन", progressRule: "जिस दिन आप अध्ययन सामग्री खोलते हैं, वह दिन एक बार गिना जाता है।",
                todayComplete: "आज का पढ़ाई का दिन पूरा हुआ",
                upcomingStatus: "18 अगस्त से शुरू। आप अभी स्टडी मोड आज़मा सकते हैं।",
                activeStatus: "आज की सामग्री इम्पोर्ट करें और 7 दिनों के लक्ष्य की ओर बढ़ें।",
                completedStatus: "चुनौती पूरी हुई! आपने पढ़ाई के 7 दिन पूरे किए।",
                endedStatus: "चुनौती समाप्त हो गई है, लेकिन स्टडी मोड उपलब्ध है।",
                stepImportTitle: "अध्ययन सामग्री इम्पोर्ट करें", stepImportDetail: "फ़ाइल, कैमरा, तस्वीर, URL और टेक्स्ट",
                stepListenTitle: "सुनें और साथ पढ़ें", stepListenDetail: "हर शब्द के साथ सिंक हाइलाइट",
                stepExplainTitle: "कठिन बातें समझें", stepExplainDetail: "AI से अवधारणाएँ और मुख्य बिंदु समझें",
                startCTA: "आज की पढ़ाई शुरू करें", previewCTA: "स्टडी मोड आज़माएँ", continueCTA: "पढ़ाई जारी रखें", close: "बंद करें"
            )
        case .english, .system:
            return .init(
                title: "Back-to-School Study Boost", badge: "LIMITED-TIME CHALLENGE",
                subtitle: "Study on 7 different days by September 15", dateRange: "Aug 18 – Sep 15",
                progressTitle: "Your study days", progressRule: "Each day you open study material counts once.",
                todayComplete: "Today’s study day is complete",
                upcomingStatus: "Starts August 18. You can preview Study mode now.",
                activeStatus: "Import today’s material and move closer to your 7-day goal.",
                completedStatus: "Challenge complete! You reached 7 study days.",
                endedStatus: "This challenge has ended, but Study mode is still available.",
                stepImportTitle: "Import study material", stepImportDetail: "Use files, camera, images, URLs, or text",
                stepListenTitle: "Listen and follow", stepListenDetail: "Stay focused with word-by-word highlights",
                stepExplainTitle: "Understand hard parts", stepExplainDetail: "Use AI explanations for concepts and key points",
                startCTA: "Start today’s study", previewCTA: "Preview Study mode", continueCTA: "Keep studying", close: "Close"
            )
        }
    }

    private static func resolvedLanguage(_ selection: AppLanguage, locale: Locale) -> AppLanguage {
        guard selection == .system else { return selection }
        let identifier = locale.identifier.lowercased()
        if identifier.hasPrefix("zh") { return .simplifiedChinese }
        if identifier.hasPrefix("ja") { return .japanese }
        if identifier.hasPrefix("es") { return .spanish }
        if identifier.hasPrefix("fr") { return .french }
        if identifier.hasPrefix("de") { return .german }
        if identifier.hasPrefix("pt") { return .brazilianPortuguese }
        if identifier.hasPrefix("it") { return .italian }
        if identifier.hasPrefix("hi") { return .hindi }
        return .english
    }
}

struct StudyBoostHomeCard: View {
    let onOpen: () -> Void

    @ObservedObject private var store = StudyBoostStore.shared
    @ObservedObject private var appLanguage = AppLanguageManager.shared

    private var copy: StudyBoostCopy {
        .localized(for: appLanguage.selectedLanguage, locale: appLanguage.locale)
    }

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.white.opacity(0.18))
                    Image(systemName: "graduationcap.fill")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(Color.white)
                }
                .frame(width: 54, height: 54)

                VStack(alignment: .leading, spacing: 5) {
                    Text(copy.badge)
                        .font(.caption2.weight(.bold))
                        .tracking(0.5)
                        .foregroundStyle(Color.white.opacity(0.84))
                    Text(copy.title)
                        .font(.headline)
                        .foregroundStyle(Color.white)
                        .lineLimit(2)
                    Text("\(store.completedDays)/\(StudyBoostCampaign.goalDays) · \(copy.dateRange)")
                        .font(.caption)
                        .foregroundStyle(Color.white.opacity(0.86))
                }

                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.white.opacity(0.9))
            }
            .padding(16)
            .background(
                LinearGradient(
                    colors: [AppTheme.primaryDark, AppTheme.primary],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(color: AppTheme.primary.opacity(0.18), radius: 16, y: 8)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("studyBoostHomeCard")
        .accessibilityLabel(Text("\(copy.title). \(copy.subtitle)"))
    }
}

struct StudyBoostView: View {
    let onStartStudy: () -> Void
    let onClose: () -> Void

    @ObservedObject private var store = StudyBoostStore.shared
    @ObservedObject private var appLanguage = AppLanguageManager.shared

    private var copy: StudyBoostCopy {
        .localized(for: appLanguage.selectedLanguage, locale: appLanguage.locale)
    }

    var body: some View {
        ZStack {
            AppTheme.background.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 20) {
                    hero
                    progressCard
                    stepsCard
                    primaryAction
                    Text(copy.progressRule)
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(AppTheme.mutedForeground)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 24)
                }
                .padding(.horizontal, 20)
                .padding(.top, 14)
            }
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .accessibilityIdentifier("studyBoostView")
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                Image(systemName: "graduationcap.fill")
                    .font(.system(size: 32, weight: .bold))
                    .foregroundStyle(Color.white)
                    .frame(width: 62, height: 62)
                    .background(Color.white.opacity(0.18))
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                Spacer()

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Color.white)
                        .frame(width: 38, height: 38)
                        .background(Color.black.opacity(0.16))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("studyBoostCloseButton")
                .accessibilityLabel(Text(copy.close))
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(copy.badge)
                    .font(.caption.weight(.bold))
                    .tracking(0.7)
                    .foregroundStyle(Color.white.opacity(0.82))
                Text(copy.title)
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .minimumScaleFactor(0.72)
                    .foregroundStyle(Color.white)
                Text(copy.subtitle)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color.white.opacity(0.94))
                Label(copy.dateRange, systemImage: "calendar")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.white.opacity(0.86))
            }
        }
        .padding(22)
        .background(
            LinearGradient(
                colors: [AppTheme.primaryDark, AppTheme.primary, AppTheme.primaryLight],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .shadow(color: AppTheme.primary.opacity(0.22), radius: 22, y: 10)
    }

    private var progressCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .firstTextBaseline) {
                Text(copy.progressTitle)
                    .font(.headline)
                    .foregroundStyle(AppTheme.foreground)
                Spacer()
                Text("\(store.completedDays)/\(StudyBoostCampaign.goalDays)")
                    .font(.title2.bold().monospacedDigit())
                    .foregroundStyle(AppTheme.primaryText)
            }

            ProgressView(value: store.progress)
                .tint(AppTheme.primary)
                .scaleEffect(x: 1, y: 1.8, anchor: .center)

            Label(statusText, systemImage: statusIcon)
                .font(.subheadline)
                .foregroundStyle(AppTheme.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)

            if store.isTodayComplete && store.phase != .upcoming {
                Label(copy.todayComplete, systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.primaryText)
            }
        }
        .padding(18)
        .background(AppTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(AppTheme.border.opacity(0.8), lineWidth: 1)
        }
        .accessibilityIdentifier("studyBoostProgressCard")
    }

    private var stepsCard: some View {
        VStack(spacing: 0) {
            stepRow(icon: "doc.badge.plus", title: copy.stepImportTitle, detail: copy.stepImportDetail)
            Divider().padding(.leading, 54)
            stepRow(icon: "text.word.spacing", title: copy.stepListenTitle, detail: copy.stepListenDetail)
            Divider().padding(.leading, 54)
            stepRow(icon: "sparkles", title: copy.stepExplainTitle, detail: copy.stepExplainDetail)
        }
        .padding(.horizontal, 16)
        .background(AppTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(AppTheme.border.opacity(0.8), lineWidth: 1)
        }
    }

    private func stepRow(icon: String, title: String, detail: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(AppTheme.primaryText)
                .frame(width: 38, height: 38)
                .background(AppTheme.primary.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.foreground)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(AppTheme.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 14)
    }

    private var primaryAction: some View {
        Button(action: onStartStudy) {
            HStack(spacing: 9) {
                Image(systemName: "arrow.up.doc.fill")
                Text(actionTitle)
                    .fontWeight(.semibold)
                Spacer()
                Image(systemName: "arrow.right")
            }
            .font(.headline)
            .foregroundStyle(AppTheme.primaryForeground)
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(AppTheme.primary)
            .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
            .shadow(color: AppTheme.primary.opacity(0.20), radius: 14, y: 7)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("studyBoostStartButton")
    }

    private var statusText: String {
        switch store.phase {
        case .upcoming: return copy.upcomingStatus
        case .active: return copy.activeStatus
        case .completed: return copy.completedStatus
        case .ended: return copy.endedStatus
        }
    }

    private var statusIcon: String {
        switch store.phase {
        case .upcoming: return "clock"
        case .active: return "flame.fill"
        case .completed: return "trophy.fill"
        case .ended: return "calendar.badge.checkmark"
        }
    }

    private var actionTitle: String {
        switch store.phase {
        case .upcoming: return copy.previewCTA
        case .active: return copy.startCTA
        case .completed, .ended: return copy.continueCTA
        }
    }
}
