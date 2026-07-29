import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @State private var store = ConfigStore.shared
    @State private var engine = Engine.shared

    var body: some View {
        TabView {
            GeneralTab(store: store, engine: engine)
                .tabItem { Label("Général", systemImage: "gearshape") }
            FormatTab(store: store)
                .tabItem { Label("Format", systemImage: "text.alignleft") }
            LogTab(engine: engine)
                .tabItem { Label("Journal", systemImage: "list.bullet.rectangle") }
        }
        .frame(width: 520, height: 460)
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
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
            }

            Section("Sources") {
                Picker("Calendrier surveillé", selection: $store.config.calendarName) {
                    ForEach(options(engine.availableCalendars, store.config.calendarName), id: \.self) {
                        Text($0).tag($0)
                    }
                }
                Toggle("N'enrichir que les titres présents dans une liste de rappels",
                       isOn: $store.config.requireReminderMatch)
                Picker("Liste de rappels", selection: $store.config.reminderListName) {
                    ForEach(options(engine.availableReminderLists, store.config.reminderListName), id: \.self) {
                        Text($0).tag($0)
                    }
                }
                .disabled(!store.config.requireReminderMatch)

                Toggle("Tolérer un suffixe après le titre de la tâche",
                       isOn: $store.config.looseTitleMatch)
                    .disabled(!store.config.requireReminderMatch)
                Text("Un événement intitulé « T015 - Rédiger\\n14/09/2026 » est rattaché à la tâche « T015 - Rédiger », et compté avec elle.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Glisser-déposer depuis Rappels") {
                Toggle("Nettoyer le titre de l'événement", isOn: $store.config.cleanEventTitle)
                    .disabled(!store.config.requireReminderMatch)
                Text("Déposer un rappel sur le calendrier recopie sa note à la suite du titre. Le titre est ramené à celui de la tâche.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Le contenu de la note n'est pas récupéré depuis le titre : il est reconstitué depuis les propriétés du rappel, dans la section « Informations de la tâche ».")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Fenêtres d'analyse") {
                Stepper("Détection : ±\(store.config.detectionDays) jours",
                        value: $store.config.detectionDays, in: 1...365)
                Stepper("Historique pris en compte : \(store.config.historyYears) ans",
                        value: $store.config.historyYears, in: 1...30)
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
            Text("Le bloc de statistiques sera réécrit sur tous les événements du calendrier dans la fenêtre de détection, y compris ceux déjà traités.")
        }
    }

    /// Garantit que la valeur enregistrée reste sélectionnable même si le
    /// calendrier ou la liste n'existe plus (ou pas encore chargé).
    private func options(_ available: [String], _ current: String) -> [String] {
        available.contains(current) ? available : ([current] + available)
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

// MARK: - Format

private struct FormatTab: View {
    @Bindable var store: ConfigStore

    var body: some View {
        Form {
            Section("Sections de la description") {
                Toggle("Informations de la tâche", isOn: $store.config.showTaskInfo)
                Text("Échéance, commentaires, priorité, liste, récurrence… relevés sur le rappel et régénérés à chaque passage.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Notes personnelles (jamais réécrites)", isOn: $store.config.includePersonalSection)
                Text("Section protégée : ce que vous y écrivez survit à un retraitement complet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Texte initial de la section", text: $store.config.personalPlaceholder)
            }

            Section("Contenu du bloc de statistiques") {
                Toggle("Numéro de session", isOn: $store.config.showSessionNumber)
                Toggle("Durée de la session courante", isOn: $store.config.showCurrentDuration)
                Toggle("Nombre et durée des sessions antérieures", isOn: $store.config.showPreviousTotal)
                Toggle("Date de la dernière séance", isOn: $store.config.showLastSessionDate)
                Toggle("Cumul total", isOn: $store.config.showGrandTotal)
            }

            Section("Lignes de séparation") {
                TextField("Informations de la tâche", text: $store.config.taskInfoMarker)
                TextField("Notes personnelles", text: $store.config.personalMarker)
                TextField("Statistiques", text: $store.config.marker)
                Text("Ces lignes délimitent les sections. Les modifier après coup empêche de retrouver les sections déjà écrites.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Écriture") {
                Toggle("Conserver les notes écrites à la main", isOn: $store.config.preserveExistingNotes)
                Text(store.config.preserveExistingNotes
                     ? "Le bloc est ajouté sous vos notes. S'il est déjà présent, il est remplacé plutôt qu'empilé."
                     : "Attention : la description de l'événement sera entièrement remplacée.")
                    .font(.caption)
                    .foregroundStyle(store.config.preserveExistingNotes ? Color.secondary : Color.red)
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

    private var preview: String {
        let c = store.config
        var blocks: [String] = []

        if c.showTaskInfo {
            blocks.append([c.taskInfoMarker,
                           "Liste : Doctorat - Tâches",
                           "Échéance : 14 septembre 2026",
                           "Priorité : haute",
                           "Commentaires : voir le compte rendu du 3 juillet"].joined(separator: "\n"))
        }
        if c.includePersonalSection {
            blocks.append(c.personalPlaceholder.isEmpty
                          ? c.personalMarker
                          : c.personalMarker + "\n" + c.personalPlaceholder)
        }

        var lines = [c.marker]
        if c.showSessionNumber { lines.append("Session n°8 — « Rédaction chapitre 2 »") }
        if c.showCurrentDuration { lines.append("Cette session : 2 h 30") }
        if c.showPreviousTotal { lines.append("Sessions antérieures : 7 — 14 h 15") }
        if c.showLastSessionDate { lines.append("Dernière séance : 22 juillet 2026") }
        if c.showGrandTotal { lines.append("Cumul : 16 h 45") }
        blocks.append(lines.joined(separator: "\n"))

        return blocks.joined(separator: "\n\n")
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
