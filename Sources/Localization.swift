import Foundation

enum Language: String, Codable, CaseIterable, Identifiable, Sendable {
    case system, fr, en

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: L.t("Langue du système", "System language")
        case .fr: "Français"
        case .en: "English"
        }
    }

    /// Langue effective : `system` se résout sur les préférences du Mac, avec
    /// le français pour seule alternative à l'anglais.
    var resolved: Language {
        guard self == .system else { return self }
        let preferred = Locale.preferredLanguages.first ?? "en"
        return preferred.hasPrefix("fr") ? .fr : .en
    }
}

/// Traduction en ligne : chaque appel porte ses deux variantes. Sans catalogue
/// de chaînes ni fichiers de ressources — l'application est un binaire unique,
/// sans dossier `.lproj`.
enum L {
    /// Lue depuis plusieurs files : l'analyse compose des textes hors du thread
    /// principal. Écrite uniquement depuis l'interface, à chaque changement de
    /// réglage.
    nonisolated(unsafe) static var current: Language = .system

    static func t(_ fr: String, _ en: String) -> String {
        current.resolved == .fr ? fr : en
    }
}
