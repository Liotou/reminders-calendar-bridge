import Foundation
import EventKit
import AppKit
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

    /// Retrouve un rappel depuis un identifiant complet ou depuis le jeton court
    /// des liens d'action. La recherche par préfixe se limite aux listes
    /// associées, ce qui rend une collision improbable et sans portée.
    private func findReminder(_ token: String) -> EKReminder? {
        if let exact = store.calendarItem(withIdentifier: token) as? EKReminder { return exact }

        let lists = store.calendars(for: .reminder).filter { calendar in
            config.pairings.contains { $0.enabled && $0.reminderListNames.contains(calendar.title) }
        }
        guard !lists.isEmpty else { return nil }

        var matches: [EKReminder] = []
        let semaphore = DispatchSemaphore(value: 0)
        store.fetchReminders(matching: store.predicateForReminders(in: lists)) { reminders in
            matches = (reminders ?? []).filter { $0.calendarItemIdentifier.hasPrefix(token) }
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 20)

        if matches.count > 1 {
            log(L.t("Jeton ambigu (\(token)) : \(matches.count) tâches correspondent.",
                    "Ambiguous token (\(token)): \(matches.count) tasks match."))
            return nil
        }
        return matches.first
    }

    /// Exécute un lien d'action cliqué depuis la description d'un événement.
    func perform(_ action: TaskAction, on taskID: String) {
        guard case .granted = reminderAccess else {
            log(L.t("Action ignorée : accès aux Rappels non accordé.",
                    "Action ignored: Reminders access not granted."))
            return
        }
        guard let reminder = findReminder(taskID) else {
            log(L.t("Action impossible : tâche introuvable (\(taskID)).",
                    "Action failed: task not found (\(taskID))."))
            return
        }

        switch action {
        case .open:
            if let url = URL(string: Self.reminderURL(reminder.calendarItemIdentifier)) {
                NSWorkspace.shared.open(url)
            }
            return
        case .complete, .reopen:
            reminder.isCompleted = (action == .complete)
        }

        do {
            try store.save(reminder, commit: true)
            log(action == .complete
                ? L.t("Tâche marquée terminée : « \(reminder.title ?? "") »",
                      "Task marked completed: “\(reminder.title ?? "")”")
                : L.t("Tâche rouverte : « \(reminder.title ?? "") »",
                      "Task reopened: “\(reminder.title ?? "")”"))
            // Les événements liés portent le marqueur d'achèvement et la section
            // d'actions : ils doivent être réécrits.
            scheduleScan(delay: 0.3)
        } catch {
            log(L.t("Échec de l'action : \(error.localizedDescription)",
                    "Action failed: \(error.localizedDescription)"))
        }
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

        // Toutes les tâches de toutes les listes surveillées, en une requête.
        // Cet index global est ce qui permet de reconnaître une tâche déposée
        // dans le mauvais calendrier, donc de la router vers le bon.
        let allListNames = Array(Set(active.flatMap(\.reminderListNames)))
        var allTasks: [TaskTitle] = []
        var tasksById: [String: TaskTitle] = [:]
        if !allListNames.isEmpty {
            // Triées du titre le plus long au plus court : en correspondance
            // souple, la tâche la plus spécifique doit l'emporter.
            allTasks = fetchTasks(listNames: allListNames, into: &result)
                .sorted { $0.normalized.count > $1.normalized.count }
            for task in allTasks { tasksById[task.id] = task }
        }

        // Quelle association possède quelle liste. Une liste rattachée à deux
        // calendriers différents n'a pas de destination évidente : on ne
        // déplacera rien dans ce cas plutôt que de trancher au hasard.
        var owner: [String: Pairing] = [:]
        var ambiguous: Set<String> = []
        for pairing in active {
            for name in pairing.reminderListNames {
                if let already = owner[name], already.calendarName != pairing.calendarName {
                    ambiguous.insert(name)
                } else {
                    owner[name] = pairing
                }
            }
        }
        for name in ambiguous.sorted() {
            result.messages.append(L.t("Liste « \(name) » rattachée à plusieurs calendriers : aucun rangement automatique.",
                                       "List “\(name)” is attached to several calendars: no automatic filing."))
        }

        var calendarsByTitle: [String: EKCalendar] = [:]
        for calendar in store.calendars(for: .event) { calendarsByTitle[calendar.title] = calendar }

        var pending: [(pairing: Pairing, events: [EKEvent])] = []
        for pairing in active {
            guard let calendar = calendarsByTitle[pairing.calendarName] else {
                result.messages.append(L.t("Calendrier « \(pairing.calendarName) » introuvable.",
                                           "Calendar “\(pairing.calendarName)” not found."))
                continue
            }
            pending.append((pairing, events(in: calendar,
                                            from: now.addingTimeInterval(-window),
                                            to: now.addingTimeInterval(window))))
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

        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let historyStart = now.addingTimeInterval(-Double(config.historyYears) * 365 * 86_400)
        var historyCache: [String: [EKEvent]] = [:]
        func history(of calendarName: String) -> [EKEvent] {
            if let cached = historyCache[calendarName] { return cached }
            guard let calendar = calendarsByTitle[calendarName] else { return [] }
            let fetched = events(in: calendar, from: historyStart, to: now.addingTimeInterval(window))
            historyCache[calendarName] = fetched
            return fetched
        }

        var written = 0
        var moved = 0
        for (pairing, calendarEvents) in pending {
            let ownTasks = allTasks.filter {
                pairing.reminderListNames.contains($0.reminder.calendar?.title ?? "")
            }

            for event in calendarEvents {
                guard let id = event.eventIdentifier else { continue }
                result.seen.append(id)

                // Rattachement à la tâche, du plus fiable au plus approximatif.
                // Le lien inscrit dans le lieu survit à un changement de titre du
                // rappel, ce que la comparaison de titres ne fait pas.
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
                        if !raw.isEmpty {
                            // Les tâches de l'association d'abord : un titre
                            // identique dans deux listes ne doit pas faire
                            // basculer un événement déjà bien rangé.
                            task = Self.matchTask(raw, among: ownTasks, loose: pairing.looseTitleMatch)
                                ?? Self.matchTask(raw, among: allTasks, loose: pairing.looseTitleMatch)
                        }
                    }
                }

                guard let task else {
                    if !pairing.reminderListNames.isEmpty,
                       state.records[id] == nil, !state.seen.contains(id) {
                        result.messages.append(L.t("Ignoré : « \(Self.firstLine(event.title)) » n'est une tâche d'aucune des listes : \(pairing.listsSummary).",
                                                   "Skipped: “\(Self.firstLine(event.title))” is not a task in any of: \(pairing.listsSummary)."))
                    }
                    continue
                }

                // Calendrier retient le dernier calendrier utilisé : un rappel
                // déposé à la suite d'un autre atterrit souvent au mauvais
                // endroit. On le range d'après la liste dont vient sa tâche.
                var effective = pairing
                let listName = task.reminder.calendar?.title ?? ""
                if config.fileEventsByList,
                   !pairing.reminderListNames.isEmpty,
                   !ambiguous.contains(listName),
                   let target = owner[listName],
                   target.calendarName != pairing.calendarName,
                   let destination = calendarsByTitle[target.calendarName] {
                    // Le déplacement doit être écrit seul : EventKit le traite
                    // comme un changement d'enregistrement, et le titre ou les
                    // notes modifiés dans la même sauvegarde sont perdus — la
                    // sauvegarde réussit pourtant, sans rien signaler.
                    event.calendar = destination
                    do {
                        try store.save(event, span: .thisEvent, commit: true)
                        effective = target
                        moved += 1
                        result.messages.append(L.t("Rangé dans « \(target.calendarName) » : « \(Self.firstLine(event.title)) » vient de \(listName).",
                                                   "Filed into “\(target.calendarName)”: “\(Self.firstLine(event.title))” comes from \(listName)."))
                    } catch {
                        result.messages.append(L.t("Rangement impossible vers « \(target.calendarName) » : \(error.localizedDescription)",
                                                   "Could not file into “\(target.calendarName)”: \(error.localizedDescription)"))
                    }
                }

                let formatStamp = effective.formatFingerprint + "\u{3}" + appVersion
                let fingerprint = ReminderDetails.fingerprint(for: task.reminder) + "\u{3}" + formatStamp
                let record = state.records[id]
                let isNew = record == nil && !state.seen.contains(id)
                let changed = record != nil && record?.fingerprint != fingerprint
                // Lien écrit par une version antérieure, avec le schéma que
                // macOS n'ouvre pas : il faut le remplacer.
                let staleLink = effective.linkReminderInLocation
                    && (event.location?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
                        .hasPrefix(Self.legacyReminderScheme)
                let relocated = effective.calendarName != pairing.calendarName

                guard isNew || changed || staleLink || relocated else {
                    result.records[id] = EventRecord(reminderId: task.id, fingerprint: fingerprint)
                    continue
                }

                if let message = annotate(event, task: task,
                                          history: history(of: effective.calendarName),
                                          records: state.records, pairing: effective) {
                    result.messages.append(message)
                    written += 1
                }
                // Le déplacement peut changer l'identifiant de l'événement.
                let finalID = event.eventIdentifier ?? id
                result.seen.append(finalID)
                result.records[finalID] = EventRecord(reminderId: task.id, fingerprint: fingerprint)
            }
        }

        if written > 0 || moved > 0 {
            var parts: [String] = []
            if written > 0 {
                parts.append(L.t("\(written) événement(s) mis à jour", "\(written) event(s) updated"))
            }
            if moved > 0 {
                parts.append(L.t("\(moved) rangé(s)", "\(moved) filed"))
            }
            result.summary = parts.joined(separator: ", ") + " — " + Self.timeFormatter.string(from: now)
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

    private nonisolated func fetchTasks(listNames: [String], into result: inout ScanResult) -> [TaskTitle] {
        let available = store.calendars(for: .reminder)
        let lists = listNames.compactMap { name in
            available.first { $0.title == name }
        }
        for missing in listNames where !available.contains(where: { $0.title == missing }) {
            result.messages.append(L.t("Liste de rappels « \(missing) » introuvable.",
                                       "Reminder list “\(missing)” not found."))
        }
        guard !lists.isEmpty else { return [] }

        var tasks: [TaskTitle] = []
        let semaphore = DispatchSemaphore(value: 0)
        store.fetchReminders(matching: store.predicateForReminders(in: lists)) { reminders in
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
        let actions = task.map { TaskAction.lines(for: $0.reminder) } ?? []
        var notes = NotesComposer(pairing: pairing)
            .compose(existing: Self.stripEmbeddedTaskID(event.notes ?? ""),
                     taskInfo: taskInfo, stats: stats, actions: actions)

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
