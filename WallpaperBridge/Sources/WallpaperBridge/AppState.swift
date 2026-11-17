import AppKit
import ServiceManagement
import SwiftUI

struct DownloadProgress: Equatable {
    var phase: String
    /// 0...1, or nil while the amount of work isn't known.
    var fraction: Double?
    var detail: String?
}

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var linkText = ""
    @Published private(set) var library: [WallpaperItem] = []
    @Published private(set) var status: String?
    @Published private(set) var statusIsError = false
    @Published private(set) var isWorking = false
    @Published private(set) var isDownloading = false
    @Published private(set) var progress: DownloadProgress?
    @Published private(set) var needsSteamLogin = false
    @Published private(set) var logLines: [String] = []
    @Published private(set) var steamcmdPath: URL?
    @Published private(set) var currentID: String?
    @Published private(set) var isLive = false
    @Published private(set) var isPaused = false

    @Published var isMuted: Bool {
        didSet {
            desktop.isMuted = isMuted
            defaults.set(isMuted, forKey: Keys.muted)
        }
    }

    @Published var setsLockScreen: Bool {
        didSet {
            desktop.setsLockScreen = setsLockScreen
            defaults.set(setsLockScreen, forKey: Keys.lockScreen)
            desktop.refreshStill()
        }
    }

    @Published var steamUsername: String {
        didSet { defaults.set(steamUsername, forKey: Keys.username) }
    }

    @Published var cursorResponsive: Bool {
        didSet {
            defaults.set(cursorResponsive, forKey: Keys.cursor)
            desktop.cursorResponsive = cursorResponsive
        }
    }

    @Published var audioResponsive: Bool {
        didSet {
            defaults.set(audioResponsive, forKey: Keys.audio)
            audioError = nil
            desktop.audioResponsive = audioResponsive
        }
    }

    @Published private(set) var audioError: String? = nil
    /// The current web wallpaper asked for audio (it has a visualizer or similar).
    @Published private(set) var currentWantsAudio = false

    private let desktop = DesktopController()
    private let defaults = UserDefaults.standard
    private var downloadTask: Task<Void, Never>?
    private var transferSample: (bytes: Int64, time: Date)?
    private var transferSpeed: Double = 0
    private var transferBaseline: Int64 = 0

    private enum Keys {
        static let username = "steamUsername"
        static let muted = "muted"
        static let lockScreen = "setsLockScreen"
        static let current = "currentWallpaperID"
        static let steamcmd = "steamcmdPath"
        static let cursor = "cursorResponsive"
        static let audio = "audioResponsive"
    }

    init() {
        steamUsername = defaults.string(forKey: Keys.username) ?? ""
        isMuted = defaults.object(forKey: Keys.muted) as? Bool ?? true
        setsLockScreen = defaults.object(forKey: Keys.lockScreen) as? Bool ?? true
        cursorResponsive = defaults.object(forKey: Keys.cursor) as? Bool ?? true
        audioResponsive = defaults.object(forKey: Keys.audio) as? Bool ?? false
        if let custom = defaults.string(forKey: Keys.steamcmd),
           FileManager.default.isExecutableFile(atPath: custom) {
            steamcmdPath = URL(fileURLWithPath: custom)
        } else {
            steamcmdPath = SteamCMD.locate()
        }
        library = Self.loadLibrary()
        desktop.isMuted = isMuted
        desktop.setsLockScreen = setsLockScreen
        desktop.cursorResponsive = cursorResponsive
        desktop.audioResponsive = audioResponsive
        desktop.onAudioError = { [weak self] message in
            self?.audioError = message
        }
        desktop.onPageWantsAudio = { [weak self] in
            self?.currentWantsAudio = true
        }
    }

    var currentEffects: EffectSettings {
        currentItem?.effectSettings ?? .off
    }

    func updateEffects(_ effects: EffectSettings) {
        guard let id = currentID, let index = library.firstIndex(where: { $0.id == id }) else { return }
        library[index].effects = effects.isActive ? effects : nil
        desktop.updateEffects(effects)
        isLive = desktop.isLive
        saveLibrary()
    }

    func openPrivacySettings() {
        NSWorkspace.shared.open(AudioCapture.privacySettingsURL)
    }

    var currentItem: WallpaperItem? {
        library.first { $0.id == currentID }
    }

    var currentFit: FitSettings {
        currentItem?.fitSettings ?? .standard
    }

    var launchAtLogin: Bool {
        SMAppService.mainApp.status == .enabled
    }

    // MARK: - Downloading

    func startDownload() {
        guard !isWorking else { return }
        guard let id = WorkshopLink.itemID(from: linkText) else {
            return report("That doesn't look like a Steam Workshop link.", error: true)
        }
        let username = steamUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty else {
            return report("Add your Steam username under Settings first.", error: true)
        }
        guard let steamcmd = steamcmdPath else {
            return report("Install SteamCMD first.", error: true)
        }

        isWorking = true
        isDownloading = true
        needsSteamLogin = false
        logLines.removeAll()
        status = nil
        downloadTask = Task {
            await download(id: id, username: username, steamcmd: steamcmd)
            isWorking = false
            isDownloading = false
            progress = nil
            downloadTask = nil
        }
    }

    func cancelDownload() {
        downloadTask?.cancel()
    }

    private func download(id: String, username: String, steamcmd: URL) async {
        do {
            progress = DownloadProgress(phase: "Looking up item \(id)…")
            let details = try await SteamWorkshopAPI.details(for: id)
            guard details.appID == SteamWorkshopAPI.wallpaperEngineAppID else {
                return report("“\(details.title)” isn't a Wallpaper Engine item.", error: true)
            }

            progress = DownloadProgress(phase: "Starting SteamCMD…")
            transferSample = nil
            transferSpeed = 0
            transferBaseline = await Task.detached {
                SteamCMD.downloadedBytes(itemID: id, executable: steamcmd)
            }.value

            // Watch the files grow on disk to show how far along the download is.
            let total = details.fileSize
            let monitor = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    let bytes = await Task.detached {
                        SteamCMD.downloadedBytes(itemID: id, executable: steamcmd)
                    }.value
                    guard !Task.isCancelled else { return }
                    self?.updateTransfer(bytes: bytes, total: total)
                }
            }
            defer { monitor.cancel() }

            let folder = try await SteamCMD.download(itemID: id, username: username, executable: steamcmd) { [weak self] line in
                Task { @MainActor in self?.appendLog(line) }
            }
            monitor.cancel()

            progress = DownloadProgress(phase: "Copying into your library…")
            let previous = library.first { $0.id == id }
            if currentID == id { stop() }  // its files are about to be replaced
            let title = details.title
            var item = try await Task.detached(priority: .userInitiated) {
                try WallpaperImporter.importFolder(folder, id: id, fallbackTitle: title)
            }.value
            item.fit = previous?.fit
            item.effects = previous?.effects
            ThumbnailCache.clear()
            upsert(item)
            linkText = ""

            progress = DownloadProgress(phase: "Applying…", fraction: 1)
            if item.kind.isSupported {
                try applyItem(item)
                report(item.kind == .scene && item.stillFile == nil
                       ? "Showing “\(item.title)” (scene preview only)."
                       : "Now showing “\(item.title)”.")
            } else {
                report("Downloaded “\(item.title)”, but \(item.kind.label) wallpapers can't run on macOS.", error: true)
            }
        } catch is CancellationError {
            report("Download cancelled.")
        } catch SteamCMDError.loginRequired {
            needsSteamLogin = true
            report(SteamCMDError.loginRequired.localizedDescription, error: true)
        } catch {
            report(Task.isCancelled ? "Download cancelled." : error.localizedDescription, error: !Task.isCancelled)
        }
    }

    private func updateTransfer(bytes: Int64, total: Int64?) {
        guard isDownloading, progress?.phase.hasPrefix("Copying") != true else { return }
        let now = Date()
        if let sample = transferSample {
            let seconds = now.timeIntervalSince(sample.time)
            if seconds > 0 {
                let instant = Double(max(bytes - sample.bytes, 0)) / seconds
                transferSpeed = transferSpeed == 0 ? instant : transferSpeed * 0.7 + instant * 0.3
            }
        }
        transferSample = (bytes, now)

        // Nothing new on disk yet: keep showing whatever phase SteamCMD's output gave us.
        guard bytes > transferBaseline else { return }

        let format: (Int64) -> String = { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
        var detail = format(bytes)
        var fraction: Double?
        if let total, total > 0 {
            fraction = min(Double(bytes) / Double(total), 0.99)
            detail = "\(format(min(bytes, total))) of \(format(total))"
        }
        if transferSpeed > 1024 {
            detail += " · \(format(Int64(transferSpeed)))/s"
        }
        progress = DownloadProgress(phase: "Downloading…", fraction: fraction, detail: detail)
    }

    /// Turns SteamCMD's output into a readable phase while nothing is arriving on disk yet.
    private func updatePhase(from line: String) {
        guard isDownloading, progress?.phase != "Downloading…" || progress?.fraction == nil else { return }
        if let match = line.range(of: #"^\[\s*(\d{1,3})%\]"#, options: .regularExpression) {
            let digits = line[match].filter(\.isNumber)
            if let percent = Double(digits) {
                progress = DownloadProgress(phase: "Updating SteamCMD…", fraction: percent / 100,
                                            detail: "First run only")
            }
        } else if line.contains("Logging in user") || line.contains("Waiting for user info") {
            progress = DownloadProgress(phase: "Signing in to Steam…")
        } else if line.hasPrefix("Downloading item") {
            progress = DownloadProgress(phase: "Downloading…")
        }
    }

    // MARK: - SteamCMD setup

    func installSteamCMD() {
        guard !isWorking else { return }
        isWorking = true
        progress = DownloadProgress(phase: "Downloading SteamCMD from Valve…")
        Task {
            do {
                steamcmdPath = try await SteamCMD.install()
                defaults.removeObject(forKey: Keys.steamcmd)
                report("SteamCMD installed. It updates itself the first time it runs, so the first download is slower.")
            } catch {
                report(error.localizedDescription, error: true)
            }
            progress = nil
            isWorking = false
        }
    }

    func chooseSteamCMD() {
        let panel = NSOpenPanel()
        panel.title = "Choose steamcmd or steamcmd.sh"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            return report("That file isn't something SteamCMD can run from.", error: true)
        }
        steamcmdPath = url
        defaults.set(url.path, forKey: Keys.steamcmd)
        report("Using SteamCMD at \(url.path).")
    }

    func openSteamLogin() {
        guard let steamcmd = steamcmdPath else {
            return report("Install SteamCMD first.", error: true)
        }
        let username = steamUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty else {
            return report("Add your Steam username under Settings first.", error: true)
        }
        do {
            try SteamCMD.openLoginInTerminal(username: username, executable: steamcmd)
            needsSteamLogin = false
            report("Finish signing in in Terminal, then download again.")
        } catch {
            report(error.localizedDescription, error: true)
        }
    }

    // MARK: - Wallpapers

    func select(_ item: WallpaperItem) {
        do {
            try applyItem(item)
            report("Now showing “\(item.title)”.")
        } catch {
            report(error.localizedDescription, error: true)
        }
    }

    func updateFit(_ fit: FitSettings) {
        guard let id = currentID, let index = library.firstIndex(where: { $0.id == id }) else { return }
        library[index].fit = fit == .standard ? nil : fit
        desktop.updateFit(fit)
        saveLibrary()
    }

    func restoreLastWallpaper() {
        guard let id = defaults.string(forKey: Keys.current),
              let item = library.first(where: { $0.id == id }) else { return }
        try? applyItem(item)
    }

    func stop() {
        desktop.stop()
        currentWantsAudio = false
        currentID = nil
        isLive = false
        isPaused = false
        defaults.removeObject(forKey: Keys.current)
    }

    func togglePause() {
        desktop.togglePause()
        isPaused = desktop.isPaused
    }

    func delete(_ item: WallpaperItem) {
        if currentID == item.id { stop() }
        try? FileManager.default.removeItem(at: item.folder)
        library.removeAll { $0.id == item.id }
        ThumbnailCache.clear()
        saveLibrary()
    }

    func showInFinder(_ item: WallpaperItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.folder])
    }

    func openWorkshopPage(_ item: WallpaperItem) {
        NSWorkspace.shared.open(item.workshopURL)
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            report("Couldn't change Open at Login: \(error.localizedDescription)", error: true)
        }
        objectWillChange.send()
    }

    private func applyItem(_ item: WallpaperItem) throws {
        currentWantsAudio = false
        try desktop.apply(item)
        currentID = item.id
        isLive = desktop.isLive
        isPaused = false
        defaults.set(item.id, forKey: Keys.current)
    }

    // MARK: - Helpers

    private func appendLog(_ line: String) {
        logLines.append(line)
        if logLines.count > 300 { logLines.removeFirst(logLines.count - 300) }
        updatePhase(from: line)
    }

    private func report(_ text: String, error: Bool = false) {
        status = text
        statusIsError = error
    }

    private func upsert(_ item: WallpaperItem) {
        library.removeAll { $0.id == item.id }
        library.insert(item, at: 0)
        saveLibrary()
    }

    private static func loadLibrary() -> [WallpaperItem] {
        guard let data = try? Data(contentsOf: AppPaths.libraryIndex) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let items = (try? decoder.decode([WallpaperItem].self, from: data)) ?? []
        return items.filter { FileManager.default.fileExists(atPath: $0.folder.path) }
    }

    private func saveLibrary() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(library) else { return }
        try? data.write(to: AppPaths.libraryIndex, options: .atomic)
    }
}

/// Library thumbnails, decoded once.
enum ThumbnailCache {
    private static let cache = NSCache<NSURL, NSImage>()

    static func image(for url: URL) -> NSImage? {
        if let hit = cache.object(forKey: url as NSURL) { return hit }
        guard let image = NSImage(contentsOf: url) else { return nil }
        cache.setObject(image, forKey: url as NSURL)
        return image
    }

    static func clear() {
        cache.removeAllObjects()
    }
}
