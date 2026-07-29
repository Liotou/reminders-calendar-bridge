import Foundation
import EventKit
import Observation

enum AccessState: Equatable {
    case unknown
    case granted
    case denied(String)
}

/// Lien durable entre un événement et la tâche dont il est issu, avec
/// l'empreinte des propriétés de celle-ci au moment de la dernière écriture.
struct EventRecord: Codable, Equatable {
    var reminderId: String
    var fingerprint: String
}

/// État persistant : événements déjà vus, et ce que l'on sait de leur tâche.
struct PersistedState: Codable {
    var bootstrapped = false
    /// Identifiants rencontrés, y compris ceux sans tâche associée.
    var seen: Set<String> = []
    var records: [String: EventRecord] = [:]

    enum CodingKeys: String, CodingKey {
        case bootstrapped, seen, records
        case ids  // ancien nom de `seen`
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bootstrapped = try c.decodeIfPresent(Bool.self, forKey: .bootstrapped) ?? false
        records = try c.decodeIfPresent([String: EventRecord].self, forKey: .records) ?? [:]
        if let s = try c.decodeIfPresent(Set<String>.self, forKey: .seen) {
            seen = s
        } else if let legacy = try c.decodeIfPresent([String].self, forKey: .ids) {
            seen = Set(legacy)
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(bootstrapped, forKey: .bootstrapped)
        try c.encode(seen, forKey: .seen)
        try c.encode(records, forKey: .records)
    }
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
        state = PersistedState()
        state.bootstrapped = true
        saveState()
        processedCount = 0
        log(L.t("Retraitement complet demandé.", "Full reprocess requested."))
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
        let stateSnapshot = state

        scanQueue.async { [weak self] in
            guard let self else { return }
            let result = self.performScan(config: snapshot, state: stateSnapshot)
            Task { @MainActor in
                self.state.bootstrapped = true
                self.state.seen.formUnion(result.seen)
                self.state.records.merge(result.records) { _, new in new }
                self.saveState()
                self.processedCount = self.state.seen.count
                self.lastScanDate = Date()
                self.isScanning = false
                for line in result.messages { self.log(line) }
                if let summary = result.summary { self.lastActivity = summary }
            }
        }
    }

    // MARK: - Analyse (hors thread principal)

    private struct ScanResult {
        var seen: [String] = []
        var records: [String: EventRecord] = [:]
        var messages: [String] = []
        var summary: String?
    }

    /// `predicateForEvents` ne couvre qu'environ quatre ans : au-delà, il ne
    /// renvoie rien du tout, silencieusement. On interroge donc par tranches,
    /// puis on dédoublonne les événements qui chevauchent une frontière.
    private nonisolated func events(in calendar: EKCalendar, from: Date, to: Date) -> [EKEvent] {
        let slice: TimeInterval = 3 * 365 * 86_400
        var collected: [EKEvent] = []
        var seen = Set<String>()
        var cursor = from
        while cursor < to {
            let end = min(cursor.addingTimeInterval(slice), to)
            let batch = store.events(matching: store.predicateForEvents(
                withStart: cursor, end: end, calendars: [calendar]))
            for event in batch {
                guard let id = event.eventIdentifier else { continue }
                if seen.insert(id).inserted { collected.append(event) }
            }
            cursor = end
        }
        return collected
    }

    private nonisolated func performScan(config: Config, state: PersistedState) -> ScanResult {
        var result = ScanResult()
        store.refreshSourcesIfNecessary()

        let now = Date()
        let window = Double(config.detectionDays) * 86_400
        let active = config.pairings.filter { $0.enabled && !$0.calendarName.isEmpty }
        guard !active.isEmpty else {
            result.messages.append(L.t("Aucune association active : rien à surveiller.",
                                       "No active pairing: nothing to watch."))
            result.summary = L.t("Aucune association active.", "No active pairing.")
            return result
        }

        // Chaque association est traitée séparément : son calendrier, sa liste,
        // sa mise en forme. Un même calendrier peut apparaître plusieurs fois.
        var pending: [(pairing: Pairing, calendar: EKCalendar, events: [EKEvent])] = []
        for pairing in active {
            guard let calendar = store.calendars(for: .event)
                .first(where: { $0.title == pairing.calendarName }) else {
                result.messages.append(L.t("Calendrier « \(pairing.calendarName) » introuvable.",
                                           "Calendar “\(pairing.calendarName)” not found."))
                continue
            }
            let events = self.events(in: calendar,
                                     from: now.addingTimeInterval(-window),
                                     to: now.addingTimeInterval(window))
            pending.append((pairing, calendar, events))
        }

        // Premier démarrage : on enregistre l'existant sans le modifier, pour ne
        // pas réécrire rétroactivement tout l'historique.
        guard state.bootstrapped else {
            result.seen = pending.flatMap { $0.events.compactMap(\.eventIdentifier) }
            result.messages.append(L.t("Initialisation : \(result.seen.count) événement(s) existant(s) marqués comme déjà vus.",
                                       "First run: \(result.seen.count) existing event(s) marked as already seen."))
            result.summary = L.t("Initialisé (\(result.seen.count) événements ignorés).",
                                 "Initialised (\(result.seen.count) events skipped).")
            return result
        }

        var written = 0
        for (pairing, calendar, events) in pending {
            var tasks: [TaskTitle] = []
            var tasksById: [String: TaskTitle] = [:]
            if !pairing.reminderListName.isEmpty {
                // Triés du plus long au plus court : en correspondance souple,
                // c'est le titre de tâche le plus spécifique qui doit l'emporter.
                tasks = fetchTasks(listName: pairing.reminderListName, into: &result)
                    .sorted { $0.normalized.count > $1.normalized.count }
                for task in tasks { tasksById[task.id] = task }
            }

            let historyStart = now.addingTimeInterval(-Double(config.historyYears) * 365 * 86_400)
            let history = self.events(in: calendar,
                                      from: historyStart,
                                      to: now.addingTimeInterval(window))

            for event in events {
                guard let id = event.eventIdentifier else { continue }
                result.seen.append(id)

                // Rattachement à la tâche, du plus fiable au plus approximatif :
                // l'identifiant inscrit dans la note survit à un changement de
                // titre du rappel, ce que la comparaison de titres ne fait pas.
                var task: TaskTitle?
                if !tasksById.isEmpty {
                    if let linked = Self.taskID(inLocation: event.location) {
                        task = tasksById[linked]
                    }
                    if task == nil, let embedded = Self.embeddedTaskID(in: event.notes) {
                        task = tasksById[embedded]
                    }
                    if task == nil, let cached = state.records[id]?.reminderId {
                        task = tasksById[cached]
                    }
                    if task == nil {
                        let raw = Self.matchable(event.title, pairing: pairing)
                        guard !raw.isEmpty,
                              let matched = Self.matchTask(raw, among: tasks, loose: pairing.looseTitleMatch) else {
                            if state.records[id] == nil && !state.seen.contains(id) {
                                result.messages.append(L.t("Ignoré : « \(Self.firstLine(event.title)) » n'est pas une tâche de \(pairing.reminderListName).",
                                                           "Skipped: “\(Self.firstLine(event.title))” is not a task in \(pairing.reminderListName)."))
                            }
                            continue
                        }
                        task = matched
                    }
                }

                let fingerprint = task.map { ReminderDetails.fingerprint(for: $0.reminder) } ?? ""
                let record = state.records[id]
                // Un événement est réécrit s'il est nouveau, ou si le rappel a
                // changé depuis la dernière fois — titre, contenu, achèvement.
                let isNew = record == nil && !state.seen.contains(id)
                let changed = record != nil && record?.fingerprint != fingerprint
                // Lien écrit par une version antérieure, avec le schéma que
                // macOS n'ouvre pas : il faut le remplacer.
                let staleLink = pairing.linkReminderInLocation && task != nil
                    && (event.location?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
                        .hasPrefix(Self.legacyReminderScheme)
                guard isNew || changed || staleLink else {
                    if let task { result.records[id] = EventRecord(reminderId: task.id, fingerprint: fingerprint) }
                    continue
                }

                if let message = annotate(event, task: task, history: history,
                                          records: state.records, pairing: pairing) {
                    result.messages.append(message)
                    written += 1
                }
                if let task { result.records[id] = EventRecord(reminderId: task.id, fingerprint: fingerprint) }
            }
        }

        if written > 0 {
            result.summary = L.t("\(written) événement(s) mis à jour — \(Self.timeFormatter.string(from: now))",
                                 "\(written) event(s) updated — \(Self.timeFormatter.string(from: now))")
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

    /// Titre normalisé d'un événement, débarrassé du marqueur d'achèvement pour
    /// que la comparaison avec la tâche reste possible.
    nonisolated static func matchable(_ title: String?, pairing: Pairing) -> String {
        var text = normalize(title)
        let mark = normalize(pairing.completedPrefix)
        if !mark.isEmpty, text.hasPrefix(mark) {
            text = String(text.dropFirst(mark.count)).trimmingCharacters(in: .whitespaces)
        }
        return text
    }

    /// Titre d'une tâche, sous ses deux formes : normalisée pour la comparaison,
    /// d'origine pour la réécriture du titre de l'événement.
    struct TaskTitle {
        let normalized: String
        let original: String
        let reminder: EKReminder

        var id: String { reminder.calendarItemIdentifier }
    }

    private nonisolated func fetchTasks(listName: String, into result: inout ScanResult) -> [TaskTitle] {
        guard let list = store.calendars(for: .reminder).first(where: { $0.title == listName }) else {
            result.messages.append(L.t("Liste de rappels « \(listName) » introuvable.",
                                       "Reminder list “\(listName)” not found."))
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

    // MARK: - Identifiant de tâche inscrit dans la note

    nonisolated private static let idPrefix = "⟦rcb:"
    nonisolated private static let idSuffix = "⟧"

    /// Schéma d'URL de Rappels. C'est `x-apple-reminderkit` qui est enregistré
    /// auprès de macOS — voir `CFBundleURLSchemes` dans Reminders.app. AppleScript
    /// renvoie de son côté des identifiants en `x-apple-reminder://`, que rien
    /// n'ouvre : cette forme n'est reconnue ici que pour relire les événements
    /// écrits par une version antérieure.
    nonisolated static let reminderScheme = "x-apple-reminderkit://REMCDReminder/"
    nonisolated static let legacyReminderScheme = "x-apple-reminder://"

    nonisolated static func reminderURL(_ id: String) -> String { reminderScheme + id }

    nonisolated static func taskID(inLocation location: String?) -> String? {
        guard let location else { return nil }
        let trimmed = location.trimmingCharacters(in: .whitespacesAndNewlines)
        for scheme in [reminderScheme, legacyReminderScheme] where trimmed.hasPrefix(scheme) {
            let id = String(trimmed.dropFirst(scheme.count))
            if !id.isEmpty { return id }
        }
        return nil
    }

    nonisolated static func embeddedTaskID(in notes: String?) -> String? {
        guard let notes,
              let start = notes.range(of: idPrefix, options: .backwards),
              let end = notes.range(of: idSuffix, range: start.upperBound..<notes.endIndex)
        else { return nil }
        return String(notes[start.upperBound..<end.lowerBound])
    }

    nonisolated static func stripEmbeddedTaskID(_ notes: String) -> String {
        guard let start = notes.range(of: idPrefix, options: .backwards),
              let end = notes.range(of: idSuffix, range: start.upperBound..<notes.endIndex)
        else { return notes }
        var text = notes
        text.removeSubrange(start.lowerBound..<end.upperBound)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Écriture

    private nonisolated func annotate(_ event: EKEvent, task: TaskTitle?, history: [EKEvent],
                                      records: [String: EventRecord], pairing: Pairing) -> String? {
        guard let start = event.startDate else { return nil }

        // Occurrences antérieures de la même tâche. Le rattachement par
        // identifiant prime : après un changement de titre du rappel, les
        // anciennes séances ne portent plus le même intitulé.
        let key = task.map { Self.matchable($0.original, pairing: pairing) }
            ?? Self.matchable(event.title, pairing: pairing)
        let loose = pairing.looseTitleMatch && task != nil
        let previous = history.filter { other in
            guard other.eventIdentifier != event.eventIdentifier,
                  (other.endDate ?? .distantPast) <= start else { return false }
            if let task {
                let otherID = Self.taskID(inLocation: other.location)
                    ?? Self.embeddedTaskID(in: other.notes)
                    ?? other.eventIdentifier.flatMap { records[$0]?.reminderId }
                if let otherID { return otherID == task.id }
            }
            let title = Self.matchable(other.title, pairing: pairing)
            return title == key || (loose && title.hasPrefix(key))
        }
        let previousTotal = previous.reduce(0.0) { sum, e in
            guard let s = e.startDate, let end = e.endDate else { return sum }
            return sum + end.timeIntervalSince(s)
        }
        let currentDuration = (event.endDate ?? start).timeIntervalSince(start)

        // Glisser-déposer d'un rappel sur le calendrier : macOS recopie la note
        // du rappel à la suite de son titre. Le titre est ramené à celui de la
        // tâche, précédé du marqueur d'achèvement si elle est terminée.
        var displayTitle = Self.firstLine(event.title)
        if let task {
            let done = task.reminder.isCompleted && !pairing.completedPrefix.isEmpty
            let wanted = (done ? pairing.completedPrefix + " " : "") + task.original
            if event.title != wanted { event.title = wanted }
            displayTitle = task.original
        }

        var stats: [String] = []
        if pairing.showSessionNumber {
            stats.append(L.t("Session n°\(previous.count + 1) — « \(displayTitle) »",
                             "Session #\(previous.count + 1) — “\(displayTitle)”"))
        }
        if pairing.showCurrentDuration {
            stats.append(L.t("Cette session : \(Self.formatDuration(currentDuration))",
                             "This session: \(Self.formatDuration(currentDuration))"))
        }
        if pairing.showPreviousTotal {
            stats.append(previous.isEmpty
                ? L.t("Aucune session antérieure.", "No earlier session.")
                : L.t("Sessions antérieures : \(previous.count) — \(Self.formatDuration(previousTotal))",
                      "Earlier sessions: \(previous.count) — \(Self.formatDuration(previousTotal))"))
        }
        if pairing.showLastSessionDate,
           let last = previous.max(by: { ($0.endDate ?? .distantPast) < ($1.endDate ?? .distantPast) }),
           let lastEnd = last.endDate {
            stats.append(L.t("Dernière séance : \(ReminderDetails.dayOnly.string(from: lastEnd))",
                             "Last session: \(ReminderDetails.dayOnly.string(from: lastEnd))"))
        }
        if pairing.showGrandTotal {
            stats.append(L.t("Cumul : \(Self.formatDuration(previousTotal + currentDuration))",
                             "Total: \(Self.formatDuration(previousTotal + currentDuration))"))
        }

        let taskInfo = task.map { ReminderDetails.lines(for: $0.reminder) } ?? []
        var notes = NotesComposer(pairing: pairing)
            .compose(existing: Self.stripEmbeddedTaskID(event.notes ?? ""),
                     taskInfo: taskInfo, stats: stats)

        // L'identifiant fermant la note relie durablement l'événement à sa
        // tâche, même si le titre de celle-ci change ensuite.
        if let task, pairing.embedTaskIdentifier {
            notes += "\n\n\(Self.idPrefix)\(task.id)\(Self.idSuffix)"
        }
        event.notes = notes

        // Le lien dans « Lieu ou appel vidéo » ouvre la tâche d'un clic et fait
        // office d'identifiant. On n'écrase jamais un lieu saisi à la main : ce
        // champ appartient d'abord à l'utilisateur.
        if let task, pairing.linkReminderInLocation {
            let existing = event.location?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if existing.isEmpty || Self.taskID(inLocation: existing) != nil {
                let link = Self.reminderURL(task.id)
                if existing != link { event.location = link }
            }
        }

        do {
            try store.save(event, span: .thisEvent, commit: true)
            return L.t("Écrit : « \(displayTitle) » — session n°\(previous.count + 1) sur \(history.count) événement(s) examiné(s)",
                       "Written: “\(displayTitle)” — session #\(previous.count + 1) across \(history.count) event(s) examined")
        } catch {
            return L.t("Échec sur « \(displayTitle) » : \(error.localizedDescription)",
                       "Failed on “\(displayTitle)”: \(error.localizedDescription)")
        }
    }

    // MARK: - État

    private func loadState() {
        if let data = try? Data(contentsOf: Self.stateURL),
           let decoded = try? JSONDecoder().decode(PersistedState.self, from: data) {
            state = decoded
            processedCount = decoded.seen.count
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
