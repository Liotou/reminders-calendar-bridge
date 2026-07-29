import Foundation
import Observation

/// Réglages de l'application, persistés en JSON dans les préférences utilisateur.
struct Config: Codable, Equatable {
    var enabled = true

    // Sources
    var calendarName = "Sessions de travail"
    var requireReminderMatch = true
    var reminderListName = "Doctorat - Tâches"
    /// Le titre de l'événement peut porter un suffixe après celui de la tâche
    /// (une date recopiée, par exemple). Le regroupement se fait alors sur le
    /// titre de la tâche.
    var looseTitleMatch = true
    /// Le glisser-déposer d'un rappel recopie sa note dans le titre de
    /// l'événement : on ramène le titre à celui de la tâche.
    var cleanEventTitle = true

    // Fenêtres d'analyse
    var detectionDays = 60
    var historyYears = 10

    // Sections de la description
    var marker = "── Statistiques ──"
    var taskInfoMarker = "── Informations de la tâche ──"
    var personalMarker = "── Notes personnelles ──"
    /// Reporte les propriétés du rappel (échéance, commentaires, priorité…).
    var showTaskInfo = true
    /// Section jamais réécrite, réservée à vos ajouts manuels.
    var includePersonalSection = true
    var personalPlaceholder = "(cette section n'est jamais réécrite)"

    // Mise en forme du bloc de statistiques
    var showSessionNumber = true
    var showCurrentDuration = true
    var showPreviousTotal = true
    var showLastSessionDate = true
    var showGrandTotal = true

    /// Si faux, le bloc écrase entièrement la description existante.
    var preserveExistingNotes = true

    enum CodingKeys: String, CodingKey {
        case enabled, calendarName, requireReminderMatch, reminderListName, looseTitleMatch
        case cleanEventTitle
        case taskInfoMarker, personalMarker, showTaskInfo, includePersonalSection, personalPlaceholder
        case detectionDays, historyYears, marker
        case showSessionNumber, showCurrentDuration, showPreviousTotal
        case showLastSessionDate, showGrandTotal, preserveExistingNotes
    }

    /// Décodage tolérant : une clé absente (réglage ajouté dans une version
    /// ultérieure) reprend sa valeur par défaut au lieu de faire échouer tout
    /// le chargement.
    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        calendarName = try c.decodeIfPresent(String.self, forKey: .calendarName) ?? d.calendarName
        requireReminderMatch = try c.decodeIfPresent(Bool.self, forKey: .requireReminderMatch) ?? d.requireReminderMatch
        reminderListName = try c.decodeIfPresent(String.self, forKey: .reminderListName) ?? d.reminderListName
        looseTitleMatch = try c.decodeIfPresent(Bool.self, forKey: .looseTitleMatch) ?? d.looseTitleMatch
        cleanEventTitle = try c.decodeIfPresent(Bool.self, forKey: .cleanEventTitle) ?? d.cleanEventTitle
        taskInfoMarker = try c.decodeIfPresent(String.self, forKey: .taskInfoMarker) ?? d.taskInfoMarker
        personalMarker = try c.decodeIfPresent(String.self, forKey: .personalMarker) ?? d.personalMarker
        showTaskInfo = try c.decodeIfPresent(Bool.self, forKey: .showTaskInfo) ?? d.showTaskInfo
        includePersonalSection = try c.decodeIfPresent(Bool.self, forKey: .includePersonalSection) ?? d.includePersonalSection
        personalPlaceholder = try c.decodeIfPresent(String.self, forKey: .personalPlaceholder) ?? d.personalPlaceholder
        detectionDays = try c.decodeIfPresent(Int.self, forKey: .detectionDays) ?? d.detectionDays
        historyYears = try c.decodeIfPresent(Int.self, forKey: .historyYears) ?? d.historyYears
        marker = try c.decodeIfPresent(String.self, forKey: .marker) ?? d.marker
        showSessionNumber = try c.decodeIfPresent(Bool.self, forKey: .showSessionNumber) ?? d.showSessionNumber
        showCurrentDuration = try c.decodeIfPresent(Bool.self, forKey: .showCurrentDuration) ?? d.showCurrentDuration
        showPreviousTotal = try c.decodeIfPresent(Bool.self, forKey: .showPreviousTotal) ?? d.showPreviousTotal
        showLastSessionDate = try c.decodeIfPresent(Bool.self, forKey: .showLastSessionDate) ?? d.showLastSessionDate
        showGrandTotal = try c.decodeIfPresent(Bool.self, forKey: .showGrandTotal) ?? d.showGrandTotal
        preserveExistingNotes = try c.decodeIfPresent(Bool.self, forKey: .preserveExistingNotes) ?? d.preserveExistingNotes
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
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(config) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }
}
