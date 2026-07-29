import Foundation
import Observation

/// Les trois sections que peut porter la description d'un événement.
enum NoteSection: String, Codable, CaseIterable, Identifiable, Sendable {
    case taskInfo, personal, stats, actions

    var id: String { rawValue }

    var label: String {
        switch self {
        case .taskInfo: L.t("Informations de la tâche", "Task information")
        case .personal: L.t("Notes personnelles", "Personal notes")
        case .stats: L.t("Statistiques", "Statistics")
        case .actions: L.t("Actions", "Actions")
        }
    }

    var defaultMarker: String {
        switch self {
        case .taskInfo: L.t("── Informations de la tâche ──", "── Task information ──")
        case .personal: L.t("── Notes personnelles ──", "── Personal notes ──")
        case .stats: L.t("── Statistiques ──", "── Statistics ──")
        case .actions: L.t("── Actions ──", "── Actions ──")
        }
    }
}

/// Une section dans l'ordre voulu, activée ou non. L'ordre du tableau *est*
/// l'ordre d'écriture dans la description.
struct SectionSetting: Codable, Equatable, Identifiable, Sendable {
    var section: NoteSection
    var enabled: Bool = true
    var marker: String

    var id: NoteSection { section }

    init(_ section: NoteSection, enabled: Bool = true, marker: String? = nil) {
        self.section = section
        self.enabled = enabled
        self.marker = marker ?? section.defaultMarker
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        section = try c.decode(NoteSection.self, forKey: .section)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        marker = try c.decodeIfPresent(String.self, forKey: .marker) ?? section.defaultMarker
    }

    enum CodingKeys: String, CodingKey { case section, enabled, marker }
}

/// Association d'un calendrier et d'une liste de rappels, avec sa propre mise
/// en forme. Plusieurs associations coexistent : « Doctorat - Tâches » vers
/// « Sessions de travail », « Doctorat - Tâches de lecture » vers « Sessions de
/// lecture », etc.
struct Pairing: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var enabled = true
    var calendarName = ""
    /// Vide : aucun filtre, tous les événements du calendrier sont traités et
    /// regroupés sur leur propre titre.
    var reminderListName = ""

    var looseTitleMatch = true
    /// Préfixe apposé au titre de l'événement quand la tâche est terminée.
    var completedPrefix = "✅"
    /// Inscrit le lien du rappel dans le champ « Lieu ou appel vidéo » de
    /// l'événement : cliquable pour ouvrir la tâche, et identifiant durable.
    var linkReminderInLocation = true
    /// Même rôle, mais en fin de note. Redondant avec le lien dans le lieu ;
    /// utile si vous réservez ce champ à un vrai lieu.
    var embedTaskIdentifier = false

    var sections: [SectionSetting] = NoteSection.allCases.map { SectionSetting($0) }
    var personalPlaceholder = ""
    var preserveExistingNotes = true

    // Contenu du bloc de statistiques
    var showSessionNumber = true
    var showCurrentDuration = true
    var showPreviousTotal = true
    var showLastSessionDate = true
    var showGrandTotal = true

    var displayName: String {
        let list = reminderListName.isEmpty ? "toutes les entrées" : reminderListName
        let cal = calendarName.isEmpty ? "(aucun calendrier)" : calendarName
        return "\(list)  →  \(cal)"
    }

    init() {}

    /// Décodage tolérant, indispensable : le décodeur synthétisé par Swift
    /// n'applique pas les valeurs par défaut et échoue sur une clé absente —
    /// une seule propriété ajoutée invaliderait tout le réglage enregistré.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Pairing()
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        calendarName = try c.decodeIfPresent(String.self, forKey: .calendarName) ?? d.calendarName
        reminderListName = try c.decodeIfPresent(String.self, forKey: .reminderListName) ?? d.reminderListName
        looseTitleMatch = try c.decodeIfPresent(Bool.self, forKey: .looseTitleMatch) ?? d.looseTitleMatch
        completedPrefix = try c.decodeIfPresent(String.self, forKey: .completedPrefix) ?? d.completedPrefix
        embedTaskIdentifier = try c.decodeIfPresent(Bool.self, forKey: .embedTaskIdentifier) ?? d.embedTaskIdentifier
        linkReminderInLocation = try c.decodeIfPresent(Bool.self, forKey: .linkReminderInLocation) ?? d.linkReminderInLocation
        sections = try c.decodeIfPresent([SectionSetting].self, forKey: .sections) ?? d.sections
        personalPlaceholder = try c.decodeIfPresent(String.self, forKey: .personalPlaceholder) ?? d.personalPlaceholder
        preserveExistingNotes = try c.decodeIfPresent(Bool.self, forKey: .preserveExistingNotes) ?? d.preserveExistingNotes
        showSessionNumber = try c.decodeIfPresent(Bool.self, forKey: .showSessionNumber) ?? d.showSessionNumber
        showCurrentDuration = try c.decodeIfPresent(Bool.self, forKey: .showCurrentDuration) ?? d.showCurrentDuration
        showPreviousTotal = try c.decodeIfPresent(Bool.self, forKey: .showPreviousTotal) ?? d.showPreviousTotal
        showLastSessionDate = try c.decodeIfPresent(Bool.self, forKey: .showLastSessionDate) ?? d.showLastSessionDate
        showGrandTotal = try c.decodeIfPresent(Bool.self, forKey: .showGrandTotal) ?? d.showGrandTotal
        normalizeSections()
    }

    enum CodingKeys: String, CodingKey {
        case id, enabled, calendarName, reminderListName, looseTitleMatch
        case completedPrefix, embedTaskIdentifier, linkReminderInLocation
        case sections, personalPlaceholder
        case preserveExistingNotes, showSessionNumber, showCurrentDuration
        case showPreviousTotal, showLastSessionDate, showGrandTotal
    }

    func marker(for section: NoteSection) -> String {
        sections.first { $0.section == section }?.marker ?? section.defaultMarker
    }

    func isEnabled(_ section: NoteSection) -> Bool {
        sections.first { $0.section == section }?.enabled ?? false
    }

    /// Complète les sections manquantes (réglage écrit par une version
    /// antérieure) sans perdre l'ordre déjà choisi.
    mutating func normalizeSections() {
        for section in NoteSection.allCases where !sections.contains(where: { $0.section == section }) {
            sections.append(SectionSetting(section))
        }
        sections = sections.filter { NoteSection.allCases.contains($0.section) }
    }
}

struct Config: Codable, Equatable, Sendable {
    var enabled = true
    var detectionDays = 60
    var historyYears = 10
    var language: Language = .system
    var checkForUpdates = true
    var pairings: [Pairing] = []

    init() {}

    enum CodingKeys: String, CodingKey {
        case enabled, detectionDays, historyYears, pairings, language, checkForUpdates
        // Clés de l'ancien format, à couple unique.
        case calendarName, reminderListName, requireReminderMatch, looseTitleMatch
        case completedPrefix, embedTaskIdentifier, linkReminderInLocation
        case marker, taskInfoMarker, personalMarker
        case showTaskInfo, includePersonalSection, personalPlaceholder, preserveExistingNotes
        case showSessionNumber, showCurrentDuration, showPreviousTotal
        case showLastSessionDate, showGrandTotal
    }

    /// Décodage tolérant : une clé absente reprend sa valeur par défaut, et un
    /// réglage écrit par la version à couple unique est converti en une
    /// association.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        detectionDays = try c.decodeIfPresent(Int.self, forKey: .detectionDays) ?? d.detectionDays
        historyYears = try c.decodeIfPresent(Int.self, forKey: .historyYears) ?? d.historyYears
        language = try c.decodeIfPresent(Language.self, forKey: .language) ?? d.language
        checkForUpdates = try c.decodeIfPresent(Bool.self, forKey: .checkForUpdates) ?? d.checkForUpdates

        if let decoded = try c.decodeIfPresent([Pairing].self, forKey: .pairings) {
            pairings = decoded.map { var p = $0; p.normalizeSections(); return p }
            return
        }

        // Migration depuis l'ancien format.
        var p = Pairing()
        p.calendarName = try c.decodeIfPresent(String.self, forKey: .calendarName) ?? ""
        let requireMatch = try c.decodeIfPresent(Bool.self, forKey: .requireReminderMatch) ?? true
        let list = try c.decodeIfPresent(String.self, forKey: .reminderListName) ?? ""
        p.reminderListName = requireMatch ? list : ""
        p.looseTitleMatch = try c.decodeIfPresent(Bool.self, forKey: .looseTitleMatch) ?? p.looseTitleMatch
        p.completedPrefix = try c.decodeIfPresent(String.self, forKey: .completedPrefix) ?? p.completedPrefix
        p.embedTaskIdentifier = try c.decodeIfPresent(Bool.self, forKey: .embedTaskIdentifier) ?? p.embedTaskIdentifier
        p.linkReminderInLocation = try c.decodeIfPresent(Bool.self, forKey: .linkReminderInLocation) ?? p.linkReminderInLocation
        p.personalPlaceholder = try c.decodeIfPresent(String.self, forKey: .personalPlaceholder) ?? ""
        p.preserveExistingNotes = try c.decodeIfPresent(Bool.self, forKey: .preserveExistingNotes) ?? true
        p.showSessionNumber = try c.decodeIfPresent(Bool.self, forKey: .showSessionNumber) ?? true
        p.showCurrentDuration = try c.decodeIfPresent(Bool.self, forKey: .showCurrentDuration) ?? true
        p.showPreviousTotal = try c.decodeIfPresent(Bool.self, forKey: .showPreviousTotal) ?? true
        p.showLastSessionDate = try c.decodeIfPresent(Bool.self, forKey: .showLastSessionDate) ?? true
        p.showGrandTotal = try c.decodeIfPresent(Bool.self, forKey: .showGrandTotal) ?? true
        p.sections = [
            SectionSetting(.taskInfo,
                           enabled: try c.decodeIfPresent(Bool.self, forKey: .showTaskInfo) ?? true,
                           marker: try c.decodeIfPresent(String.self, forKey: .taskInfoMarker)),
            SectionSetting(.personal,
                           enabled: try c.decodeIfPresent(Bool.self, forKey: .includePersonalSection) ?? true,
                           marker: try c.decodeIfPresent(String.self, forKey: .personalMarker)),
            SectionSetting(.stats,
                           marker: try c.decodeIfPresent(String.self, forKey: .marker)),
        ]
        pairings = [p]
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(detectionDays, forKey: .detectionDays)
        try c.encode(historyYears, forKey: .historyYears)
        try c.encode(language, forKey: .language)
        try c.encode(checkForUpdates, forKey: .checkForUpdates)
        try c.encode(pairings, forKey: .pairings)
    }
}

@MainActor
@Observable
final class ConfigStore {
    static let shared = ConfigStore()

    private static let key = "config"

    var config: Config {
        didSet {
            guard config != oldValue else { return }
            L.current = config.language
            save()
            Engine.shared.configDidChange(config)
        }
    }

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode(Config.self, from: data) {
            config = decoded
        } else {
            config = Config()
        }
        L.current = config.language
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(config) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }
}
