import Foundation
import EventKit

/// Liens d'action inscrits dans la description de l'événement. Cliqués depuis
/// Calendrier, ils réveillent l'application, qui agit sur le rappel puis met à
/// jour les événements concernés.
///
/// Le schéma `rcb` est déclaré par l'application elle-même (`CFBundleURLTypes`
/// dans Info.plist). Rien ne sort de la machine.
enum TaskAction: String, CaseIterable {
    case complete, reopen, open

    static let scheme = "rcb"

    func url(_ taskID: String) -> String {
        "\(Self.scheme)://\(rawValue)/\(taskID)"
    }

    /// Lignes proposées pour un rappel donné : seule l'action pertinente au
    /// regard de son état est offerte.
    static func lines(for reminder: EKReminder) -> [String] {
        let id = reminder.calendarItemIdentifier
        var out: [String] = []
        if reminder.isCompleted {
            out.append(L.t("Rouvrir la tâche : \(TaskAction.reopen.url(id))",
                           "Reopen the task: \(TaskAction.reopen.url(id))"))
        } else {
            out.append(L.t("Marquer terminée : \(TaskAction.complete.url(id))",
                           "Mark as completed: \(TaskAction.complete.url(id))"))
        }
        out.append(L.t("Ouvrir dans Rappels : \(Engine.reminderURL(id))",
                       "Open in Reminders: \(Engine.reminderURL(id))"))
        return out
    }

    /// Décode `rcb://<action>/<identifiant>`.
    static func parse(_ url: URL) -> (action: TaskAction, taskID: String)? {
        guard url.scheme == scheme,
              let host = url.host,
              let action = TaskAction(rawValue: host) else { return nil }
        let id = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return id.isEmpty ? nil : (action, id)
    }
}
