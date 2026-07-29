import Foundation
import EventKit

/// Restitution lisible des propriétés d'un rappel, pour les reporter dans la
/// description de l'événement. Seules les propriétés renseignées apparaissent.
enum ReminderDetails {

    static func lines(for reminder: EKReminder) -> [String] {
        var out: [String] = []

        append(&out, L.t("Liste", "List"), reminder.calendar?.title)

        // Rappels recopie l'échéance dans la date de début : n'afficher « Début »
        // que s'il porte réellement une autre information.
        let due = format(reminder.dueDateComponents)
        let begin = format(reminder.startDateComponents)
        append(&out, L.t("Échéance", "Due"), due)
        if begin != due { append(&out, L.t("Début", "Starts"), begin) }

        append(&out, L.t("Priorité", "Priority"), priority(reminder.priority))
        append(&out, L.t("Lieu", "Location"), reminder.location)
        append(&out, L.t("Lien", "Link"), reminder.url?.absoluteString)
        append(&out, L.t("Récurrence", "Repeats"), recurrence(reminder.recurrenceRules))
        append(&out, L.t("Alertes", "Alerts"), alarms(reminder.alarms))

        if reminder.isCompleted {
            append(&out, L.t("Terminée le", "Completed on"),
                   reminder.completionDate.map { dateTime.string(from: $0) } ?? L.t("oui", "yes"))
        }

        // En dernier : c'est la propriété la plus volumineuse, et la seule qui
        // puisse tenir sur plusieurs lignes.
        if let notes = reminder.notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
            let label = L.t("Commentaires", "Notes")
            out.append(notes.contains("\n") ? "\(label) :\n\(notes)" : "\(label) : \(notes)")
        }

        return out
    }

    /// Empreinte des propriétés reportées. Elle sert à repérer qu'un rappel a
    /// changé — titre, contenu, achèvement — pour remettre à jour tous les
    /// événements qui en dépendent.
    static func fingerprint(for reminder: EKReminder) -> String {
        var parts: [String] = [
            reminder.title ?? "",
            reminder.notes ?? "",
            reminder.calendar?.title ?? "",
            reminder.location ?? "",
            reminder.url?.absoluteString ?? "",
            String(reminder.priority),
            reminder.isCompleted ? "done" : "open",
            reminder.completionDate.map { String($0.timeIntervalSince1970) } ?? "",
            String(reminder.recurrenceRules?.count ?? 0),
            String(reminder.alarms?.count ?? 0),
        ]
        for components in [reminder.dueDateComponents, reminder.startDateComponents] {
            parts.append(components
                .flatMap { Calendar.current.date(from: $0) }
                .map { String($0.timeIntervalSince1970) } ?? "")
        }
        return parts.joined(separator: "\u{1}")
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
        case 1...4: L.t("haute", "high")
        case 5: L.t("moyenne", "medium")
        case 6...9: L.t("basse", "low")
        default: nil  // 0 = aucune
        }
    }

    private static func recurrence(_ rules: [EKRecurrenceRule]?) -> String? {
        guard let rule = rules?.first else { return nil }
        let unit: String = switch rule.frequency {
        case .daily: L.t("quotidienne", "daily")
        case .weekly: L.t("hebdomadaire", "weekly")
        case .monthly: L.t("mensuelle", "monthly")
        case .yearly: L.t("annuelle", "yearly")
        @unknown default: L.t("définie", "custom")
        }
        return rule.interval > 1
            ? unit + L.t(" (tous les \(rule.interval))", " (every \(rule.interval))")
            : unit
    }

    private static func alarms(_ alarms: [EKAlarm]?) -> String? {
        guard let alarms, !alarms.isEmpty else { return nil }
        let dates = alarms.compactMap { $0.absoluteDate }.map { dateTime.string(from: $0) }
        if !dates.isEmpty { return dates.joined(separator: ", ") }
        return alarms.count == 1
            ? L.t("1 alerte", "1 alert")
            : L.t("\(alarms.count) alertes", "\(alarms.count) alerts")
    }

    // Recréés à chaque usage : la langue peut changer en cours de session.
    private static var locale: Locale {
        Locale(identifier: L.current.resolved == .fr ? "fr_FR" : "en_US")
    }

    static var dayOnly: DateFormatter {
        let f = DateFormatter()
        f.locale = locale
        f.dateFormat = L.t("d MMMM yyyy", "MMMM d, yyyy")
        return f
    }

    static var dateTime: DateFormatter {
        let f = DateFormatter()
        f.locale = locale
        f.dateFormat = L.t("d MMMM yyyy 'à' HH:mm", "MMMM d, yyyy 'at' h:mm a")
        return f
    }
}
