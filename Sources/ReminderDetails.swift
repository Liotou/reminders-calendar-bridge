import Foundation
import EventKit

/// Restitution lisible des propriétés d'un rappel, pour les reporter dans la
/// description de l'événement. Seules les propriétés renseignées apparaissent.
enum ReminderDetails {

    static func lines(for reminder: EKReminder) -> [String] {
        var out: [String] = []

        append(&out, "Liste", reminder.calendar?.title)

        // Rappels recopie l'échéance dans la date de début : n'afficher « Début »
        // que s'il porte réellement une autre information.
        let due = format(reminder.dueDateComponents)
        let begin = format(reminder.startDateComponents)
        append(&out, "Échéance", due)
        if begin != due { append(&out, "Début", begin) }
        append(&out, "Priorité", priority(reminder.priority))
        append(&out, "Lieu", reminder.location)
        append(&out, "Lien", reminder.url?.absoluteString)
        append(&out, "Récurrence", recurrence(reminder.recurrenceRules))
        append(&out, "Alertes", alarms(reminder.alarms))

        if reminder.isCompleted {
            append(&out, "Terminée le", reminder.completionDate.map { dateTime.string(from: $0) } ?? "oui")
        }

        // En dernier : c'est la propriété la plus volumineuse, et la seule qui
        // puisse tenir sur plusieurs lignes.
        if let notes = reminder.notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
            out.append(notes.contains("\n") ? "Commentaires :\n\(notes)" : "Commentaires : \(notes)")
        }

        return out
    }

    // MARK: - Mise en forme

    private static func append(_ out: inout [String], _ label: String, _ value: String?) {
        guard let value, !value.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        out.append("\(label) : \(value)")
    }

    /// Une échéance sans composante horaire ne doit pas afficher « à 00:00 ».
    private static func format(_ components: DateComponents?) -> String? {
        guard let components, let date = Calendar.current.date(from: components) else { return nil }
        let hasTime = components.hour != nil || components.minute != nil
        return hasTime ? dateTime.string(from: date) : dayOnly.string(from: date)
    }

    private static func priority(_ value: Int) -> String? {
        switch value {
        case 1...4: "haute"
        case 5: "moyenne"
        case 6...9: "basse"
        default: nil  // 0 = aucune
        }
    }

    private static func recurrence(_ rules: [EKRecurrenceRule]?) -> String? {
        guard let rule = rules?.first else { return nil }
        let unit: String = switch rule.frequency {
        case .daily: "quotidienne"
        case .weekly: "hebdomadaire"
        case .monthly: "mensuelle"
        case .yearly: "annuelle"
        @unknown default: "définie"
        }
        return rule.interval > 1 ? "\(unit) (tous les \(rule.interval))" : unit
    }

    private static func alarms(_ alarms: [EKAlarm]?) -> String? {
        guard let alarms, !alarms.isEmpty else { return nil }
        let dates = alarms.compactMap { $0.absoluteDate }.map { dateTime.string(from: $0) }
        if !dates.isEmpty { return dates.joined(separator: ", ") }
        return alarms.count == 1 ? "1 alerte" : "\(alarms.count) alertes"
    }

    private static let dayOnly: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.dateFormat = "d MMMM yyyy"
        return f
    }()

    private static let dateTime: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.dateFormat = "d MMMM yyyy 'à' HH:mm"
        return f
    }()
}
