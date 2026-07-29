import SwiftUI

/// Les demandes d'autorisation TCC doivent partir une fois l'application
/// pleinement lancée. Émises depuis `App.init()`, elles sont refusées sans
/// qu'aucun dialogue ne s'affiche.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            Engine.shared.start()
        }
    }
}

@main
struct RemindersCalendarBridgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var engine = Engine.shared
    @State private var store = ConfigStore.shared

    var body: some Scene {
        MenuBarExtra {
            Text(engine.lastActivity)
            Text("\(engine.processedCount) événement(s) suivi(s)")
            Divider()
            Toggle("Surveillance active", isOn: $store.config.enabled)
            Button("Analyser maintenant") { engine.scanNow() }
            Divider()
            SettingsLink { Text("Réglages…") }
                .keyboardShortcut(",", modifiers: .command)
            Button("Quitter") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q", modifiers: .command)
        } label: {
            Image(systemName: store.config.enabled ? "calendar.badge.clock" : "calendar")
        }

        Settings {
            SettingsView()
        }
    }
}
