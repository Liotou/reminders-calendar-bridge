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

    /// Le champ Notes d'un événement est du texte brut : Calendrier détecte les
    /// URL lui-même, elles ne peuvent donc pas se cacher derrière un libellé.
    /// À défaut, on les raccourcit — les huit premiers caractères d'un UUID
    /// suffisent amplement à désigner une tâche parmi celles d'une liste.
    static let tokenLength = 8

    static func token(_ taskID: String) -> String { String(taskID.prefix(tokenLength)) }

    func url(_ taskID: String) -> String {
        "\(Self.scheme)://\(rawValue)/\(Self.token(taskID))"
    }

    /// Lignes proposées pour un rappel donné : seule l'action pertinente au
    /// regard de son état est offerte.
    static func lines(for reminder: EKReminder) -> [String] {
        let id = reminder.calendarItemIdentifier
        var out: [String] = []
        if reminder.isCompleted {
            out.append(L.t("Rouvrir la tâche  \(TaskAction.reopen.url(id))",
                           "Reopen the task  \(TaskAction.reopen.url(id))"))
        } else {
            out.append(L.t("Marquer terminée  \(TaskAction.complete.url(id))",
                           "Mark as completed  \(TaskAction.complete.url(id))"))
        }
        // L'ouverture dans Rappels est déjà offerte par le champ « Lieu » ; on ne
        // la répète ici que sous sa forme courte.
        out.append(L.t("Ouvrir la tâche  \(TaskAction.open.url(id))",
                       "Open the task  \(TaskAction.open.url(id))"))
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
