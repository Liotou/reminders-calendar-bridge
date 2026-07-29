import Foundation
import AppKit
import Observation

/// Mise à jour depuis les publications GitHub du dépôt d'origine.
///
/// L'application étant signée en ad-hoc, il n'y a pas de certificat de
/// développeur à vérifier. Le lien de confiance repose donc sur trois points :
/// le dépôt est figé dans le code, l'échange se fait en HTTPS, et l'archive
/// téléchargée doit présenter une signature intacte et le même identifiant de
/// bundle que l'application en place. Rien n'est installé sans votre accord.
@MainActor
@Observable
final class Updater {
    static let shared = Updater()

    static let repository = "Liotou/reminders-calendar-bridge"
    static var releasesURL: URL { URL(string: "https://github.com/\(repository)/releases")! }

    enum State: Equatable {
        case idle
        case checking
        case upToDate(Date)
        case available(version: String, url: URL, notes: String)
        case installing
        case failed(String)
    }

    private(set) var state: State = .idle
    private var lastCheck: Date?

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    private init() {}

    /// Vérification périodique, au plus une fois par jour.
    func checkIfDue() {
        guard ConfigStore.shared.config.checkForUpdates else { return }
        if let lastCheck, Date().timeIntervalSince(lastCheck) < 86_400 { return }
        check()
    }

    func check() {
        guard state != .checking, state != .installing else { return }
        state = .checking
        lastCheck = Date()

        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repository)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20

        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.state = .failed(error.localizedDescription)
                    return
                }
                guard let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tag = json["tag_name"] as? String else {
                    self.state = .failed(L.t("Aucune version publiée.", "No published release."))
                    return
                }
                let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
                guard Self.isNewer(version, than: self.currentVersion) else {
                    self.state = .upToDate(Date())
                    return
                }
                let assets = json["assets"] as? [[String: Any]] ?? []
                guard let asset = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".zip") == true }),
                      let urlString = asset["browser_download_url"] as? String,
                      let url = URL(string: urlString) else {
                    self.state = .failed(L.t("La publication ne contient pas d'archive .zip.",
                                             "The release has no .zip asset."))
                    return
                }
                self.state = .available(version: version, url: url,
                                        notes: (json["body"] as? String) ?? "")
            }
        }.resume()
    }

    /// Comparaison de versions par composantes numériques : 1.10 dépasse 1.9.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    func install() {
        guard case .available(_, let url, _) = state else { return }
        state = .installing

        URLSession.shared.downloadTask(with: url) { [weak self] location, _, error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.state = .failed(error.localizedDescription)
                    return
                }
                guard let location else {
                    self.state = .failed(L.t("Téléchargement vide.", "Empty download."))
                    return
                }
                do {
                    try self.replaceInstalledApp(withArchiveAt: location)
                } catch {
                    self.state = .failed(error.localizedDescription)
                }
            }
        }.resume()
    }

    private func replaceInstalledApp(withArchiveAt archive: URL) throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        let zip = work.appendingPathComponent("update.zip")
        try fm.moveItem(at: archive, to: zip)
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, work.path])

        guard let bundle = try fm.contentsOfDirectory(at: work, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "app" }) else {
            throw Failure(L.t("L'archive ne contient pas d'application.",
                              "The archive contains no application."))
        }

        // Signature intacte et même identité que l'application en place : sans
        // cette vérification, n'importe quelle archive ferait l'affaire.
        try run("/usr/bin/codesign", ["--verify", "--strict", bundle.path])
        let plist = bundle.appendingPathComponent("Contents/Info.plist")
        guard let info = NSDictionary(contentsOf: plist),
              let identifier = info["CFBundleIdentifier"] as? String,
              identifier == Bundle.main.bundleIdentifier else {
            throw Failure(L.t("Identifiant de bundle inattendu dans l'archive.",
                              "Unexpected bundle identifier in the archive."))
        }

        let destination = Bundle.main.bundleURL
        let backup = work.appendingPathComponent("previous.app")
        try fm.moveItem(at: destination, to: backup)
        do {
            try fm.copyItem(at: bundle, to: destination)
        } catch {
            try? fm.moveItem(at: backup, to: destination)  // remise en place
            throw error
        }

        // Relance : le processus courant tourne encore depuis l'ancien bundle.
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: destination, configuration: configuration) { _, _ in
            Task { @MainActor in NSApplication.shared.terminate(nil) }
        }
    }

    private struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    @discardableResult
    private func run(_ tool: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw Failure("\(tool) : \(output.isEmpty ? "code \(process.terminationStatus)" : output)")
        }
        return output
    }
}
