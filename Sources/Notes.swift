import Foundation

/// Compose la description d'un événement à partir de sections balisées, dans
/// l'ordre défini par l'association. Seule la section personnelle est préservée
/// mot pour mot ; les autres sont régénérées à chaque passage.
struct NotesComposer {
    let pairing: Pairing

    private var markers: [String] {
        pairing.sections.map(\.marker).filter { !$0.isEmpty }
    }

    func compose(existing: String, taskInfo: [String], stats: [String]) -> String {
        var personal = extract(section: .personal, from: existing)

        // Texte libre écrit avant toute section : on le récupère dans la section
        // personnelle plutôt que de le laisser être écrasé.
        if pairing.preserveExistingNotes {
            let loose = freeText(from: existing)
            if !loose.isEmpty, !personal.contains(loose) {
                personal = personal.isEmpty ? loose : loose + "\n\n" + personal
            }
        }
        if personal.isEmpty { personal = pairing.personalPlaceholder }

        var blocks: [String] = []
        for setting in pairing.sections where setting.enabled {
            let body: [String] = switch setting.section {
            case .taskInfo: taskInfo
            case .stats: stats
            case .personal: personal.isEmpty ? [] : [personal]
            }
            // Une section vide n'est écrite que si elle est personnelle : son
            // marqueur signale où écrire.
            guard !body.isEmpty || setting.section == .personal else { continue }
            blocks.append(([setting.marker] + body).joined(separator: "\n"))
        }
        return blocks.joined(separator: "\n\n")
    }

    /// Contenu d'une section : entre son marqueur et le marqueur suivant, quel
    /// que soit l'ordre dans lequel les sections ont été écrites.
    func extract(section: NoteSection, from text: String) -> String {
        let marker = pairing.marker(for: section)
        guard !marker.isEmpty, let range = text.range(of: marker) else { return "" }
        let after = text[range.upperBound...]
        let end = markers
            .filter { $0 != marker }
            .compactMap { after.range(of: $0)?.lowerBound }
            .min() ?? after.endIndex
        return String(after[after.startIndex..<end])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Texte situé avant la première section connue.
    private func freeText(from text: String) -> String {
        let starts = markers.compactMap { text.range(of: $0)?.lowerBound }
        guard let first = starts.min() else {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return String(text[text.startIndex..<first])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
