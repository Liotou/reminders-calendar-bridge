import SwiftUI

/// Les demandes d'autorisation TCC doivent partir une fois l'application
/// pleinement lancée. Émises depuis `App.init()`, elles sont refusées sans
/// qu'aucun dialogue ne s'affiche.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            Engine.shared.start()
            Updater.shared.checkIfDue()
        }
    }
}

@main
struct RemindersCalendarBridgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var engine = Engine.shared
    @State private var store = ConfigStore.shared
    @State private var updater = Updater.shared

    var body: some Scene {
        MenuBarExtra {
            Text(engine.lastActivity)
            Text(L.t("\(engine.processedCount) événement(s) suivi(s)",
                     "\(engine.processedCount) tracked event(s)"))
            if case .available(let version, _, _) = updater.state {
                Divider()
                Text(L.t("Version \(version) disponible", "Version \(version) available"))
            }
            Divider()
            Toggle(L.t("Surveillance active", "Watching enabled"), isOn: $store.config.enabled)
            Button(L.t("Analyser maintenant", "Scan now")) { engine.scanNow() }
            Divider()
            SettingsLink { Text(L.t("Réglages…", "Settings…")) }
                .keyboardShortcut(",", modifiers: .command)
            Button(L.t("Quitter", "Quit")) { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q", modifiers: .command)
        } label: {
            Image(systemName: store.config.enabled ? "calendar.badge.clock" : "calendar")
        }

        Settings {
            SettingsView()
        }
    }
}
