import Foundation

/// Compose la description d'un événement en trois sections balisées :
///
///     ── Informations de la tâche ──   (régénérée à chaque passage)
///     ── Notes personnelles ──         (jamais touchée)
///     ── Statistiques ──               (régénérée à chaque passage)
///
/// Seule la section personnelle est préservée mot pour mot. Le texte libre
/// antérieur à toute section y est versé, pour ne rien perdre lors du premier
/// passage sur un événement déjà annoté à la main.
struct NotesComposer {
    let taskMarker: String
    let personalMarker: String
    let statsMarker: String

    func compose(existing: String,
                 taskInfo: [String]?,
                 stats: String?,
                 personalPlaceholder: String,
                 includePersonal: Bool,
                 carryFreeText: Bool) -> String {
        var personal = extract(section: personalMarker, from: existing)

        // Texte libre écrit avant toute section : on le récupère dans la section
        // personnelle plutôt que de le laisser être écrasé.
        if carryFreeText {
            let loose = freeText(from: existing)
            if !loose.isEmpty, !personal.contains(loose) {
                personal = personal.isEmpty ? loose : loose + "\n\n" + personal
            }
        }
        if personal.isEmpty { personal = personalPlaceholder }

        var blocks: [String] = []
        if let taskInfo, !taskInfo.isEmpty {
            blocks.append(([taskMarker] + taskInfo).joined(separator: "\n"))
        }
        if includePersonal {
            blocks.append(personal.isEmpty ? personalMarker : personalMarker + "\n" + personal)
        }
        if let stats, !stats.isEmpty {
            blocks.append(stats)
        }
        return blocks.joined(separator: "\n\n")
    }

    /// Contenu d'une section : entre son marqueur et le marqueur suivant.
    func extract(section marker: String, from text: String) -> String {
        guard !marker.isEmpty, let range = text.range(of: marker) else { return "" }
        let afterMarker = text[range.upperBound...]
        let others = [taskMarker, personalMarker, statsMarker].filter { $0 != marker && !$0.isEmpty }
        let end = others
            .compactMap { afterMarker.range(of: $0)?.lowerBound }
            .min() ?? afterMarker.endIndex
        return String(afterMarker[afterMarker.startIndex..<end])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Texte situé avant la première section connue.
    private func freeText(from text: String) -> String {
        let starts = [taskMarker, personalMarker, statsMarker]
            .filter { !$0.isEmpty }
            .compactMap { text.range(of: $0)?.lowerBound }
        guard let first = starts.min() else {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return String(text[text.startIndex..<first])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
