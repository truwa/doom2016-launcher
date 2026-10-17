import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

private enum SupportFolder {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/DOOM 2016", isDirectory: true)
}

@MainActor
final class LauncherModel: ObservableObject {
    @Published var gamePath: String?
    @Published var gameReady = false
    @Published var status = "Choose the DOOM (2016) GOG folder you own."
    @Published var log = ""
    @Published var running = false
    @Published var updating = false
    @Published var gogDownloading = false
    @Published var showGogLogin = false
    @Published var wineVersion = ""
    @Published var showCredits = false

    nonisolated static var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        if let version, !version.isEmpty { return version }
        return "1.0"
    }

    private var gameURL: URL?
    private var gameProcess: Process?
    private var engineProcess: Process?
    private var windowTimer: Timer?
    private var sawGameWindow = false
    private var windowGonePolls = 0
    private var launchedAt = Date.distantPast
    private var logRemainder = ""
    var logLevel = "normal"
    private var seenLogLines: [String: Int] = [:]
    private var gogUpdateAfterLogin = false

    func restore() {
        loadWineVersion()
        if let data = UserDefaults.standard.data(forKey: "gameBookmark") {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale) {
                adopt(url)
                return
            }
            stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) {
                adopt(url)
                return
            }
        }
        if let path = UserDefaults.standard.string(forKey: "gamePath"),
           FileManager.default.fileExists(atPath: path) {
            adopt(URL(fileURLWithPath: path))
        }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose the DOOM (2016) GOG folder. It needs DOOMx64vk.exe and a goggame info file."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store(url)
        adopt(url, announce: true)
    }

    private func store(_ url: URL) {
        let scoped = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        let plain = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        if let data = scoped ?? plain {
            UserDefaults.standard.set(data, forKey: "gameBookmark")
        }
        UserDefaults.standard.set(url.path, forKey: "gamePath")
    }

    func installFromGog() {
        guard !running, !updating else { return }
        gogUpdateAfterLogin = false
        if gogSignedIn {
            chooseGogDestination()
        } else {
            showGogLogin = true
        }
    }

    func updateFromGog() {
        guard !running, !updating, let gameURL, gameReady else { return }
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Update DOOM (2016) from GOG?"
        alert.informativeText = "The latest base game will be downloaded into the folder you already chose. Files already there are kept."
        alert.addButton(withTitle: "Update")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        gogUpdateAfterLogin = true
        if gogSignedIn {
            startGogDownload(gameURL)
        } else {
            showGogLogin = true
        }
    }

    func finishGogSignIn(_ code: String) {
        showGogLogin = false
        updating = true
        status = "Signing in to GOG…"
        runEngine(["--gog-auth", code]) { _ in
        } onExit: { [weak self] code in
            guard let self else { return }
            self.updating = false
            guard code == 0 else {
                self.status = "GOG sign-in did not finish."
                return
            }
            if self.gogUpdateAfterLogin, let gameURL = self.gameURL, self.gameReady {
                self.startGogDownload(gameURL)
            } else {
                self.chooseGogDestination()
            }
        }
    }

    func stopGogDownload() {
        engineProcess?.terminate()
        gogDownloading = false
        updating = false
        status = "GOG download stopped."
    }

    private var gogSignedIn: Bool {
        FileManager.default.isReadableFile(atPath: SupportFolder.url.appendingPathComponent("gog-auth.json").path)
    }

    private func chooseGogDestination() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Install"
        panel.message = "Choose a folder for the GOG install of DOOM (2016). The base game is about 69 GB."
        guard panel.runModal() == .OK, let url = panel.url else {
            status = "GOG install was not started."
            return
        }
        startGogDownload(url)
    }

    private func startGogDownload(_ url: URL) {
        updating = true
        gogDownloading = true
        status = "Downloading DOOM (2016) from GOG…"
        runEngine(["--gog-download", url.path]) { [weak self] line in
            guard let self else { return }
            if line.hasPrefix("progress ") {
                self.status = "Downloading DOOM (2016)… \(line.dropFirst("progress ".count))%"
            } else if line.hasPrefix("status ") {
                self.status = String(line.dropFirst("status ".count))
            }
        } onExit: { [weak self] code in
            guard let self else { return }
            self.gogDownloading = false
            self.updating = false
            if code == 0 {
                self.store(url)
                self.adopt(url, announce: true)
                if self.gameReady { self.status = "Ready to play." }
            } else if !self.status.hasSuffix("stopped.") {
                self.status = "The GOG download did not finish."
            }
        }
    }

    func play(display: String, metalHud: Bool, skipIntro: Bool, devMode: Bool, msync: Bool, playstationIcons: Bool, logLevel: String) {
        guard let gameURL, gameReady, !running else { return }
        if !wineReady {
            if wineInstalled {
                beginWineSetup(force: false)
            } else {
                confirmWineDownload(force: false)
            }
            return
        }
        running = true
        sawGameWindow = false
        windowGonePolls = 0
        status = "DOOM is loading. The window can take a minute to appear."
        log = ""
        logRemainder = ""
        seenLogLines.removeAll()
        self.logLevel = logLevelArgument(logLevel)
        launchedAt = Date()
        let process = Process()
        process.executableURL = pythonURL
        var arguments = [launcherURL.path, "--game", gameURL.path, "--display", display]
        if metalHud { arguments.append("--metal-hud") }
        if skipIntro { arguments.append("--skip-intro") }
        if devMode { arguments.append("--dev-mode") }
        if msync { arguments.append("--msync") }
        if playstationIcons { arguments.append("--playstation-icons") }
        arguments += ["--log-level", logLevel]
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.terminationHandler = { [weak self] ended in
            Task { @MainActor in
                guard let self else { return }
                self.windowTimer?.invalidate()
                let alreadyNoted = self.status.hasSuffix("closed.") || self.status.hasSuffix("stopped.")
                self.running = false
                self.gameProcess = nil
                self.sawGameWindow = false
                if !alreadyNoted {
                    self.status = ended.terminationStatus == 0 ? "DOOM (2016) closed." : "DOOM (2016) stopped."
                }
            }
        }
        do {
            try process.run()
            gameProcess = process
            pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let text = String(data: handle.availableData, encoding: .utf8) ?? ""
                guard !text.isEmpty else { return }
                Task { @MainActor in
                    guard let self else { return }
                    self.appendLog(text)
                }
            }
            watchGameWindow()
        } catch {
            running = false
            status = "Cannot start: \(error.localizedDescription)"
        }
    }

    private func appendLog(_ text: String) {
        logRemainder += text
        let ended = text.hasSuffix("\n") || text.hasSuffix("\r")
        var parts = logRemainder.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        if ended {
            logRemainder = ""
        } else {
            logRemainder = parts.popLast() ?? ""
        }
        let kept = parts.compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !Self.isNoise(trimmed) else { return nil }
            let problem = Self.isProblem(trimmed)
            switch logLevel {
            case "errors":
                guard problem else { return nil }
            case "verbose":
                break
            default:
                guard problem || trimmed.hasPrefix("log ") else { return nil }
            }
            let count = (seenLogLines[trimmed] ?? 0) + 1
            seenLogLines[trimmed] = count
            if seenLogLines.count > 4_000 { seenLogLines.removeAll() }
            if count > 2 || (count == 2 && logLevel != "verbose") { return nil }
            return count == 1 ? trimmed : trimmed + " (repeating)"
        }
        guard !kept.isEmpty else { return }
        log += kept.joined(separator: "\n") + "\n"
        if log.count > 100_000 {
            let tail = String(log.suffix(80_000))
            if let newline = tail.firstIndex(of: "\n") {
                log = String(tail[tail.index(after: newline)...])
            } else {
                log = tail
            }
        }
        for line in kept where line.hasPrefix("status ") {
            status = String(line.dropFirst("status ".count))
        }
    }

    func clearLog() {
        log = ""
        logRemainder = ""
        seenLogLines.removeAll()
    }

    private func logLevelArgument(_ level: String) -> String {
        switch level {
        case "errors", "verbose": return level
        default: return "normal"
        }
    }

    private static func isNoise(_ text: String) -> Bool {
        let folded = text.lowercased()
        let keys = [
            "chainsawkill", "chroma", "pluginisplaying", "openanimation",
            "pluginplayanimation", "plugin is not initialized", "chromasdkplugin",
            "libmtlhud", "frame-interval",
        ]
        return keys.contains { folded.contains($0) }
    }

    private static func isProblem(_ text: String) -> Bool {
        let folded = text.lowercased()
        if folded.contains("exited") {
            guard let tail = folded.split(separator: " ").last, let code = Int(tail) else { return true }
            return code != 0
        }
        return ["cannot", "failed", "not found", "error", "exception", "not saved"].contains { folded.contains($0) }
    }

    func stop() {
        windowTimer?.invalidate()
        if running, !status.hasSuffix("closed.") {
            status = "DOOM (2016) stopped."
        }
        gameProcess?.terminate()
    }

    func killWine() {
        windowTimer?.invalidate()
        gameProcess?.terminate()
        running = false
        gameProcess = nil
        sawGameWindow = false
        status = "Stopping Wine processes…"
        runEngine(["--kill-wine"]) { [weak self] line in
            guard let self, line.hasPrefix("status ") else { return }
            self.status = String(line.dropFirst("status ".count))
        } onExit: { [weak self] code in
            guard let self, !self.status.hasPrefix("Wine processes") else { return }
            self.status = code == 0 ? "Wine processes stopped." : "Could not stop the Wine processes."
        }
    }

    func openSaveFolder() {
        let saved = saveFolder()
        try? FileManager.default.createDirectory(at: saved, withIntermediateDirectories: true)
        NSWorkspace.shared.open(saved)
    }

    private func saveFolder() -> URL {
        let users = SupportFolder.url.appendingPathComponent("prefix/drive_c/users", isDirectory: true)
        let children = (try? FileManager.default.contentsOfDirectory(at: users, includingPropertiesForKeys: nil)) ?? []
        for child in children where child.lastPathComponent != "Public" {
            let doom = child.appendingPathComponent("Saved Games/id Software/DOOM", isDirectory: true)
            if FileManager.default.fileExists(atPath: doom.path) { return doom }
        }
        return SupportFolder.url
    }

    private func adopt(_ url: URL, announce: Bool = false) {
        gameURL?.stopAccessingSecurityScopedResource()
        _ = url.startAccessingSecurityScopedResource()
        let resolved = resolveGame(url)
        gameURL = resolved
        gamePath = resolved.path
        refresh()
        guard announce, !gameReady else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "That folder is not a DOOM (2016) GOG install."
        alert.informativeText = "Choose the folder you own with DOOMx64vk.exe and a goggame info file."
        alert.runModal()
    }

    private func resolveGame(_ url: URL) -> URL {
        if isGogDoom(url) { return url }
        let children = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
        let matches = children.filter { isGogDoom($0) }
        if matches.count == 1 { return matches[0] }
        if isGogDoom(url.deletingLastPathComponent()) { return url.deletingLastPathComponent() }
        return url
    }

    private func isGogDoom(_ url: URL) -> Bool {
        var isDirectory = ObjCBool(false)
        let exe = url.appendingPathComponent("DOOMx64vk.exe")
        guard FileManager.default.fileExists(atPath: exe.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return false
        }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        return names.contains { $0.hasPrefix("goggame-") && $0.hasSuffix(".info") }
    }

    private func refresh() {
        guard let gameURL else { return }
        gameReady = isGogDoom(gameURL)
        if gameReady {
            status = "Ready to play."
            return
        }
        let exe = gameURL.appendingPathComponent("DOOMx64vk.exe")
        if FileManager.default.fileExists(atPath: exe.path) {
            status = "This folder has the game, but it is not a GOG install."
        } else {
            status = "This folder is not DOOM (2016)."
        }
    }

    private var wineInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: SupportFolder.url.appendingPathComponent("wine/bin/wine").path)
    }

    private var wineReady: Bool {
        wineInstalled && FileManager.default.fileExists(atPath: SupportFolder.url.appendingPathComponent("prefix/system.reg").path)
    }

    func prepareWine() {
        if wineReady {
            loadWineVersion()
            return
        }
        guard !updating else { return }
        if !wineInstalled {
            DispatchQueue.main.async { [weak self] in self?.confirmWineDownload(force: false) }
            return
        }
        beginWineSetup(force: false)
    }

    func updateWine() {
        guard !updating, !running else { return }
        confirmWineDownload(force: true)
    }

    private func confirmWineDownload(force: Bool) {
        guard !updating else { return }
        if !force, wineInstalled { return }
        let alert = NSAlert()
        alert.alertStyle = .informational
        if force {
            alert.messageText = "Update Wine"
            alert.informativeText = "The latest WineHQ macOS build will be downloaded, about 180 MB. It replaces the Wine copy used by this launcher. Saves and settings stay."
        } else {
            alert.messageText = "Wine will be downloaded"
            alert.informativeText = "The launcher does not include Wine. The latest WineHQ macOS build is about 180 MB. It is downloaded once, then a private Wine environment is created."
        }
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Not Now")
        if alert.runModal() == .alertFirstButtonReturn {
            beginWineSetup(force: force)
        } else if !wineInstalled {
            status = "Wine is downloaded before the game can start."
        }
    }

    private func beginWineSetup(force: Bool) {
        guard !updating else { return }
        updating = true
        status = !force && wineInstalled ? "Creating the Wine environment…" : "Downloading Wine…"
        runEngine([force ? "--update-wine" : "--setup-wine"]) { [weak self] line in
            guard let self else { return }
            if line.hasPrefix("progress ") {
                if !self.status.hasPrefix("Creating") {
                    self.status = "Downloading Wine… \(line.dropFirst("progress ".count))%"
                }
            } else if line.hasPrefix("status ") {
                self.status = String(line.dropFirst("status ".count))
            } else if line.hasPrefix("installed wine ") {
                self.wineVersion = String(line.dropFirst("installed wine ".count))
            } else if line.hasPrefix("ready ") {
                self.wineVersion = String(line.dropFirst("ready ".count))
            }
        } onExit: { [weak self] code in
            guard let self else { return }
            self.updating = false
            self.loadWineVersion()
            if code != 0 {
                self.status = "Wine setup did not finish. Open the launcher again to retry."
            } else if self.gameURL == nil {
                self.status = "Choose the DOOM (2016) GOG folder you own."
            } else {
                self.refresh()
            }
        }
    }

    private func runEngine(_ arguments: [String], onLine: @escaping (String) -> Void, onExit: @escaping (Int32) -> Void) {
        let process = Process()
        process.executableURL = pythonURL
        process.arguments = [launcherURL.path] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let buffer = LineBuffer()
        process.terminationHandler = { ended in
            Task { @MainActor in onExit(ended.terminationStatus) }
        }
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let text = String(data: handle.availableData, encoding: .utf8) ?? ""
            let lines = buffer.take(text)
            guard !lines.isEmpty else { return }
            Task { @MainActor in lines.forEach(onLine) }
        }
        try? process.run()
        engineProcess = process
    }

    private func watchGameWindow() {
        windowTimer?.invalidate()
        sawGameWindow = false
        windowGonePolls = 0
        windowTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollGameWindow() }
        }
    }

    private func pollGameWindow() {
        guard running, let process = gameProcess, process.isRunning else { return }
        if crashedSinceLaunch() {
            status = "DOOM crashed while opening."
            stop()
            return
        }
        if gameWindowVisible(root: process.processIdentifier) {
            sawGameWindow = true
            windowGonePolls = 0
            if status.hasPrefix("DOOM is loading") || status.hasPrefix("Starting") {
                status = "DOOM (2016) is running."
            }
            return
        }
        guard sawGameWindow else { return }
        windowGonePolls += 1
        if windowGonePolls >= 6 {
            status = "DOOM (2016) closed."
            stop()
        }
    }

    private func gameWindowVisible(root: Int32) -> Bool {
        let pids = family(of: root)
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        for window in list {
            guard let pid = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, pids.contains(pid) else { continue }
            guard let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let width = (bounds["Width"] as? NSNumber)?.doubleValue,
                  let height = (bounds["Height"] as? NSNumber)?.doubleValue,
                  width > 100, height > 100 else { continue }
            return true
        }
        return false
    }

    private func crashedSinceLaunch() -> Bool {
        let folder = saveFolder().appendingPathComponent("base", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return false }
        for file in files where file.lastPathComponent.hasPrefix("Crash.") && file.pathExtension == "html" {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if modified > launchedAt { return true }
        }
        return false
    }

    private func family(of root: Int32) -> Set<Int32> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-ax", "-o", "pid=,ppid="]
        let pipe = Pipe()
        process.standardOutput = pipe
        guard (try? process.run()) != nil else { return [root] }
        process.waitUntilExit()
        let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        var children: [Int32: [Int32]] = [:]
        for line in text.split(separator: "\n") {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count == 2, let pid = Int32(fields[0]), let parent = Int32(fields[1]) else { continue }
            children[parent, default: []].append(pid)
        }
        var seen: Set<Int32> = []
        var queue = [root]
        while let pid = queue.popLast() {
            if !seen.insert(pid).inserted { continue }
            queue.append(contentsOf: children[pid] ?? [])
        }
        return seen
    }

    private func loadWineVersion() {
        let url = SupportFolder.url.appendingPathComponent("WINE_VERSION")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let version = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !version.isEmpty { wineVersion = version }
    }

    private var resources: URL {
        Bundle.main.resourceURL ?? URL(fileURLWithPath: ".")
    }

    private var pythonURL: URL {
        let bundled = resources.appendingPathComponent("python/bin/python3")
        if FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled }
        return URL(fileURLWithPath: "/opt/homebrew/bin/python3")
    }

    private var launcherURL: URL {
        resources.appendingPathComponent("engine/launch.py")
    }
}

private struct CreditEntry: Identifiable {
    let id = UUID()
    let text: String
    var url: URL?
}

private struct CreditBlock: Identifiable {
    let id = UUID()
    let heading: String
    let lines: [CreditEntry]
}

private let creditBlocks: [CreditBlock] = [
    CreditBlock(heading: "DOOM (2016)", lines: [
        CreditEntry(text: "id Software"),
        CreditEntry(text: "Bethesda Softworks"),
        CreditEntry(text: "The game is not included"),
    ]),
    CreditBlock(heading: "Wine", lines: [
        CreditEntry(text: "LGPL-2.1-or-later"),
        CreditEntry(text: "Downloaded on first launch"),
        CreditEntry(text: "macOS build by Gcenx", url: URL(string: "https://github.com/Gcenx/macOS_Wine_builds/releases/latest")),
    ]),
    CreditBlock(heading: "KosmicKrisp", lines: [
        CreditEntry(text: "Mesa, MIT"),
        CreditEntry(text: "Compat build v0.1.0", url: URL(string: "https://github.com/truwa/kosmickrisp-compat/releases/tag/v0.1.0")),
        CreditEntry(text: "github.com/truwa/kosmickrisp-compat", url: URL(string: "https://github.com/truwa/kosmickrisp-compat")),
        CreditEntry(text: "docs.mesa3d.org", url: URL(string: "https://docs.mesa3d.org/drivers/kosmickrisp.html")),
    ]),
    CreditBlock(heading: "This launcher", lines: [
        CreditEntry(text: "Version \(LauncherModel.appVersion)"),
        CreditEntry(text: "MacGameTest", url: URL(string: "https://www.youtube.com/@MacGameTest")),
        CreditEntry(text: "youtube.com/@MacGameTest", url: URL(string: "https://www.youtube.com/@MacGameTest")),
    ]),
]

private struct CreditsView: View {
    var onClose: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color(nsColor: .windowBackgroundColor)
            ScrollView {
                VStack(spacing: 28) {
                    ForEach(creditBlocks) { block in
                        VStack(spacing: 6) {
                            Text(block.heading).font(.title2).fontWeight(.semibold)
                            ForEach(block.lines) { line in
                                if let url = line.url {
                                    Link(line.text, destination: url).underline()
                                } else {
                                    Text(line.text)
                                }
                            }
                            .font(.body)
                        }
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(.top, 48)
                .padding(.horizontal, 32)
                .padding(.bottom, 24)
            }
            Button("Close", action: onClose)
                .keyboardShortcut(.cancelAction)
                .padding(12)
        }
    }
}

private final class LineBuffer: @unchecked Sendable {
    private var text = ""
    func take(_ chunk: String) -> [String] {
        text += chunk
        var lines: [String] = []
        while let newline = text.firstIndex(of: "\n") {
            let line = text[..<newline].trimmingCharacters(in: .whitespacesAndNewlines)
            text = String(text[text.index(after: newline)...])
            if !line.isEmpty { lines.append(String(line)) }
        }
        return lines
    }
}

private struct PlayButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        // #A41F00 is the red field behind the logo. #891203 is the darker edge of the same art.
        let fill = configuration.isPressed
            ? Color(red: 137.0 / 255, green: 18.0 / 255, blue: 3.0 / 255)
            : Color(red: 164.0 / 255, green: 31.0 / 255, blue: 0)
        return configuration.label
            .foregroundStyle(.white)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(fill))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.black, lineWidth: 2)
            )
            .opacity(isEnabled ? 1 : 0.4)
    }
}

struct ContentView: View {
    @EnvironmentObject private var model: LauncherModel
    @AppStorage("displayMode") private var displayMode = "window"
    @AppStorage("showLog") private var showLog = false
    @AppStorage("logLevel") private var logLevel = "normal"
    @AppStorage("metalHud") private var metalHud = false
    @AppStorage("skipIntro") private var skipIntro = false
    @AppStorage("devMode") private var devMode = false
    @AppStorage("msync") private var msync = false
    @AppStorage("playstationIcons") private var playstationIcons = false
    @AppStorage("appearance") private var appearance = "system"
    @State private var folderDetails = false
    @State private var optionsOpen = false
    @State private var contentHeight: CGFloat = 0
    @State private var systemScheme = systemColorScheme()

    private var cover: some View {
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("cover.jpg")
        let image = bundled.flatMap { NSImage(contentsOf: $0) }
        return ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Color(nsColor: .quaternaryLabelColor)
            }
        }
        .frame(width: 150, height: 211)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.18)))
        .opacity(model.gameReady || model.running ? 1 : 0.4)
        .accessibilityLabel("DOOM (2016)")
    }

    var body: some View {
        ZStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 10) {
                Text("DOOM (2016), GOG version, under Wine.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline) {
                    Button(action: model.chooseFolder) {
                        Label("Point to the DOOM (2016) GOG folder you own:", systemImage: "folder")
                            .font(.headline)
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    Spacer(minLength: 8)
                    Button {
                        folderDetails.toggle()
                    } label: {
                        Image(systemName: folderDetails ? "chevron.down" : "chevron.right")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(folderDetails ? "Hide folder details" : "Show folder details")
                }
                if folderDetails {
                    Text("The folder needs DOOMx64vk.exe and a goggame info file.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(model.gamePath ?? "No game folder chosen")
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                }
                HStack(alignment: .center, spacing: 16) {
                    cover
                    VStack(alignment: .leading, spacing: 10) {
                        Text("DOOM (2016)")
                            .font(.title2)
                        Button {
                            if model.running {
                                model.stop()
                            } else {
                                model.play(display: displayMode, metalHud: metalHud, skipIntro: skipIntro, devMode: devMode, msync: msync, playstationIcons: playstationIcons, logLevel: fullLogging ? "verbose" : logLevel)
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: model.running ? "stop.fill" : "play.fill")
                                    .font(.system(size: 15, weight: .semibold))
                                Text(model.running ? "Stop" : "Play")
                                    .font(.system(size: 18, weight: .semibold))
                            }
                            .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(PlayButtonStyle())
                        .disabled(model.updating || (!model.running && !model.gameReady))
                    }
                    .frame(width: 180)
                    Spacer(minLength: 0)
                }
                Text(model.status)
                DisclosureGroup("Options", isExpanded: $optionsOpen) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Appearance")
                            Picker("Appearance", selection: $appearance) {
                                Text("System").tag("system")
                                Text("Light").tag("light")
                                Text("Dark").tag("dark")
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .frame(maxWidth: 280)
                        }
                        HStack {
                            Text("Start the game in")
                            Picker("Start the game in", selection: $displayMode) {
                                Text("Window").tag("window")
                                Text("Borderless").tag("borderless")
                                Text("Full Screen").tag("fullscreen")
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .frame(maxWidth: 420)
                        }
                        HStack {
                            Text("Logging")
                            Picker("Logging", selection: $logLevel) {
                                Text("Errors").tag("errors")
                                Text("Normal").tag("normal")
                                Text("Verbose").tag("verbose")
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .frame(maxWidth: 280)
                            .disabled(model.running)
                        }
                        HStack(spacing: 20) {
                            Toggle("Show log", isOn: $showLog)
                            Toggle("Metal HUD", isOn: $metalHud)
                                .disabled(model.running)
                            Toggle("Skip intro", isOn: $skipIntro)
                                .disabled(model.running)
                            Toggle("Dev mode", isOn: $devMode)
                                .disabled(model.running)
                            Toggle("Msync", isOn: $msync)
                                .disabled(model.running)
                        }
                        Toggle("PlayStation icons", isOn: $playstationIcons)
                            .disabled(model.running)
                        HStack {
                            Text(wineLabel).lineLimit(1)
                            Spacer()
                            Button("Kill all wine processes") { model.killWine() }
                                .disabled(model.updating)
                            Button("Update Wine") { model.updateWine() }
                                .disabled(model.running || model.updating)
                        }
                    }
                    .padding(.top, 4)
                }
                if showLog {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Spacer()
                            Button("Copy") { copyLog() }
                            Button("Save…") { saveLog() }
                            Button("Clear") { model.clearLog() }
                        }
                        .controlSize(.small)
                        .disabled(model.log.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        LogText(text: model.log)
                            .frame(height: 120)
                            .padding(8)
                            .background(Color(nsColor: .textBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
                            .overlay(alignment: .topLeading) {
                                if model.log.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    Text("No log yet.")
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .padding(8)
                                        .allowsHitTesting(false)
                                }
                            }
                    }
                }
                HStack {
                    Text("Version \(LauncherModel.appVersion)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Credits & Licenses") { model.showCredits = true }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .fixedSize(horizontal: false, vertical: true)
            .background(GeometryReader { proxy in
                Color.clear.preference(key: ContentHeight.self, value: proxy.size.height)
            })
            if model.showCredits {
                CreditsView { model.showCredits = false }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(WindowHeight(height: contentHeight))
        .frame(minWidth: 640)
        .onPreferenceChange(ContentHeight.self) { height in
            if height > 160 { contentHeight = height }
        }
        .preferredColorScheme(preferredScheme)
        .onAppear {
            folderDetails = false
            optionsOpen = false
            if fullLogging { showLog = true }
            systemScheme = Self.systemColorScheme()
            applyAppearance()
            model.restore()
            model.prepareWine()
        }
        .onChange(of: model.showCredits) { _, showing in
            if showing { NSApp.keyWindow?.makeFirstResponder(nil) }
        }
        .onChange(of: logLevel) { _, level in
            model.logLevel = level
        }
        .onChange(of: appearance) { _, _ in
            systemScheme = Self.systemColorScheme()
            applyAppearance()
        }
        .onReceive(DistributedNotificationCenter.default().publisher(for: Notification.Name("AppleInterfaceThemeChangedNotification"))) { _ in
            systemScheme = Self.systemColorScheme()
            if appearance == "system" { applyAppearance() }
        }
        .sheet(isPresented: $model.showGogLogin) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Sign in to the GOG account that owns DOOM (2016).")
                    .font(.headline)
                GogSignIn { code in
                    model.finishGogSignIn(code)
                }
                .frame(width: 640, height: 520)
                HStack {
                    Spacer()
                    Button("Cancel") { model.showGogLogin = false }
                }
            }
            .padding(16)
        }
    }

    private func copyLog() {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(model.log, forType: .string)
    }

    private func saveLog() {
        let text = model.log
        let panel = NSSavePanel()
        panel.title = "Save log"
        panel.nameFieldStringValue = "doom-2016-log.txt"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                Task { @MainActor in
                    model.status = "Could not save the log."
                }
            }
        }
    }

    private var fullLogging: Bool {
        ProcessInfo.processInfo.environment["DOOM_FULL_LOG"] == "1"
            || UserDefaults.standard.bool(forKey: "fullLog")
    }

    private var preferredScheme: ColorScheme {
        switch appearance {
        case "light": return .light
        case "dark": return .dark
        default: return systemScheme
        }
    }

    private static func systemColorScheme() -> ColorScheme {
        UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark" ? .dark : .light
    }

    private func applyAppearance() {
        let name: NSAppearance.Name? = switch appearance {
        case "light": .aqua
        case "dark": .darkAqua
        default: nil
        }
        let resolved = name.flatMap { NSAppearance(named: $0) }
        NSApp.appearance = resolved
        for window in NSApp.windows {
            window.appearance = resolved
        }
    }

    private var wineLabel: String {
        if model.wineVersion.isEmpty { return "Wine downloads on first launch" }
        return "Wine \(model.wineVersion)"
    }
}

@main
struct DoomApp: App {
    @StateObject private var model = LauncherModel()

    var body: some Scene {
        WindowGroup("DOOM (2016)") {
            ContentView()
                .environmentObject(model)
        }
        .defaultSize(width: 680, height: 280)
        .commands {
            CommandGroup(after: .appInfo) {
                Button(model.gogDownloading ? "Stop Download" : (model.gameReady ? "Update from GOG" : "Install from GOG…")) {
                    if model.gogDownloading {
                        model.stopGogDownload()
                    } else if model.gameReady {
                        model.updateFromGog()
                    } else {
                        model.installFromGog()
                    }
                }
                .disabled(model.running || (model.updating && !model.gogDownloading))
                Button("Open Game Save Folder") { model.openSaveFolder() }
                Button("Credits & Licenses") { model.showCredits = true }
            }
        }
    }
}

private struct GogSignIn: NSViewRepresentable {
    var onCode: (String) -> Void

    func makeNSView(context: Context) -> WKWebView {
        let web = WKWebView()
        web.navigationDelegate = context.coordinator
        let address = "https://auth.gog.com/auth?client_id=46899977096215655&redirect_uri=https%3A%2F%2Fembed.gog.com%2Fon_login_success%3Forigin%3Dclient&response_type=code&layout=client2"
        if let url = URL(string: address) {
            web.load(URLRequest(url: url))
        }
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onCode: onCode)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onCode: (String) -> Void
        var delivered = false

        init(onCode: @escaping (String) -> Void) {
            self.onCode = onCode
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if deliver(webView.url) || deliver(navigationAction.request.url) {
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            _ = deliver(webView.url)
        }

        private func deliver(_ url: URL?) -> Bool {
            guard !delivered, let url, url.host?.contains("gog.com") == true else { return false }
            guard let code = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "code" })?.value, !code.isEmpty else { return false }
            delivered = true
            onCode(code)
            return true
        }
    }
}

private struct LogText: NSViewRepresentable {
    var text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let textView = scroll.documentView as? NSTextView else { return scroll }
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.drawsBackground = false
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textColor = .labelColor
        textView.textContainerInset = NSSize(width: 0, height: 0)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = false
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        textView.textColor = .labelColor
        guard textView.string != text else { return }
        let selected = textView.selectedRange()
        let stick = selected.length == 0 && isNearBottom(scroll)
        textView.string = text
        let length = (text as NSString).length
        if stick {
            textView.scrollToEndOfDocument(nil)
        } else if selected.location <= length {
            let range = NSRange(location: selected.location, length: min(selected.length, length - selected.location))
            textView.setSelectedRange(range)
        }
    }

    private func isNearBottom(_ scroll: NSScrollView) -> Bool {
        guard let document = scroll.documentView else { return true }
        let visible = scroll.contentView.bounds
        let limit = document.frame.height - visible.height
        return visible.origin.y >= limit - 24
    }
}

private struct ContentHeight: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct WindowHeight: NSViewRepresentable {
    var height: CGFloat

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        let height = height
        DispatchQueue.main.async {
            guard height > 200, let window = view.window else { return }
            if let applied = context.coordinator.applied, abs(applied - height) < 2 { return }
            var frame = window.frame
            let content = window.contentRect(forFrameRect: frame)
            let delta = height - content.height
            frame.size.height += delta
            frame.origin.y -= delta
            let minimum = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 640, height: height)).size
            window.minSize = minimum
            window.setFrame(frame, display: true, animate: context.coordinator.applied != nil)
            context.coordinator.applied = height
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var applied: CGFloat?
    }
}
