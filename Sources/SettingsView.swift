import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @State private var store = ConfigStore.shared
    @State private var engine = Engine.shared

    var body: some View {
        TabView {
            GeneralTab(store: store, engine: engine)
                .tabItem { Label("Général", systemImage: "gearshape") }
            PairingsTab(store: store, engine: engine)
                .tabItem { Label("Associations", systemImage: "arrow.triangle.branch") }
            LogTab(engine: engine)
                .tabItem { Label("Journal", systemImage: "list.bullet.rectangle") }
        }
        .frame(width: 700, height: 560)
        .onAppear { engine.refreshSources() }
    }
}

// MARK: - Général

private struct GeneralTab: View {
    @Bindable var store: ConfigStore
    var engine: Engine
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    @State private var confirmReprocess = false

    var body: some View {
        Form {
            Section {
                Toggle("Surveillance active", isOn: $store.config.enabled)
                Toggle("Lancer au démarrage de la session", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, wanted in setLaunchAtLogin(wanted) }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(Color.red)
                }
            }

            Section("Fenêtres d'analyse") {
                Stepper("Détection : ±\(store.config.detectionDays) jours",
                        value: $store.config.detectionDays, in: 1...365)
                Stepper("Historique pris en compte : \(store.config.historyYears) ans",
                        value: $store.config.historyYears, in: 1...30)
                Text("Communes à toutes les associations.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("État") {
                LabeledContent("Calendrier", value: accessLabel(engine.calendarAccess))
                LabeledContent("Rappels", value: accessLabel(engine.reminderAccess))
                LabeledContent("Événements suivis", value: "\(engine.processedCount)")
                LabeledContent("Dernière activité", value: engine.lastActivity)
                HStack {
                    Button("Analyser maintenant") { engine.scanNow() }
                    Button("Oublier l'état") { engine.forgetState() }
                    Button("Retraiter tout l'historique") { confirmReprocess = true }
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Retraiter tout l'historique ?", isPresented: $confirmReprocess) {
            Button("Retraiter", role: .destructive) { engine.reprocessAll() }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Les sections « Informations de la tâche » et « Statistiques » seront réécrites sur tous les événements des calendriers associés, dans la fenêtre de détection. Les notes personnelles sont préservées.")
        }
    }

    private func accessLabel(_ state: AccessState) -> String {
        switch state {
        case .unknown: "en attente"
        case .granted: "accordé"
        case .denied(let reason): "refusé — \(reason)"
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
                                Text(pairing.reminderListName.isEmpty
                                     ? "Toutes les entrées" : pairing.reminderListName)
                                    .lineLimit(1)
                                Text(pairing.calendarName.isEmpty
                                     ? "(aucun calendrier)" : pairing.calendarName)
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
                        new.reminderListName = engine.availableReminderLists.first ?? ""
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
                    ContentUnavailableView("Aucune association sélectionnée",
                                           systemImage: "arrow.triangle.branch",
                                           description: Text("Chaque association relie une liste de rappels à un calendrier, avec sa propre mise en forme."))
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
            Section("Sources") {
                Picker("Liste de rappels", selection: $pairing.reminderListName) {
                    Text("Aucune (tous les événements)").tag("")
                    ForEach(options(engine.availableReminderLists, pairing.reminderListName), id: \.self) {
                        Text($0).tag($0)
                    }
                }
                Picker("Calendrier", selection: $pairing.calendarName) {
                    ForEach(options(engine.availableCalendars, pairing.calendarName), id: \.self) {
                        Text($0).tag($0)
                    }
                }
                Toggle("Tolérer un suffixe après le titre de la tâche",
                       isOn: $pairing.looseTitleMatch)
                    .disabled(pairing.reminderListName.isEmpty)
                Text("Le glisser-déposer d'un rappel ajoute sa note au titre. Le titre de l'événement est ensuite ramené à celui de la tâche.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Sections de la description") {
                // L'ordre du tableau est l'ordre d'écriture : on le change par
                // glissement.
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
                .frame(height: 96)
                .listStyle(.plain)
                Text("Glissez les lignes pour changer l'ordre. La section « Notes personnelles » n'est jamais réécrite.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Lignes de séparation") {
                ForEach($pairing.sections) { $setting in
                    TextField(setting.section.label, text: $setting.marker)
                }
                Text("Elles délimitent les sections dans la description. Les modifier après coup empêche de retrouver celles déjà écrites dans les événements existants.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Texte initial des notes personnelles", text: $pairing.personalPlaceholder)
            }

            Section("Statistiques") {
                Toggle("Numéro de session", isOn: $pairing.showSessionNumber)
                Toggle("Durée de la session courante", isOn: $pairing.showCurrentDuration)
                Toggle("Nombre et durée des sessions antérieures", isOn: $pairing.showPreviousTotal)
                Toggle("Date de la dernière séance", isOn: $pairing.showLastSessionDate)
                Toggle("Cumul total", isOn: $pairing.showGrandTotal)
                Toggle("Conserver le texte libre existant", isOn: $pairing.preserveExistingNotes)
            }

            Section("Aperçu") {
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

    private var preview: String {
        var taskInfo: [String] = []
        if !pairing.reminderListName.isEmpty {
            taskInfo = ["Liste : \(pairing.reminderListName)",
                        "Échéance : 14 septembre 2026",
                        "Priorité : haute",
                        "Commentaires : voir le compte rendu du 3 juillet"]
        }
        var stats: [String] = []
        if pairing.showSessionNumber { stats.append("Session n°8 — « Rédaction chapitre 2 »") }
        if pairing.showCurrentDuration { stats.append("Cette session : 2 h 30") }
        if pairing.showPreviousTotal { stats.append("Sessions antérieures : 7 — 14 h 15") }
        if pairing.showLastSessionDate { stats.append("Dernière séance : 22 juillet 2026") }
        if pairing.showGrandTotal { stats.append("Cumul : 16 h 45") }

        return NotesComposer(pairing: pairing)
            .compose(existing: "", taskInfo: taskInfo, stats: stats)
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
                Text("Journal complet : ~/Library/Application Support/SessionsStats/")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Révéler dans le Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([Engine.logURL])
                }
            }
        }
        .padding()
    }
}
