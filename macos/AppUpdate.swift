import AppKit
import Foundation
import SwiftUI

private let bundleIdentifier = "com.doom2016.macos"
private let releaseAPI = URL(string: "https://api.github.com/repos/truwa/doom2016-launcher/releases/latest")!

private struct SemanticVersion: Comparable, Equatable {
    var major: Int
    var minor: Int
    var patch: Int
    var prerelease: [String]

    static func parse(_ raw: String) -> SemanticVersion? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.first == "v" || text.first == "V" { text.removeFirst() }
        let withoutBuild = text.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)[0]
        let pieces = withoutBuild.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let core = pieces[0].split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(core.count) else { return nil }
        var numbers: [Int] = []
        for part in core {
            guard let value = Int(part), value >= 0, String(value) == part else { return nil }
            numbers.append(value)
        }
        while numbers.count < 3 { numbers.append(0) }
        var prerelease: [String] = []
        if pieces.count == 2 {
            let identifiers = pieces[1].split(separator: ".", omittingEmptySubsequences: false)
            guard !identifiers.isEmpty else { return nil }
            for item in identifiers {
                let identifier = String(item)
                guard isIdentifier(identifier) else { return nil }
                prerelease.append(identifier)
            }
        }
        return SemanticVersion(major: numbers[0], minor: numbers[1], patch: numbers[2], prerelease: prerelease)
    }

    private static func isIdentifier(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        let allowed = text.allSatisfy { character in
            character.isASCII && (character.isLetter || character.isNumber || character == "-")
        }
        guard allowed else { return false }
        if text.allSatisfy(\.isNumber), text.count > 1, text.first == "0" { return false }
        return true
    }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
        if lhs.prerelease.isEmpty { return false }
        if rhs.prerelease.isEmpty { return true }
        let count = min(lhs.prerelease.count, rhs.prerelease.count)
        for index in 0..<count {
            let left = lhs.prerelease[index]
            let right = rhs.prerelease[index]
            if left == right { continue }
            switch (Self.number(left), Self.number(right)) {
            case let (left?, right?) where left != right:
                return left < right
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            default:
                return left < right
            }
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }

    private static func number(_ text: String) -> Int? {
        guard text.allSatisfy(\.isNumber) else { return nil }
        return Int(text)
    }
}

private struct ReleaseInfo {
    var tag: String
    var notes: String
    var zip: URL
    var size: Int64
}

private enum UpdateCheck {
    case current(String)
    case ahead(local: String, published: String)
    case available(ReleaseInfo, local: String)
    case failed(String)
}

enum UpdatePhase {
    case idle
    case checking
    case downloading(received: Int64, total: Int64)
    case preparing(String)
    case ready(skippedNotarization: Bool)
    case failed(String)
}

private enum UpdateFeed {
    static var isOverridden: Bool {
        #if DEBUG
        return overrideLocation() != nil
        #else
        return false
        #endif
    }

    static func load(currentVersion: String) async -> UpdateCheck {
        guard let current = SemanticVersion.parse(currentVersion) else {
            return .failed("This copy's version “\(currentVersion)” is not a semantic version.")
        }
        do {
            let (json, source) = try await fetchDescription()
            guard let tag = (json["tag_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !tag.isEmpty else {
                return .failed("The update feed did not include a version.")
            }
            guard let latest = SemanticVersion.parse(tag) else {
                return .failed("The published version “\(tag)” is not a semantic version.")
            }
            let shown = display(tag)
            if latest == current {
                return .current(currentVersion)
            }
            if latest < current {
                return .ahead(local: currentVersion, published: shown)
            }
            guard let zip = resolveZip(in: json, base: source) else {
                return .failed("Version \(shown) has no .zip download.")
            }
            guard accept(zip.url) else {
                return .failed("The download link for \(shown) is not a release zip this app can use.")
            }
            let notes = (json["body"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return .available(ReleaseInfo(tag: shown, notes: notes, zip: zip.url, size: zip.size), local: currentVersion)
        } catch let error as UpdateFailure {
            return .failed(error.message)
        } catch {
            return .failed(describe(error))
        }
    }

    private static func fetchDescription() async throws -> ([String: Any], URL) {
        #if DEBUG
        if let override = overrideLocation() {
            if override.isFileURL {
                let data = try Data(contentsOf: override)
                return (try parse(data, from: override), override)
            }
            let (data, response) = try await data(from: override, tokenHost: true)
            return (try parse(data, response: response, from: override), override)
        }
        #endif
        let (data, response) = try await data(from: releaseAPI, tokenHost: true)
        return (try parse(data, response: response, from: releaseAPI), releaseAPI)
    }

    private static func parse(_ data: Data, response: URLResponse? = nil, from url: URL) throws -> [String: Any] {
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw UpdateFailure(httpFailure(http.statusCode, data: data, url: url))
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UpdateFailure("The update feed was not a release description.")
        }
        return json
    }

    private static func resolveZip(in json: [String: Any], base: URL) -> (url: URL, size: Int64)? {
        let assets = json["assets"] as? [[String: Any]] ?? []
        let zips: [(name: String, url: URL, size: Int64)] = assets.compactMap { asset in
            guard let name = asset["name"] as? String, name.lowercased().hasSuffix(".zip") else { return nil }
            guard let text = asset["browser_download_url"] as? String else { return nil }
            guard let url = resolve(text, base: base) else { return nil }
            let size = (asset["size"] as? NSNumber)?.int64Value ?? 0
            return (name, url, size)
        }
        let preferred = zips.first { $0.name.lowercased().contains("doom") } ?? zips.first
        return preferred.map { ($0.url, $0.size) }
    }

    private static func resolve(_ text: String, base: URL) -> URL? {
        if let url = URL(string: text), url.scheme != nil { return url }
        return base.deletingLastPathComponent().appendingPathComponent(text)
    }

    private static func accept(_ url: URL) -> Bool {
        #if DEBUG
        if isOverridden {
            if url.isFileURL { return true }
            if url.scheme == "http", let host = url.host?.lowercased(), host == "localhost" || host == "127.0.0.1" {
                return true
            }
        }
        #endif
        guard url.scheme == "https", let host = url.host?.lowercased() else { return false }
        return [
            "github.com",
            "api.github.com",
            "objects.githubusercontent.com",
            "release-assets.githubusercontent.com",
        ].contains(host)
    }

    private static func data(from url: URL, tokenHost: Bool) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("doom-2016-macos", forHTTPHeaderField: "User-Agent")
        #if DEBUG
        if tokenHost, let token = debugToken(for: url) {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        #endif
        do {
            return try await URLSession.shared.data(for: request)
        } catch {
            throw UpdateFailure(describe(error, url: url))
        }
    }

    private static func httpFailure(_ status: Int, data: Data, url: URL) -> String {
        let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String
        let extra = detail.map { " \($0)." } ?? ""
        if status == 404 {
            return "The update link is not reachable (HTTP 404).\(extra) GitHub hides releases of a private repository, so this check fails until the repository is public. Asked \(url.absoluteString)."
        }
        if status == 403 {
            return "GitHub refused the update check (HTTP 403).\(extra)"
        }
        return "The update feed answered HTTP \(status).\(extra)"
    }

    private static func describe(_ error: Error, url: URL? = nil) -> String {
        if let failure = error as? UpdateFailure { return failure.message }
        let target = url?.host ?? "the update server"
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                return "The update link is not reachable. This Mac appears to be offline."
            case .cannotFindHost, .dnsLookupFailed:
                return "The update link is not reachable. \(target) could not be found."
            case .cannotConnectToHost, .timedOut, .resourceUnavailable:
                return "The update link is not reachable. \(target) did not answer."
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid:
                return "The update link could not be trusted. \(target) failed its certificate check."
            default:
                break
            }
        }
        return "Could not check for an update. \(error.localizedDescription)"
    }

    private static func display(_ tag: String) -> String {
        var text = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.first == "v" || text.first == "V" { text.removeFirst() }
        return text
    }

    #if DEBUG
    private static func overrideLocation() -> URL? {
        let raw = ProcessInfo.processInfo.environment["DOOM_UPDATE_FEED"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !raw.isEmpty else { return nil }
        if raw.hasPrefix("http://") || raw.hasPrefix("https://") || raw.hasPrefix("file://") {
            return URL(string: raw)
        }
        let path = URL(fileURLWithPath: raw)
        var directory = ObjCBool(false)
        if FileManager.default.fileExists(atPath: path.path, isDirectory: &directory), directory.boolValue {
            return path.appendingPathComponent("release.json")
        }
        return path
    }

    static func debugToken(for url: URL) -> String? {
        guard let host = url.host?.lowercased(), host == "github.com" || host == "api.github.com" else { return nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "doom2016-launcher-update",
            kSecAttrAccount as String: "github",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let token = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static var skipNotarization: Bool {
        isOverridden && ProcessInfo.processInfo.environment["DOOM_UPDATE_SKIP_NOTARIZATION"] == "1"
    }
    #endif
}

private struct UpdateFailure: LocalizedError {
    var message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

private struct VerifyOutcome: Sendable {
    var failure: String?
    var skippedNotarization: Bool
}

private enum BundleVerifier {
    static func check(newApp: URL, currentApp: URL, requireNotarization: Bool) -> VerifyOutcome {
        let verified = run("/usr/bin/codesign", ["--verify", "--deep", "--strict", "--verbose=2", newApp.path])
        guard verified.status == 0 else {
            return VerifyOutcome(failure: "The download failed its code signature check. \(clip(verified.output))", skippedNotarization: false)
        }
        let current = signature(of: currentApp)
        let downloaded = signature(of: newApp)
        guard let team = downloaded.team, !team.isEmpty else {
            return VerifyOutcome(failure: "The download is not signed with a Developer ID.", skippedNotarization: false)
        }
        guard let currentTeam = current.team, !currentTeam.isEmpty else {
            return VerifyOutcome(failure: "This copy has no Team ID, so the download cannot be compared with it.", skippedNotarization: false)
        }
        guard team == currentTeam else {
            return VerifyOutcome(failure: "The download is signed by team \(team), not this app's team \(currentTeam).", skippedNotarization: false)
        }
        guard downloaded.identifier == bundleIdentifier else {
            return VerifyOutcome(failure: "The download is \(downloaded.identifier ?? "a different app"), not \(bundleIdentifier).", skippedNotarization: false)
        }
        guard requireNotarization else {
            return VerifyOutcome(failure: nil, skippedNotarization: true)
        }
        let assessment = run("/usr/sbin/spctl", ["--assess", "--type", "execute", "--verbose", newApp.path])
        guard assessment.status == 0 else {
            return VerifyOutcome(failure: "Apple has not accepted the notarization ticket for this download. \(clip(assessment.output))", skippedNotarization: false)
        }
        return VerifyOutcome(failure: nil, skippedNotarization: false)
    }

    private static func signature(of url: URL) -> (team: String?, identifier: String?) {
        let result = run("/usr/bin/codesign", ["-dv", "--verbose=4", url.path])
        var team: String?
        var identifier: String?
        for line in result.output.split(whereSeparator: \.isNewline) {
            let text = String(line)
            if text.hasPrefix("TeamIdentifier=") {
                let value = String(text.dropFirst("TeamIdentifier=".count)).trimmingCharacters(in: .whitespaces)
                if value != "not set" { team = value }
            } else if text.hasPrefix("Identifier=") {
                identifier = String(text.dropFirst("Identifier=".count)).trimmingCharacters(in: .whitespaces)
            }
        }
        return (team, identifier)
    }

    private static func run(_ path: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (1, error.localizedDescription)
        }
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    private static func clip(_ text: String) -> String {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
        let tail = lines.suffix(4).joined(separator: " ")
        if tail.count <= 360 { return tail }
        return String(tail.suffix(360))
    }
}

private final class ZipDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private var session: URLSession?
    private var continuation: CheckedContinuation<URL, Error>?
    private var resumed = false
    private var downloaded: URL?
    private var moveError: Error?
    private let destination: URL
    private let fallbackTotal: Int64
    private let progress: @Sendable (Int64, Int64) -> Void
    #if DEBUG
    private var authorization: String?
    #endif

    init(destination: URL, fallbackTotal: Int64, progress: @escaping @Sendable (Int64, Int64) -> Void) {
        self.destination = destination
        self.fallbackTotal = fallbackTotal
        self.progress = progress
        super.init()
    }

    func start(_ url: URL) async throws -> URL {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 30 * 60
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session
        var request = URLRequest(url: url)
        request.setValue("doom-2016-macos", forHTTPHeaderField: "User-Agent")
        #if DEBUG
        if let authorization, !authorization.isEmpty {
            request.setValue("Bearer \(authorization)", forHTTPHeaderField: "Authorization")
        }
        #endif
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            session.downloadTask(with: request).resume()
        }
    }

    func cancel() {
        session?.invalidateAndCancel()
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : fallbackTotal
        progress(totalBytesWritten, total)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            moveError = UpdateFailure("The download failed (HTTP \(http.statusCode)).")
            return
        }
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: location, to: destination)
            downloaded = destination
        } catch {
            moveError = error
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let moveError {
            finish(.failure(moveError))
        } else if let error {
            finish(.failure(error))
        } else if let downloaded {
            finish(.success(downloaded))
        } else {
            finish(.failure(UpdateFailure("The download did not finish.")))
        }
        session.finishTasksAndInvalidate()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        var request = request
        #if DEBUG
        let host = request.url?.host?.lowercased() ?? ""
        if host != "github.com" && host != "api.github.com" {
            request.setValue(nil, forHTTPHeaderField: "Authorization")
        }
        #endif
        completionHandler(request)
    }

    private func finish(_ result: Result<URL, Error>) {
        guard !resumed else { return }
        resumed = true
        continuation?.resume(with: result)
        continuation = nil
    }
}

@MainActor
final class AppUpdateModel: ObservableObject {
    @Published var busy = false
    @Published var phase: UpdatePhase = .idle
    @Published var versionLabel = ""
    var blockReason: (() -> String?)?

    private var window: NSWindow?
    private var closeProxy: WindowClose?
    private var work: URL?
    private var verifiedApp: URL?
    private var downloader: ZipDownload?
    private var job: Task<Void, Never>?
    private var handingOff = false
    private var release: ReleaseInfo?

    func check() {
        guard !busy else { return }
        busy = true
        phase = .checking
        let current = LauncherModel.appVersion
        Task {
            let result = await UpdateFeed.load(currentVersion: current)
            self.busy = false
            self.phase = .idle
            switch result {
            case .failed(let message):
                self.alert("Could not check for an update.", message)
            case .current(let version):
                self.alert("The launcher is up to date.", "This copy is \(version).")
            case .ahead(let local, let published):
                self.alert("The launcher is up to date.", "This copy is \(local). The published release is \(published).")
            case .available(let release, let local):
                guard self.offer(release, local: local) else { return }
                if let reason = self.installBlocker() {
                    self.alert("The update cannot be installed.", reason)
                    return
                }
                self.begin(release)
            }
        }
    }

    func cancel() {
        guard !handingOff else { return }
        stopWork()
        cleanupFiles()
        phase = .idle
        busy = false
        versionLabel = ""
        window?.close()
    }

    func relaunch() {
        guard case .ready = phase, let verifiedApp, let work else { return }
        let destination = Bundle.main.bundleURL
        if let reason = installBlocker() {
            phase = .failed(reason)
            return
        }
        do {
            try spawnReplacer(pid: ProcessInfo.processInfo.processIdentifier, destination: destination, newApp: verifiedApp, work: work)
        } catch {
            phase = .failed("Could not start the installer. This copy was not changed. \(error.localizedDescription)")
            return
        }
        handingOff = true
        NSApp.terminate(nil)
    }

    func windowDidClose() {
        window = nil
        guard !handingOff else { return }
        stopWork()
        cleanupFiles()
        phase = .idle
        busy = false
        versionLabel = ""
    }

    private func begin(_ release: ReleaseInfo) {
        self.release = release
        versionLabel = release.tag
        busy = true
        phase = .downloading(received: 0, total: release.size)
        showWindow()
        job = Task { await self.download(release) }
    }

    private func download(_ release: ReleaseInfo) async {
        let work: URL
        do {
            work = try makeWork()
        } catch {
            phase = .failed("Could not create a temporary folder. \(error.localizedDescription)")
            busy = false
            return
        }
        self.work = work
        let zip = work.appendingPathComponent("update.zip")
        if release.zip.isFileURL {
            #if DEBUG
            do {
                let values = try release.zip.resourceValues(forKeys: [.fileSizeKey])
                let size = Int64(values.fileSize ?? 0)
                phase = .downloading(received: 0, total: size)
                try FileManager.default.copyItem(at: release.zip, to: zip)
                phase = .downloading(received: size, total: max(size, 1))
            } catch {
                fail("Could not read the local update zip. \(error.localizedDescription)")
                return
            }
            #else
            fail("The download link is not a GitHub release zip.")
            return
            #endif
        } else {
            let loader = ZipDownload(destination: zip, fallbackTotal: release.size) { [weak self] received, total in
                Task { @MainActor in
                    guard let self else { return }
                    switch self.phase {
                    case .downloading, .checking:
                        self.phase = .downloading(received: received, total: total)
                    default:
                        break
                    }
                }
            }
            #if DEBUG
            loader.useToken(UpdateFeed.debugToken(for: release.zip))
            #endif
            downloader = loader
            do {
                _ = try await loader.start(release.zip)
            } catch {
                if Task.isCancelled { return }
                fail("The download did not finish. \(publicMessage(error))")
                return
            }
        }
        guard !Task.isCancelled else { return }
        await unpack(zip: zip, work: work, version: release.tag)
    }

    private func unpack(zip: URL, work: URL, version: String) async {
        phase = .preparing("Unzipping \(version)…")
        let unpacked = work.appendingPathComponent("unpacked", isDirectory: true)
        let unzip = await Task.detached(priority: .userInitiated) { () -> String? in
            do {
                try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                process.arguments = ["-x", "-k", zip.path, unpacked.path]
                let pipe = Pipe()
                process.standardError = pipe
                try process.run()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    return "The zip could not be opened. \(text)"
                }
                try? FileManager.default.removeItem(at: zip)
                return nil
            } catch {
                return "The zip could not be opened. \(error.localizedDescription)"
            }
        }.value
        guard !Task.isCancelled else { return }
        if let unzip {
            fail(unzip)
            return
        }
        let app: URL
        do {
            app = try findApp(in: unpacked)
        } catch let failure as UpdateFailure {
            fail(failure.message)
            return
        } catch {
            fail(error.localizedDescription)
            return
        }
        phase = .preparing("Checking the signature…")
        let current = Bundle.main.bundleURL
        #if DEBUG
        let requireNotarization = !UpdateFeed.skipNotarization
        #else
        let requireNotarization = true
        #endif
        let outcome = await Task.detached(priority: .userInitiated) {
            BundleVerifier.check(newApp: app, currentApp: current, requireNotarization: requireNotarization)
        }.value
        guard !Task.isCancelled else { return }
        if let failure = outcome.failure {
            fail(failure)
            return
        }
        verifiedApp = app
        phase = .ready(skippedNotarization: outcome.skippedNotarization)
    }

    private func fail(_ message: String) {
        stopWork()
        cleanupFiles()
        phase = .failed(message)
        busy = false
    }

    private func stopWork() {
        job?.cancel()
        job = nil
        downloader?.cancel()
        downloader = nil
    }

    private func cleanupFiles() {
        if let work, !handingOff {
            try? FileManager.default.removeItem(at: work)
        }
        if !handingOff {
            work = nil
            verifiedApp = nil
        }
    }

    private func makeWork() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("doom2016-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func findApp(in root: URL) throws -> URL {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else {
            throw UpdateFailure("The zip did not contain the launcher.")
        }
        var found: [URL] = []
        for case let item as URL in enumerator where item.pathExtension == "app" {
            found.append(item)
            enumerator.skipDescendants()
        }
        let matches = found.filter { bundleID($0) == bundleIdentifier }
        if let match = matches.first, matches.count == 1 { return match }
        if matches.count > 1 {
            throw UpdateFailure("The zip contained more than one \(bundleIdentifier) app.")
        }
        if found.count == 1, let only = found.first { return only }
        throw UpdateFailure("The zip did not contain the launcher.")
    }

    private func bundleID(_ url: URL) -> String? {
        let plist = url.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return nil
        }
        return object["CFBundleIdentifier"] as? String
    }

    private func installBlocker() -> String? {
        if let reason = blockReason?() { return reason }
        let bundle = Bundle.main.bundleURL
        if bundle.path.contains("/AppTranslocation/") {
            return "macOS is running this copy from a locked download location, so it cannot be replaced. Move \(bundle.lastPathComponent) to a folder you choose, such as Applications, open that copy, and check for updates again."
        }
        let parent = bundle.deletingLastPathComponent()
        if !FileManager.default.isWritableFile(atPath: parent.path) {
            return "The folder that contains this launcher is not writable, so the update cannot replace it."
        }
        return nil
    }

    private func offer(_ release: ReleaseInfo, local: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Launcher \(release.tag) is available."
        alert.informativeText = "This copy is \(local)."
        let notes = release.notes.isEmpty ? "No release notes were published." : release.notes
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 440, height: 160))
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 440, height: 160))
        text.minSize = NSSize(width: 0, height: 160)
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.textContainer?.widthTracksTextView = true
        text.isEditable = false
        text.isSelectable = true
        text.font = .systemFont(ofSize: 12)
        text.string = notes
        scroll.documentView = text
        alert.accessoryView = scroll
        alert.addButton(withTitle: "Download Update")
        alert.addButton(withTitle: "Not Now")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func alert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.alertStyle = title.hasPrefix("Could not") || title.hasPrefix("The update cannot") ? .warning : .informational
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }

    private func showWindow() {
        if window == nil {
            let host = NSHostingView(rootView: UpdateWindowView().environmentObject(self))
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 480, height: 240),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Update DOOM (2016)"
            window.contentView = host
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 480, height: 240))
            window.minSize = NSSize(width: 420, height: 200)
            let proxy = WindowClose()
            proxy.owner = self
            window.delegate = proxy
            closeProxy = proxy
            window.center()
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func publicMessage(_ error: Error) -> String {
        if let failure = error as? UpdateFailure { return failure.message }
        let text = error.localizedDescription
        if text.count > 240 { return String(text.prefix(240)) }
        return text
    }

    private func spawnReplacer(pid: Int32, destination: URL, newApp: URL, work: URL) throws {
        let script = work.appendingPathComponent("relaunch.sh")
        try replacerScript.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [
            "-c",
            "mkdir -p \"$HOME/Library/Application Support/DOOM 2016\" && nohup /bin/bash \"$1\" \"$2\" \"$3\" \"$4\" \"$5\" >>\"$HOME/Library/Application Support/DOOM 2016/update.log\" 2>&1 &",
            "bash",
            script.path,
            String(pid),
            destination.path,
            newApp.path,
            work.path,
        ]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdateFailure("The installer did not start.")
        }
    }
}

#if DEBUG
private extension ZipDownload {
    func useToken(_ token: String?) {
        authorization = token
    }
}
#endif

private let replacerScript = """
#!/bin/bash
set -u
PID="$1"
DEST="$2"
NEW="$3"
WORK="$4"
LOG="$HOME/Library/Application Support/DOOM 2016/update.log"
mkdir -p "$(dirname "$LOG")"
say() { printf '%s\\n' "$*" >>"$LOG"; }

case "$DEST" in
  *.app) ;;
  *) say "Refusing to replace $DEST."; exit 1 ;;
esac
case "$NEW" in
  *.app) ;;
  *) say "The new copy is not an app."; exit 1 ;;
esac

say "Waiting for launcher $PID to exit."
for _ in $(seq 1 300); do
  if ! kill -0 "$PID" 2>/dev/null; then
    break
  fi
  sleep 0.2
done
if kill -0 "$PID" 2>/dev/null; then
  say "The launcher did not exit. The installed copy was not changed."
  exit 1
fi
sleep 0.5

PARENT="$(dirname "$DEST")"
BASE="$(basename "$DEST")"
STAGE="$PARENT/.$BASE.installing"
BACKUP="$PARENT/.$BASE.previous"

restore() {
  if [[ ! -e "$DEST" && -d "$BACKUP" ]]; then
    mv "$BACKUP" "$DEST" || say "Could not restore the previous launcher."
  fi
}

rm -rf "$STAGE"
if ! /usr/bin/ditto "$NEW" "$STAGE"; then
  say "Could not copy the new launcher beside the current one. The installed copy was not changed."
  rm -rf "$STAGE"
  exit 1
fi

if [[ -d "$DEST" ]]; then
  rm -rf "$BACKUP"
  moved=0
  for _ in $(seq 1 10); do
    if mv "$DEST" "$BACKUP"; then
      moved=1
      break
    fi
    sleep 0.3
  done
  if [[ "$moved" -ne 1 ]]; then
    say "Could not move the current launcher aside. It was left in place."
    rm -rf "$STAGE"
    exit 1
  fi
fi

if ! mv "$STAGE" "$DEST"; then
  say "Could not move the new launcher into place. Restoring the previous copy."
  restore
  rm -rf "$STAGE"
  exit 1
fi

if xattr -lr "$DEST" 2>/dev/null | grep -q 'com\\.apple\\.quarantine'; then
  xattr -dr com.apple.quarantine "$DEST" || say "Could not clear quarantine on the new launcher."
fi

if ! open "$DEST"; then
  say "The new launcher is installed at $DEST but did not open. The previous copy is at $BACKUP."
  exit 1
fi
rm -rf "$BACKUP" "$WORK"
say "Updated $DEST."
exit 0
"""

private final class WindowClose: NSObject, NSWindowDelegate {
    weak var owner: AppUpdateModel?
    func windowWillClose(_ notification: Notification) {
        owner?.windowDidClose()
    }
}

private struct UpdateWindowView: View {
    @EnvironmentObject private var updates: AppUpdateModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(heading)
                .font(.headline)
            content
            Spacer(minLength: 0)
            buttons
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var content: some View {
        switch updates.phase {
        case .downloading(let received, let total):
            if total > 0 {
                ProgressView(value: Double(min(received, total)), total: Double(total))
            } else {
                ProgressView()
            }
            Text(byteLine(received: received, total: total))
                .font(.callout)
                .foregroundStyle(.secondary)
        case .preparing(let message):
            ProgressView()
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
        case .ready(let skipped):
            Text("The new launcher passed its checks.")
            if skipped {
                Text("Notarization was not checked. This debug feed was allowed to skip it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .failed(let message):
            ScrollView {
                Text(message)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 120)
        default:
            ProgressView()
            Text("Checking for an update…")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var buttons: some View {
        HStack {
            switch updates.phase {
            case .ready:
                Button("Update & Relaunch") { updates.relaunch() }
                    .keyboardShortcut(.defaultAction)
                Button("Cancel") { updates.cancel() }
            case .failed:
                Button("Close") { updates.cancel() }
                    .keyboardShortcut(.cancelAction)
            default:
                Button("Cancel") { updates.cancel() }
                    .keyboardShortcut(.cancelAction)
            }
            Spacer()
        }
    }

    private var heading: String {
        switch updates.phase {
        case .downloading:
            return "Downloading \(updates.versionLabel)"
        case .preparing:
            return "Checking \(updates.versionLabel)"
        case .ready:
            return "\(updates.versionLabel) is ready"
        case .failed:
            return "Update failed"
        default:
            return "Update"
        }
    }

    private func byteLine(received: Int64, total: Int64) -> String {
        let got = ByteCountFormatter.string(fromByteCount: received, countStyle: .file)
        guard total > 0 else { return got }
        let all = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
        let percent = Int((Double(min(received, total)) / Double(total) * 100).rounded())
        return "\(got) of \(all) · \(percent)%"
    }
}
