import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @State private var store = ConfigStore.shared
    @State private var engine = Engine.shared

    var body: some View {
        TabView {
            GeneralTab(store: store, engine: engine)
                .tabItem { Label(L.t("Général", "General"), systemImage: "gearshape") }
            PairingsTab(store: store, engine: engine)
                .tabItem { Label(L.t("Associations", "Pairings"), systemImage: "arrow.triangle.branch") }
            LogTab(engine: engine)
                .tabItem { Label(L.t("Journal", "Log"), systemImage: "list.bullet.rectangle") }
        }
        .frame(width: 700, height: 580)
        .onAppear {
            engine.refreshSources()
            Self.bringToFront()
        }
    }

    /// Sans icône dans le Dock (`LSUIElement`), l'application n'est pas activée
    /// quand sa fenêtre s'ouvre : celle-ci apparaît derrière l'application au
    /// premier plan. On active donc explicitement, une fois la fenêtre créée.
    private static func bringToFront() {
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.keyWindow?.makeKeyAndOrderFront(nil)
            NSApp.windows
                .first { $0.isVisible && $0.canBecomeKey }?
                .makeKeyAndOrderFront(nil)
        }
    }
}

// MARK: - Général

private struct GeneralTab: View {
    @Bindable var store: ConfigStore
    var engine: Engine
    @State private var updater = Updater.shared
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    @State private var confirmReprocess = false

    var body: some View {
        Form {
            Section {
                Toggle(L.t("Surveillance active", "Watching enabled"), isOn: $store.config.enabled)
                Toggle(L.t("Lancer au démarrage de la session", "Launch at login"), isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, wanted in setLaunchAtLogin(wanted) }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(Color.red)
                }
                Picker(L.t("Langue", "Language"), selection: $store.config.language) {
                    ForEach(Language.allCases) { Text($0.label).tag($0) }
                }
            }

            Section(L.t("Fenêtres d'analyse", "Analysis windows")) {
                Stepper(L.t("Détection : ±\(store.config.detectionDays) jours",
                            "Detection: ±\(store.config.detectionDays) days"),
                        value: $store.config.detectionDays, in: 1...365)
                Stepper(L.t("Historique pris en compte : \(store.config.historyYears) ans",
                            "History depth: \(store.config.historyYears) years"),
                        value: $store.config.historyYears, in: 1...30)
                Text(L.t("Communes à toutes les associations.", "Shared by every pairing."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(L.t("État", "Status")) {
                LabeledContent(L.t("Calendrier", "Calendar"), value: accessLabel(engine.calendarAccess))
                LabeledContent(L.t("Rappels", "Reminders"), value: accessLabel(engine.reminderAccess))
                LabeledContent(L.t("Événements suivis", "Tracked events"), value: "\(engine.processedCount)")
                LabeledContent(L.t("Dernière activité", "Last activity"), value: engine.lastActivity)
                HStack {
                    Button(L.t("Analyser maintenant", "Scan now")) { engine.scanNow() }
                    Button(L.t("Oublier l'état", "Forget state")) { engine.forgetState() }
                    Button(L.t("Retraiter tout l'historique", "Reprocess everything")) { confirmReprocess = true }
                }
            }

            Section(L.t("Mises à jour", "Updates")) {
                LabeledContent(L.t("Version installée", "Installed version"), value: updater.currentVersion)
                Toggle(L.t("Vérifier automatiquement", "Check automatically"),
                       isOn: $store.config.checkForUpdates)
                updateStatus
                HStack {
                    Button(L.t("Vérifier maintenant", "Check now")) { updater.check() }
                    if case .available = updater.state {
                        Button(L.t("Installer et relancer", "Install and relaunch")) { updater.install() }
                            .buttonStyle(.borderedProminent)
                    }
                    Link(L.t("Voir les publications", "View releases"), destination: Updater.releasesURL)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { updater.checkIfDue() }
        .confirmationDialog(L.t("Retraiter tout l'historique ?", "Reprocess everything?"),
                            isPresented: $confirmReprocess) {
            Button(L.t("Retraiter", "Reprocess"), role: .destructive) { engine.reprocessAll() }
            Button(L.t("Annuler", "Cancel"), role: .cancel) {}
        } message: {
            Text(L.t("Les sections « Informations de la tâche » et « Statistiques » seront réécrites sur tous les événements des calendriers associés, dans la fenêtre de détection. Les notes personnelles sont préservées.",
                     "The “Task information” and “Statistics” sections will be rewritten on every event of the paired calendars, within the detection window. Personal notes are preserved."))
        }
    }

    @ViewBuilder
    private var updateStatus: some View {
        switch updater.state {
        case .idle:
            EmptyView()
        case .checking:
            Text(L.t("Vérification en cours…", "Checking…")).font(.caption).foregroundStyle(.secondary)
        case .upToDate:
            Text(L.t("Vous disposez de la dernière version.", "You are up to date."))
                .font(.caption).foregroundStyle(.secondary)
        case .available(let version, _, let notes):
            VStack(alignment: .leading, spacing: 2) {
                Text(L.t("Version \(version) disponible.", "Version \(version) available."))
                    .font(.caption).bold()
                if !notes.isEmpty {
                    Text(notes).font(.caption).foregroundStyle(.secondary).lineLimit(4)
                }
            }
        case .installing:
            Text(L.t("Téléchargement et installation…", "Downloading and installing…"))
                .font(.caption).foregroundStyle(.secondary)
        case .failed(let reason):
            Text(reason).font(.caption).foregroundStyle(Color.red)
        }
    }

    private func accessLabel(_ state: AccessState) -> String {
        switch state {
        case .unknown: L.t("en attente", "pending")
        case .granted: L.t("accordé", "granted")
        case .denied(let reason): L.t("refusé — \(reason)", "denied — \(reason)")
        }
    }

    private func setLaunchAtLogin(_ wanted: Bool) {
        do {
            if wanted {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginError = nil
        } catch {
            loginError = error.localizedDescription
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

// MARK: - Associations

private struct PairingsTab: View {
    @Bindable var store: ConfigStore
    var engine: Engine
    @State private var selection: Pairing.ID?

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach($store.config.pairings) { $pairing in
                        HStack {
                            Toggle("", isOn: $pairing.enabled)
                                .labelsHidden()
                                .toggleStyle(.checkbox)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(pairing.listsSummary)
                                    .lineLimit(1)
                                Text(pairing.calendarName.isEmpty
                                     ? L.t("(aucun calendrier)", "(no calendar)") : pairing.calendarName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .tag(pairing.id)
                    }
                    .onMove { store.config.pairings.move(fromOffsets: $0, toOffset: $1) }
                }

                HStack(spacing: 4) {
                    Button {
                        var new = Pairing()
                        new.calendarName = engine.availableCalendars.first ?? ""
                        new.reminderListNames = engine.availableReminderLists.prefix(1).map { $0 }
                        store.config.pairings.append(new)
                        selection = new.id
                    } label: { Image(systemName: "plus") }

                    Button {
                        store.config.pairings.removeAll { $0.id == selection }
                        selection = store.config.pairings.first?.id
                    } label: { Image(systemName: "minus") }
                        .disabled(selection == nil)
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(6)
            }
            .frame(minWidth: 200, idealWidth: 230, maxWidth: 300)

            Group {
                if let index = store.config.pairings.firstIndex(where: { $0.id == selection }) {
                    PairingDetail(pairing: $store.config.pairings[index], engine: engine)
                } else {
                    ContentUnavailableView(
                        L.t("Aucune association sélectionnée", "No pairing selected"),
                        systemImage: "arrow.triangle.branch",
                        description: Text(L.t("Chaque association relie une liste de rappels à un calendrier, avec sa propre mise en forme.",
                                              "Each pairing links a reminder list to a calendar, with its own formatting.")))
                }
            }
            .frame(minWidth: 380)
        }
        .onAppear { if selection == nil { selection = store.config.pairings.first?.id } }
    }
}

private struct PairingDetail: View {
    @Binding var pairing: Pairing
    var engine: Engine

    var body: some View {
        Form {
            Section(L.t("Sources", "Sources")) {
                LabeledContent(L.t("Listes de rappels", "Reminder lists")) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(options(engine.availableReminderLists, pairing.reminderListNames), id: \.self) { name in
                            Toggle(name, isOn: Binding(
                                get: { pairing.reminderListNames.contains(name) },
                                set: { on in
                                    if on {
                                        if !pairing.reminderListNames.contains(name) {
                                            pairing.reminderListNames.append(name)
                                        }
                                    } else {
                                        pairing.reminderListNames.removeAll { $0 == name }
                                    }
                                }))
                        }
                    }
                }
                Text(pairing.reminderListNames.isEmpty
                     ? L.t("Aucune liste cochée : tous les événements du calendrier sont traités et regroupés sur leur propre titre.",
                           "No list ticked: every event of the calendar is processed and grouped on its own title.")
                     : L.t("Plusieurs listes peuvent alimenter le même calendrier. La liste d'appartenance de chaque tâche figure dans la section « Informations de la tâche ».",
                           "Several lists may feed the same calendar. Each task's own list appears in the “Task information” section."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker(L.t("Calendrier", "Calendar"), selection: $pairing.calendarName) {
                    ForEach(options(engine.availableCalendars, pairing.calendarName), id: \.self) {
                        Text($0).tag($0)
                    }
                }
                Toggle(L.t("Tolérer un suffixe après le titre de la tâche",
                           "Allow a suffix after the task title"),
                       isOn: $pairing.looseTitleMatch)
                    .disabled(pairing.reminderListNames.isEmpty)
                Text(L.t("Le glisser-déposer d'un rappel ajoute sa note au titre. Le titre de l'événement est ensuite ramené à celui de la tâche.",
                         "Dragging a reminder appends its notes to the title. The event title is then reduced to the task title."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(L.t("Suivi de la tâche", "Task tracking")) {
                Toggle(L.t("Lien vers le rappel dans « Lieu ou appel vidéo »",
                           "Link to the reminder in “Location or Video Call”"),
                       isOn: $pairing.linkReminderInLocation)
                    .disabled(pairing.reminderListNames.isEmpty)
                Text(L.t("Cliquable pour ouvrir la tâche dans Rappels, et fait office d'identifiant durable. Un lieu saisi à la main n'est jamais écrasé.",
                         "Clickable to open the task in Reminders, and doubles as a durable identifier. A location you typed yourself is never overwritten."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle(L.t("Inscrire aussi l'identifiant en fin de note",
                           "Also write the identifier at the end of the notes"),
                       isOn: $pairing.embedTaskIdentifier)
                    .disabled(pairing.reminderListNames.isEmpty)
                Text(L.t("Redondant avec le lien ci-dessus. Utile si vous réservez le champ « Lieu » à un véritable lieu.",
                         "Redundant with the link above. Useful if you keep the location field for an actual place."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField(L.t("Marqueur de tâche terminée", "Completed task marker"),
                          text: $pairing.completedPrefix)
                Text(L.t("Apposé devant le titre des événements dès que la tâche est cochée dans Rappels. Laissez vide pour ne rien ajouter.",
                         "Prepended to event titles as soon as the task is ticked in Reminders. Leave empty to add nothing."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(L.t("Sections de la description", "Description sections")) {
                // Ces lignes sont déplaçables : sur macOS, toute la ligne est la
                // poignée de glissement. On n'y met donc aucun champ de saisie,
                // que le geste de glissement rendrait inutilisable.
                List {
                    ForEach($pairing.sections) { $setting in
                        HStack(spacing: 8) {
                            Image(systemName: "line.3.horizontal")
                                .foregroundStyle(.tertiary)
                            Toggle(setting.section.label, isOn: $setting.enabled)
                            Spacer()
                        }
                    }
                    .onMove { pairing.sections.move(fromOffsets: $0, toOffset: $1) }
                }
                .frame(height: 124)
                .listStyle(.plain)
                Text(L.t("Glissez les lignes pour changer l'ordre. La section « Notes personnelles » n'est jamais réécrite.",
                         "Drag rows to reorder. The “Personal notes” section is never rewritten."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(L.t("Lignes de séparation", "Section headers")) {
                ForEach($pairing.sections) { $setting in
                    TextField(setting.section.label, text: $setting.marker)
                }
                Text(L.t("Elles délimitent les sections dans la description. Les modifier après coup empêche de retrouver celles déjà écrites dans les événements existants.",
                         "They delimit the sections. Changing them afterwards prevents already written sections from being found in existing events."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField(L.t("Texte initial des notes personnelles", "Initial text of personal notes"),
                          text: $pairing.personalPlaceholder)
            }

            Section(L.t("Statistiques", "Statistics")) {
                Toggle(L.t("Numéro de session", "Session number"), isOn: $pairing.showSessionNumber)
                Toggle(L.t("Durée de la session courante", "Current session duration"), isOn: $pairing.showCurrentDuration)
                Toggle(L.t("Nombre et durée des sessions antérieures", "Count and duration of earlier sessions"), isOn: $pairing.showPreviousTotal)
                Toggle(L.t("Date de la dernière séance", "Date of the last session"), isOn: $pairing.showLastSessionDate)
                Toggle(L.t("Cumul total", "Grand total"), isOn: $pairing.showGrandTotal)
                Toggle(L.t("Conserver le texte libre existant", "Keep existing free text"), isOn: $pairing.preserveExistingNotes)
            }

            Section(L.t("Aperçu", "Preview")) {
                Text(preview)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
    }

    /// Garantit que la valeur enregistrée reste sélectionnable même si le
    /// calendrier ou la liste n'existe plus.
    private func options(_ available: [String], _ current: String) -> [String] {
        available.contains(current) || current.isEmpty ? available : ([current] + available)
    }

    /// Les listes enregistrées mais disparues restent affichées, pour que leur
    /// retrait soit un geste délibéré plutôt qu'un effet de bord.
    private func options(_ available: [String], _ current: [String]) -> [String] {
        available + current.filter { !available.contains($0) }
    }

    private var preview: String {
        var taskInfo: [String] = []
        if !pairing.reminderListNames.isEmpty {
            taskInfo = ["\(L.t("Liste", "List")) : \(pairing.reminderListNames.first ?? "")",
                        "\(L.t("Échéance", "Due")) : \(L.t("14 septembre 2026", "September 14, 2026"))",
                        "\(L.t("Priorité", "Priority")) : \(L.t("haute", "high"))",
                        "\(L.t("Commentaires", "Notes")) : \(L.t("voir le compte rendu du 3 juillet", "see the July 3 minutes"))"]
        }
        var actions: [String] = []
        if !pairing.reminderListNames.isEmpty {
            actions = [L.t("Marquer terminée  rcb://complete/5C1FA93B",
                           "Mark as completed  rcb://complete/5C1FA93B"),
                       L.t("Ouvrir la tâche  rcb://open/5C1FA93B",
                           "Open the task  rcb://open/5C1FA93B")]
        }
        var stats: [String] = []
        let title = L.t("Rédaction chapitre 2", "Writing chapter 2")
        if pairing.showSessionNumber { stats.append(L.t("Session n°8 — « \(title) »", "Session #8 — “\(title)”")) }
        if pairing.showCurrentDuration { stats.append(L.t("Cette session : 2 h 30", "This session: 2 h 30")) }
        if pairing.showPreviousTotal { stats.append(L.t("Sessions antérieures : 7 — 14 h 15", "Earlier sessions: 7 — 14 h 15")) }
        if pairing.showLastSessionDate { stats.append(L.t("Dernière séance : 22 juillet 2026", "Last session: July 22, 2026")) }
        if pairing.showGrandTotal { stats.append(L.t("Cumul : 16 h 45", "Total: 16 h 45")) }

        var text = ""
        if pairing.linkReminderInLocation && !pairing.reminderListNames.isEmpty {
            text += L.t("Lieu : x-apple-reminderkit://REMCDReminder/5C1F…A93\n\n",
                        "Location: x-apple-reminderkit://REMCDReminder/5C1F…A93\n\n")
        }
        text += NotesComposer(pairing: pairing)
            .compose(existing: "", taskInfo: taskInfo, stats: stats, actions: actions)
        if pairing.embedTaskIdentifier && !pairing.reminderListNames.isEmpty {
            text += "\n\n⟦rcb:5C1F…A93⟧"
        }
        return text
    }
}

// MARK: - Journal

private struct LogTab: View {
    var engine: Engine

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(engine.logLines.enumerated().reversed()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(8)
            }
            .background(.quinary, in: RoundedRectangle(cornerRadius: 6))

            HStack {
                Text("~/Library/Application Support/RemindersCalendarBridge/")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(L.t("Révéler dans le Finder", "Reveal in Finder")) {
                    NSWorkspace.shared.activateFileViewerSelecting([Engine.logURL])
                }
            }
        }
        .padding()
    }
}
