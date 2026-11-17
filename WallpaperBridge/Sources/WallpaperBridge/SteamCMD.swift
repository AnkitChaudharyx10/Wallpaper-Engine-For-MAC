import AppKit
import Foundation

enum SteamCMDError: LocalizedError {
    case notInstalled
    case installFailed(String)
    case invalidUsername
    case loginRequired
    case needsRosetta
    case downloadFailed(String)
    case outputNotFound

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "SteamCMD isn't installed yet."
        case .installFailed(let message):
            return message
        case .invalidUsername:
            return "That Steam username has characters SteamCMD won't accept."
        case .loginRequired:
            return "Steam needs you to sign in. Click “Sign in with Terminal”, finish there, then download again."
        case .needsRosetta:
            return "SteamCMD needs Rosetta on Apple Silicon. Run `softwareupdate --install-rosetta` in Terminal, then try again."
        case .downloadFailed(let message):
            return "\(message) Make sure this Steam account owns Wallpaper Engine and the item is public."
        case .outputNotFound:
            return "SteamCMD finished, but the downloaded files couldn't be found. Check the SteamCMD log."
        }
    }
}

/// Wraps Valve's SteamCMD. The app never handles your Steam password: you sign in once in
/// Terminal, SteamCMD caches the login, and later downloads reuse it.
enum SteamCMD {
    static let installerURL = URL(string: "https://steamcdn-a.akamaihd.net/client/installer/steamcmd_osx.tar.gz")!

    static func locate() -> URL? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let candidates: [URL] = [
            AppPaths.steamcmdDir.appendingPathComponent("steamcmd.sh"),
            URL(fileURLWithPath: "/opt/homebrew/bin/steamcmd"),
            URL(fileURLWithPath: "/usr/local/bin/steamcmd"),
            home.appendingPathComponent("steamcmd/steamcmd.sh"),
            home.appendingPathComponent("Steam/steamcmd.sh"),
        ]
        return candidates.first { fm.isExecutableFile(atPath: $0.path) }
    }

    /// Downloads Valve's official macOS SteamCMD bootstrap into Application Support.
    static func install() async throws -> URL {
        let (tempFile, response) = try await URLSession.shared.download(from: installerURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw SteamCMDError.installFailed("Couldn't download SteamCMD from Valve.")
        }
        let fm = FileManager.default
        let archive = AppPaths.support.appendingPathComponent("steamcmd_osx.tar.gz")
        try? fm.removeItem(at: archive)
        try fm.moveItem(at: tempFile, to: archive)
        defer { try? fm.removeItem(at: archive) }

        let status = try await ProcessRunner.run(
            URL(fileURLWithPath: "/usr/bin/tar"),
            arguments: ["-xzf", archive.path, "-C", AppPaths.steamcmdDir.path]
        )
        let script = AppPaths.steamcmdDir.appendingPathComponent("steamcmd.sh")
        guard status == 0, fm.isExecutableFile(atPath: script.path) else {
            throw SteamCMDError.installFailed("SteamCMD downloaded, but unpacking it failed.")
        }
        return script
    }

    static func isValidUsername(_ name: String) -> Bool {
        name.range(of: #"^[A-Za-z0-9_.@-]{2,64}$"#, options: .regularExpression) != nil
    }

    /// Opens Terminal running `steamcmd +login <user> +quit` so the user types their own
    /// password and Steam Guard code. SteamCMD then caches the login for later downloads.
    static func openLoginInTerminal(username: String, executable: URL) throws {
        guard isValidUsername(username) else { throw SteamCMDError.invalidUsername }
        let script = """
        #!/bin/bash
        clear
        echo "Signing in to Steam for Wallpaper Bridge."
        echo "Type your password and Steam Guard code when SteamCMD asks,"
        echo "or approve the sign-in in the Steam mobile app."
        echo
        \(shellQuote(executable.path)) +login \(shellQuote(username)) +quit
        echo
        echo "All set. Close this window and download again in Wallpaper Bridge."

        """
        let url = AppPaths.support.appendingPathComponent("steam-login.command")
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        guard NSWorkspace.shared.open(url) else {
            throw SteamCMDError.installFailed("Couldn't open Terminal.")
        }
    }

    /// Downloads one Wallpaper Engine Workshop item and returns the folder it landed in.
    static func download(itemID: String, username: String, executable: URL,
                         log: @escaping @Sendable (String) -> Void) async throws -> URL {
        guard isValidUsername(username) else { throw SteamCMDError.invalidUsername }
        let scanner = OutputScanner(log: log)
        let arguments = [
            "+login", username,
            "+workshop_download_item", String(SteamWorkshopAPI.wallpaperEngineAppID), itemID, "validate",
            "+quit",
        ]
        let status = try await ProcessRunner.run(executable, arguments: arguments) { chunk in
            scanner.consume(chunk)
        }
        try Task.checkCancellation()

        let result = scanner.snapshot()
        if result.needsRosetta { throw SteamCMDError.needsRosetta }
        if result.loginRequired { throw SteamCMDError.loginRequired }
        if let path = result.successPath, directoryHasFiles(URL(fileURLWithPath: path)) {
            return URL(fileURLWithPath: path)
        }
        if let error = result.error { throw SteamCMDError.downloadFailed(error) }
        if let found = existingDownload(itemID: itemID, executable: executable) { return found }
        if status != 0 { throw SteamCMDError.downloadFailed("SteamCMD exited with code \(status).") }
        throw SteamCMDError.outputNotFound
    }

    /// Folders SteamCMD may use as its Steam root on macOS.
    private static func steamRoots(executable: URL) -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent("Library/Application Support/Steam"),
            executable.resolvingSymlinksInPath().deletingLastPathComponent(),
            home.appendingPathComponent("Steam"),
            home.appendingPathComponent(".steam/steam"),
        ]
    }

    private static func existingDownload(itemID: String, executable: URL) -> URL? {
        let relative = "steamapps/workshop/content/\(SteamWorkshopAPI.wallpaperEngineAppID)/\(itemID)"
        return steamRoots(executable: executable)
            .map { $0.appendingPathComponent(relative) }
            .first(where: directoryHasFiles)
    }

    /// Bytes of this item SteamCMD has on disk so far (in-progress and finished folders).
    /// SteamCMD doesn't print download progress, so the app measures it this way.
    static func downloadedBytes(itemID: String, executable: URL) -> Int64 {
        let app = String(SteamWorkshopAPI.wallpaperEngineAppID)
        var best: Int64 = 0
        for root in steamRoots(executable: executable) {
            let workshop = root.appendingPathComponent("steamapps/workshop")
            let total = ["downloads", "temp", "content"].reduce(Int64(0)) { sum, stage in
                sum + folderSize(workshop.appendingPathComponent("\(stage)/\(app)/\(itemID)"))
            }
            best = max(best, total)
        }
        return best
    }

    private static func folderSize(_ url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileSizeKey, .isRegularFileKey]
        guard FileManager.default.fileExists(atPath: url.path),
              let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else { return 0 }
        var sum: Int64 = 0
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            // Allocated size grows as data arrives even if the file was pre-sized.
            sum += Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
        }
        return sum
    }

    private static func directoryHasFiles(_ url: URL) -> Bool {
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        return !contents.isEmpty
    }

    private static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Reads SteamCMD output as it streams in and picks out the lines that matter.
final class OutputScanner: @unchecked Sendable {
    struct Result {
        var successPath: String?
        var error: String?
        var loginRequired = false
        var needsRosetta = false
    }

    private let lock = NSLock()
    private var pending = ""
    private var result = Result()
    private let log: @Sendable (String) -> Void

    init(log: @escaping @Sendable (String) -> Void) {
        self.log = log
    }

    /// Returns true when SteamCMD should be stopped (it's waiting for input we can't give it).
    func consume(_ chunk: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        pending += chunk
        var lines = pending.components(separatedBy: CharacterSet(charactersIn: "\r\n"))
        pending = lines.removeLast()
        lines.forEach(handle)

        // Prompts such as "password:" have no newline after them, so check the partial line too.
        let partial = pending.lowercased()
        if partial.contains("password:") || partial.contains("steam guard code") || partial.contains("two-factor code") {
            result.loginRequired = true
            log(pending)
            pending = ""
        }
        return result.loginRequired || result.needsRosetta
    }

    func snapshot() -> Result {
        lock.lock()
        defer { lock.unlock() }
        return result
    }

    private func handle(_ raw: String) {
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return }
        log(line)

        if line.hasPrefix("Success. Downloaded item"),
           let open = line.firstIndex(of: "\""),
           let close = line.lastIndex(of: "\""),
           open < close {
            result.successPath = String(line[line.index(after: open)..<close])
        } else if line.hasPrefix("ERROR!") || (line.contains("FAILED (") && result.error == nil) {
            result.error = line
        }

        let lower = line.lowercased()
        let loginHints = ["cached credentials not found", "invalid password", "login failure",
                          "account logon denied", "password:", "steam guard code", "two-factor code"]
        if loginHints.contains(where: { lower.contains($0) }) { result.loginRequired = true }
        if lower.contains("bad cpu type") { result.needsRosetta = true }
    }
}

enum ProcessRunner {
    /// Runs a process, streaming combined stdout/stderr to `onOutput` on a background queue.
    /// Return true from `onOutput` to stop the process early. Cancelling the task stops it too.
    static func run(_ executable: URL, arguments: [String],
                    onOutput: @escaping @Sendable (String) -> Bool = { _ in false }) async throws -> Int32 {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            if onOutput(String(decoding: data, as: UTF8.self)) {
                ProcessRunner.terminateTree(process)
            }
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
                process.terminationHandler = { finished in
                    pipe.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(returning: finished.terminationStatus)
                }
                do {
                    try process.run()
                } catch {
                    pipe.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            ProcessRunner.terminateTree(process)
        }
    }

    /// steamcmd.sh launches the real steamcmd binary as a child, so stop the children too.
    private static func terminateTree(_ process: Process) {
        guard process.isRunning else { return }
        let pkill = Process()
        pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        pkill.arguments = ["-TERM", "-P", String(process.processIdentifier)]
        try? pkill.run()
        pkill.waitUntilExit()
        if process.isRunning { process.terminate() }
    }
}
