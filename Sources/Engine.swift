import Foundation
import EventKit
import Observation

enum AccessState: Equatable {
    case unknown
    case granted
    case denied(String)
}

/// État persistant : quels événements ont déjà été enrichis.
private struct PersistedState: Codable {
    var bootstrapped = false
    var ids: [String] = []
}

@MainActor
@Observable
final class Engine {
    static let shared = Engine()

    // Exposé à l'interface
    private(set) var calendarAccess: AccessState = .unknown
    private(set) var reminderAccess: AccessState = .unknown
    private(set) var availableCalendars: [String] = []
    private(set) var availableReminderLists: [String] = []
    private(set) var lastActivity: String = "En attente du premier événement."
    private(set) var lastScanDate: Date?
    private(set) var processedCount: Int = 0
    private(set) var logLines: [String] = []
    private(set) var isScanning = false

    // Délibérément partagé entre le thread principal et la file d'analyse :
    // EKEventStore supporte cet usage, et l'analyse ne doit pas bloquer l'UI.
    nonisolated(unsafe) private let store = EKEventStore()
    private let scanQueue = DispatchQueue(label: "fr.equiriconi.bridge.scan")
    private var config = ConfigStore.shared.config
    private var state = PersistedState()
    private var observer: NSObjectProtocol?
    private var debounce: DispatchWorkItem?

    private static let appSupport = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support", isDirectory: true)
    static let supportDir = appSupport
        .appendingPathComponent("RemindersCalendarBridge", isDirectory: true)
    private static let stateURL = supportDir.appendingPathComponent("state.json")
    static let logURL = supportDir.appendingPathComponent("bridge.log")

    private init() {
        Self.migrateSupportDirectory()
        try? FileManager.default.createDirectory(at: Self.supportDir, withIntermediateDirectories: true)
        loadState()
    }

    /// L'application s'est appelée SessionsStats : on reprend son dossier plutôt
    /// que de repartir d'un état vide, ce qui ferait passer tous les événements
    /// existants pour de nouveaux.
    private static func migrateSupportDirectory() {
        let fm = FileManager.default
        let old = appSupport.appendingPathComponent("SessionsStats", isDirectory: true)
        guard fm.fileExists(atPath: old.path), !fm.fileExists(atPath: supportDir.path) else { return }
        try? fm.moveItem(at: old, to: supportDir)
        let oldLog = supportDir.appendingPathComponent("sessions-stats.log")
        if fm.fileExists(atPath: oldLog.path), !fm.fileExists(atPath: logURL.path) {
            try? fm.moveItem(at: oldLog, to: logURL)
        }
    }

    // MARK: - Cycle de vie

    func start() {
        log("Statut initial — Calendrier : \(EKEventStore.authorizationStatus(for: .event).rawValue), Rappels : \(EKEventStore.authorizationStatus(for: .reminder).rawValue) (0 notDetermined, 1 restricted, 2 denied, 3 authorized, 4 fullAccess)")
        store.requestFullAccessToEvents { [weak self] granted, error in
            Task { @MainActor in
                guard let self else { return }
                self.calendarAccess = granted
                    ? .granted
                    : .denied(error?.localizedDescription ?? "Accès refusé")
                self.log("Accès Calendrier : \(granted ? "accordé" : "refusé — \(error?.localizedDescription ?? "sans dialogue")")")
                if granted { self.refreshSources() }
                self.requestReminderAccess()
            }
        }
    }

    private func requestReminderAccess() {
        store.requestFullAccessToReminders { [weak self] granted, error in
            Task { @MainActor in
                guard let self else { return }
                self.reminderAccess = granted
                    ? .granted
                    : .denied(error?.localizedDescription ?? "Accès refusé")
                self.log("Accès Rappels : \(granted ? "accordé" : "refusé — \(error?.localizedDescription ?? "sans dialogue")")")
                if granted { self.refreshSources() }
                self.installObserver()
                self.scheduleScan(delay: 0.5)
            }
        }
    }

    private func installObserver() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: store,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.scheduleScan() }
        }
        log("Surveillance temps réel active (EKEventStoreChanged).")
    }

    func configDidChange(_ new: Config) {
        config = new
        refreshSources()
        scheduleScan(delay: 0.3)
    }

    func refreshSources() {
        availableCalendars = store.calendars(for: .event).map(\.title).sorted()
        availableReminderLists = store.calendars(for: .reminder).map(\.title).sorted()
        log("Sources visibles — calendriers : \(availableCalendars.count) \(availableCalendars), listes de rappels : \(availableReminderLists.count) \(availableReminderLists)")
    }

    // MARK: - Actions manuelles

    /// Oublie les événements traités sans rien réécrire : au prochain passage,
    /// l'existant est simplement réenregistré comme déjà vu.
    func forgetState() {
        state = PersistedState()
        saveState()
        processedCount = 0
        log("État réinitialisé. L'existant sera ignoré au prochain passage.")
        scheduleScan(delay: 0.3)
    }

    /// Réécrit le bloc de statistiques sur **tous** les événements du
    /// calendrier, y compris ceux déjà traités.
    func reprocessAll() {
        state = PersistedState(bootstrapped: true, ids: [])
        saveState()
        processedCount = 0
        log("Retraitement complet demandé.")
        scheduleScan(delay: 0.3)
    }

    func scanNow() {
        scheduleScan(delay: 0)
    }

    // MARK: - Planification

    /// Les modifications iCloud arrivent en rafale ; on les regroupe.
    private func scheduleScan(delay: TimeInterval = 2.0) {
        guard config.enabled, case .granted = calendarAccess else { return }
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.runScan() }
        }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func runScan() {
        guard !isScanning else { return }
        isScanning = true
        let snapshot = config
        let known = Set(state.ids)
        let bootstrapped = state.bootstrapped

        scanQueue.async { [weak self] in
            guard let self else { return }
            let result = self.performScan(config: snapshot, known: known, bootstrapped: bootstrapped)
            Task { @MainActor in
                self.state.bootstrapped = true
                self.state.ids = Array(known.union(result.handled))
                self.saveState()
                self.processedCount = self.state.ids.count
                self.lastScanDate = Date()
                self.isScanning = false
                for line in result.messages { self.log(line) }
                if let summary = result.summary { self.lastActivity = summary }
            }
        }
    }

    // MARK: - Analyse (hors thread principal)

    private struct ScanResult {
        var handled: [String] = []
        var messages: [String] = []
        var summary: String?
    }

    private nonisolated func performScan(config: Config, known: Set<String>, bootstrapped: Bool) -> ScanResult {
        var result = ScanResult()
        store.refreshSourcesIfNecessary()

        let now = Date()
        let window = Double(config.detectionDays) * 86_400
        let active = config.pairings.filter { $0.enabled && !$0.calendarName.isEmpty }
        guard !active.isEmpty else {
            result.messages.append("Aucune association active : rien à surveiller.")
            result.summary = "Aucune association active."
            return result
        }
        result.messages.append("Associations actives : \(active.map(\.displayName).joined(separator: " ; "))")

        // Chaque association est traitée séparément : son calendrier, sa liste,
        // sa mise en forme. Un même calendrier peut apparaître plusieurs fois.
        var enriched = 0
        var pending: [(pairing: Pairing, calendar: EKCalendar, events: [EKEvent])] = []
        for pairing in active {
            guard let calendar = store.calendars(for: .event)
                .first(where: { $0.title == pairing.calendarName }) else {
                result.messages.append("Calendrier « \(pairing.calendarName) » introuvable.")
                continue
            }
            let events = store.events(matching: store.predicateForEvents(
                withStart: now.addingTimeInterval(-window),
                end: now.addingTimeInterval(window),
                calendars: [calendar]))
            pending.append((pairing, calendar, events))
        }

        // Premier démarrage : on enregistre l'existant sans le modifier, pour ne
        // pas réécrire rétroactivement tout l'historique.
        guard bootstrapped else {
            result.handled = pending.flatMap { $0.events.compactMap(\.eventIdentifier) }
            result.messages.append("Initialisation : \(result.handled.count) événement(s) existant(s) marqués comme déjà vus.")
            result.summary = "Initialisé (\(result.handled.count) événements existants ignorés)."
            return result
        }

        for (pairing, calendar, events) in pending {
            let fresh = events.filter { event in
                guard let id = event.eventIdentifier else { return false }
                return !known.contains(id)
            }
            guard !fresh.isEmpty else { continue }

            // Triés du plus long au plus court : en correspondance souple, c'est
            // le titre de tâche le plus spécifique qui doit l'emporter.
            var taskTitles: [TaskTitle]?
            if !pairing.reminderListName.isEmpty {
                taskTitles = fetchTasks(listName: pairing.reminderListName, into: &result)
                    .sorted { $0.normalized.count > $1.normalized.count }
            }

            let historyStart = now.addingTimeInterval(-Double(config.historyYears) * 365 * 86_400)
            let history = store.events(matching: store.predicateForEvents(
                withStart: historyStart,
                end: now.addingTimeInterval(window),
                calendars: [calendar]))

            for event in fresh {
                guard let id = event.eventIdentifier else { continue }
                result.handled.append(id)

                let raw = Self.normalize(event.title)
                guard !raw.isEmpty else { continue }

                // Clé de regroupement : le titre de la tâche quand il y en a une,
                // pour que « Tâche » et « Tâche\n14/09/2026 » comptent ensemble.
                let key: String
                let canonicalTitle: String?
                let reminder: EKReminder?
                if let taskTitles {
                    guard let matched = Self.matchTask(raw, among: taskTitles, loose: pairing.looseTitleMatch) else {
                        result.messages.append("Ignoré : « \(Self.firstLine(event.title)) » n'est pas une tâche de \(pairing.reminderListName).")
                        continue
                    }
                    key = matched.normalized
                    canonicalTitle = matched.original
                    reminder = matched.reminder
                } else {
                    key = raw
                    canonicalTitle = nil
                    reminder = nil
                }

                if let message = annotate(event, key: key, canonicalTitle: canonicalTitle,
                                          reminder: reminder,
                                          loose: pairing.looseTitleMatch && canonicalTitle != nil,
                                          history: history, pairing: pairing) {
                    result.messages.append(message)
                    enriched += 1
                }
            }
        }

        if enriched > 0 {
            result.summary = "\(enriched) session(s) enrichie(s) — \(Self.timeFormatter.string(from: now))"
        }
        return result
    }

    /// Rapproche un titre d'événement d'un titre de tâche. En mode souple, le
    /// titre de l'événement peut porter un suffixe (une date recopiée, par
    /// exemple) ; le titre de tâche le plus long l'emporte.
    nonisolated static func matchTask(_ title: String, among tasks: [TaskTitle], loose: Bool) -> TaskTitle? {
        if let exact = tasks.first(where: { $0.normalized == title }) { return exact }
        guard loose else { return nil }
        return tasks.first { !$0.normalized.isEmpty && title.hasPrefix($0.normalized) }
    }

    /// Titre d'une tâche, sous ses deux formes : normalisée pour la comparaison,
    /// d'origine pour la réécriture du titre de l'événement.
    struct TaskTitle {
        let normalized: String
        let original: String
        let reminder: EKReminder
    }

    private nonisolated func fetchTasks(listName: String, into result: inout ScanResult) -> [TaskTitle] {
        guard let list = store.calendars(for: .reminder).first(where: { $0.title == listName }) else {
            result.messages.append("Liste de rappels « \(listName) » introuvable.")
            return []
        }
        var tasks: [TaskTitle] = []
        let semaphore = DispatchSemaphore(value: 0)
        store.fetchReminders(matching: store.predicateForReminders(in: [list])) { reminders in
            tasks = (reminders ?? []).map {
                TaskTitle(normalized: Self.normalize($0.title), original: $0.title ?? "", reminder: $0)
            }
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 20)
        return tasks
    }

    private nonisolated func annotate(_ event: EKEvent, key: String, canonicalTitle: String?,
                                      reminder: EKReminder?, loose: Bool,
                                      history: [EKEvent], pairing: Pairing) -> String? {
        guard let start = event.startDate else { return nil }

        // Occurrences antérieures : même tâche, terminées avant le début de la
        // session courante.
        let previous = history.filter { other in
            let title = Self.normalize(other.title)
            return other.eventIdentifier != event.eventIdentifier
                && (title == key || (loose && title.hasPrefix(key)))
                && (other.endDate ?? .distantPast) <= start
        }
        let previousTotal = previous.reduce(0.0) { sum, e in
            guard let s = e.startDate, let end = e.endDate else { return sum }
            return sum + end.timeIntervalSince(s)
        }
        let currentDuration = (event.endDate ?? start).timeIntervalSince(start)

        // Glisser-déposer d'un rappel sur le calendrier : macOS recopie la note
        // du rappel à la suite de son titre. Le titre est ramené à celui de la
        // tâche ; le contenu recopié n'est pas récupéré ici, il est reconstitué
        // proprement depuis les propriétés du rappel lui-même.
        if let canonicalTitle, !canonicalTitle.isEmpty, (event.title ?? "") != canonicalTitle {
            event.title = canonicalTitle
        }
        let displayTitle = canonicalTitle ?? Self.firstLine(event.title)

        var stats: [String] = []
        if pairing.showSessionNumber {
            stats.append("Session n°\(previous.count + 1) — « \(displayTitle) »")
        }
        if pairing.showCurrentDuration {
            stats.append("Cette session : \(Self.formatDuration(currentDuration))")
        }
        if pairing.showPreviousTotal {
            stats.append(previous.isEmpty
                ? "Aucune session antérieure."
                : "Sessions antérieures : \(previous.count) — \(Self.formatDuration(previousTotal))")
        }
        if pairing.showLastSessionDate,
           let last = previous.max(by: { ($0.endDate ?? .distantPast) < ($1.endDate ?? .distantPast) }),
           let lastEnd = last.endDate {
            stats.append("Dernière séance : \(Self.dayFormatter.string(from: lastEnd))")
        }
        if pairing.showGrandTotal {
            stats.append("Cumul : \(Self.formatDuration(previousTotal + currentDuration))")
        }

        let taskInfo = reminder.map { ReminderDetails.lines(for: $0) } ?? []
        event.notes = NotesComposer(pairing: pairing)
            .compose(existing: event.notes ?? "", taskInfo: taskInfo, stats: stats)

        do {
            try store.save(event, span: .thisEvent, commit: true)
            return "Enrichi : « \(event.title ?? "") » (session n°\(previous.count + 1))"
        } catch {
            return "Échec sur « \(event.title ?? "") » : \(error.localizedDescription)"
        }
    }

    // MARK: - État

    private func loadState() {
        if let data = try? Data(contentsOf: Self.stateURL),
           let decoded = try? JSONDecoder().decode(PersistedState.self, from: data) {
            state = decoded
            processedCount = decoded.ids.count
        }
    }

    private func saveState() {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: Self.stateURL, options: .atomic)
    }

    // MARK: - Journal

    func log(_ message: String) {
        let stamp = Self.timeFormatter.string(from: Date())
        let line = "\(stamp)  \(message)"
        logLines.append(line)
        if logLines.count > 200 { logLines.removeFirst(logLines.count - 200) }

        let fileLine = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
        if !FileManager.default.fileExists(atPath: Self.logURL.path) {
            FileManager.default.createFile(atPath: Self.logURL.path, contents: nil)
        }
        if let handle = try? FileHandle(forWritingTo: Self.logURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(fileLine.utf8))
        }
    }

    // MARK: - Formatage

    /// Rapprochement des titres : insensible à la casse, aux accents et aux
    /// espaces superflus.
    nonisolated static func normalize(_ title: String?) -> String {
        (title ?? "")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "fr_FR"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    nonisolated static func firstLine(_ text: String?) -> String {
        (text ?? "").split(separator: "\n", omittingEmptySubsequences: false)
            .first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
    }

    nonisolated static func formatDuration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours == 0 { return "\(minutes) min" }
        if minutes == 0 { return "\(hours) h" }
        return String(format: "%d h %02d", hours, minutes)
    }

    nonisolated static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.dateFormat = "d MMMM yyyy"
        return f
    }()

    nonisolated static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}
