import AppKit
import AVFoundation
import ImageIO
import WebKit

/// Shows wallpapers on the desktop. Live wallpapers (videos, web wallpapers, and pictures with
/// effects) run in a WebKit view inside a borderless window at desktop level, behind the icons,
/// on every Space and screen. The app feeds those pages the cursor position and system-audio
/// levels. Underneath, a still picture rendered at each screen's exact size is set as the
/// macOS desktop picture, which macOS also uses for the lock screen.
@MainActor
final class DesktopController {
    enum ApplyError: LocalizedError {
        case unsupported(WallpaperKind)
        case missingFile

        var errorDescription: String? {
            switch self {
            case .unsupported(.application):
                return "This wallpaper is a Windows program, so it can't run on macOS."
            case .unsupported(let kind):
                return "\(kind.label) wallpapers can't be shown on macOS."
            case .missingFile:
                return "This wallpaper's files are missing. Try downloading it again."
            }
        }
    }

    private(set) var current: WallpaperItem?
    private(set) var isPaused = false
    var isMuted = true { didSet { applyMute() } }
    /// Also set a matching still (video frame or preview) as the desktop/lock screen picture
    /// for live wallpapers. Still wallpapers always set it.
    var setsLockScreen = true
    var cursorResponsive = true { didSet { updatePump() } }
    var audioResponsive = false { didSet { updateAudio() } }
    var isLive: Bool { !surfaces.isEmpty }

    var onAudioError: (@MainActor (String) -> Void)?
    var onPageWantsAudio: (@MainActor () -> Void)?

    private struct Surface {
        let window: NSWindow
        let webView: WKWebView
        let screenFrame: NSRect
    }

    private struct LivePage {
        let url: URL
        let folder: URL
        let properties: String?
    }

    private var surfaces: [Surface] = []
    private var stillTask: Task<Void, Never>?
    /// Screen ID → rendered desktop picture currently in use.
    private var desktopPictures: [String: URL] = [:]
    private var observers: [NSObjectProtocol] = []

    private let audio = AudioCapture()
    private var audioStarting = false
    private var pageWantsAudio = false
    private var pump: Timer?
    private var lastMouse: NSPoint?
    private var sentSilence = false
    private lazy var messageHandler = BridgeMessageHandler { [weak self] message in
        self?.handleMessage(message)
    }

    init() {
        StillRenderer.removeUnusedRenders()

        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reapply() }
        })

        let workspace = NSWorkspace.shared.notificationCenter
        // macOS keeps one desktop picture per Space; set ours again when you switch Spaces.
        observers.append(workspace.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reassertDesktopPictures() }
        })
        // Stop playing while the displays are asleep.
        observers.append(workspace.addObserver(
            forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.setPlaying(false) }
        })
        observers.append(workspace.addObserver(
            forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.isPaused else { return }
                self.setPlaying(true)
            }
        })
    }

    // MARK: - Applying

    func apply(_ item: WallpaperItem) throws {
        let page = try livePage(for: item)
        tearDown()
        pageWantsAudio = false
        if let page {
            for screen in NSScreen.screens {
                addSurface(on: screen, page: page, effects: item.effectSettings)
            }
        }
        current = item
        isPaused = false
        updatePump()
        updateAudio()
        scheduleStill(delay: 0)
    }

    /// Live update while the user drags the Adjust sliders.
    func updateFit(_ fit: FitSettings) {
        guard var item = current else { return }
        item.fit = fit
        current = item
        runScript("window.__bridgeSetFit && window.__bridgeSetFit(\(fit.json))")
        // Re-rendering the still is heavier, so wait until the sliders settle.
        scheduleStill(delay: 0.35)
    }

    /// Live update while the user changes effects.
    func updateEffects(_ effects: EffectSettings) {
        guard var item = current else { return }
        item.effects = effects
        if needsLiveWindow(item) != isLive {
            // A still picture just gained (or lost) its effects window.
            let wasPaused = isPaused
            try? apply(item)
            if wasPaused { togglePause() }
            return
        }
        current = item
        runScript("window.__bridgeSetEffects && window.__bridgeSetEffects(\(effects.json))")
        updatePump()
        updateAudio()
    }

    func stop() {
        stillTask?.cancel()
        tearDown()
        current = nil
        isPaused = false
        desktopPictures = [:]
        updatePump()
        updateAudio()
    }

    func togglePause() {
        isPaused.toggle()
        setPlaying(!isPaused)
        updatePump()
        updateAudio()
    }

    func refreshStill() {
        scheduleStill(delay: 0)
    }

    private func needsLiveWindow(_ item: WallpaperItem) -> Bool {
        switch item.kind {
        case .video, .web:
            return true
        case .scene, .image:
            let animatedPreview = item.stillURL == nil && item.previewURL?.pathExtension.lowercased() == "gif"
            return animatedPreview || item.effectSettings.isActive
        case .application, .unknown:
            return false
        }
    }

    /// The page to show live for this wallpaper, or nil when a desktop picture is enough.
    private func livePage(for item: WallpaperItem) throws -> LivePage? {
        switch item.kind {
        case .video:
            guard item.mainURL != nil, let relative = item.mainFile else { throw ApplyError.missingFile }
            let url = try writeStagePage(media: relative, isVideo: true, item: item)
            return LivePage(url: url, folder: item.folder, properties: nil)

        case .web:
            guard let url = item.mainURL else { throw ApplyError.missingFile }
            return LivePage(url: url, folder: item.folder, properties: WebBridge.userProperties(in: item.folder))

        case .scene, .image:
            let picture: String?
            if item.stillURL != nil {
                picture = item.stillFile
            } else if item.previewURL != nil {
                picture = item.previewFile
            } else {
                picture = nil
            }
            guard let relative = picture else { throw ApplyError.missingFile }
            guard needsLiveWindow(item) else { return nil }
            let url = try writeStagePage(media: relative, isVideo: false, item: item)
            return LivePage(url: url, folder: item.folder, properties: nil)

        case .application, .unknown:
            throw ApplyError.unsupported(item.kind)
        }
    }

    private func writeStagePage(media relativePath: String, isVideo: Bool, item: WallpaperItem) throws -> URL {
        let html = WebBridge.stagePage(media: relativePath, isVideo: isVideo, fit: item.fitSettings)
        let url = item.folder.appendingPathComponent("_bridge_player.html")
        try html.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Cursor and audio

    private var needsCursor: Bool {
        cursorResponsive && isLive && !isPaused
    }

    private var needsAudio: Bool {
        guard audioResponsive, isLive, !isPaused, let current else { return false }
        return pageWantsAudio || current.effectSettings.usesAudio
    }

    /// One timer sends the cursor position and audio levels to every live page.
    private func updatePump() {
        let wanted = needsCursor || audio.isRunning
        if wanted, pump == nil {
            let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.sendFrame() }
            }
            RunLoop.main.add(timer, forMode: .common)
            pump = timer
        } else if !wanted {
            pump?.invalidate()
            pump = nil
            lastMouse = nil
        }
    }

    private func updateAudio() {
        if needsAudio {
            guard !audio.isRunning, !audioStarting else { return }
            audioStarting = true
            Task {
                do {
                    try await audio.start()
                } catch {
                    onAudioError?(AudioCapture.describe(error))
                }
                audioStarting = false
                if !needsAudio { audio.stop() }
                updatePump()
            }
        } else if audio.isRunning {
            audio.stop()
            sentSilence = false
            updatePump()
            let silence = "[" + Array(repeating: "0", count: SpectrumAnalyzer.bandCount * 2).joined(separator: ",") + "]"
            runScript("window.__bridgeFrame && window.__bridgeFrame(null, null, \(silence))")
        }
    }

    private func sendFrame() {
        guard isLive else { return }

        var bands = "null"
        if audio.isRunning {
            let levels = audio.latestBands()
            let silent = levels.allSatisfy { $0 < 0.005 }
            if !(silent && sentSilence) {
                bands = "[" + levels.map { String(format: "%.3f", $0) }.joined(separator: ",") + "]"
            }
            sentSilence = silent
        }

        let mouse = NSEvent.mouseLocation
        let mouseMoved = needsCursor && mouse != lastMouse
        if mouseMoved { lastMouse = mouse }
        guard mouseMoved || bands != "null" else { return }

        for surface in surfaces {
            var coordinates = "null, null"
            if mouseMoved {
                // Page coordinates start at the top-left of that screen.
                let x = mouse.x - surface.screenFrame.minX
                let y = surface.screenFrame.maxY - mouse.y
                coordinates = String(format: "%.1f, %.1f", x, y)
            }
            surface.webView.evaluateJavaScript(
                "window.__bridgeFrame && window.__bridgeFrame(\(coordinates), \(bands))",
                completionHandler: nil
            )
        }
    }

    private func handleMessage(_ message: String) {
        guard message == "audio", !pageWantsAudio else { return }
        pageWantsAudio = true
        onPageWantsAudio?()
        updateAudio()
    }

    // MARK: - Desktop / lock screen picture

    private func scheduleStill(delay: Double) {
        stillTask?.cancel()
        stillTask = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            guard !Task.isCancelled else { return }
            await self?.applyStill()
        }
    }

    private func applyStill() async {
        guard let item = current, let image = await stillImage(for: item) else { return }
        guard !Task.isCancelled, current?.id == item.id else { return }

        let fit = current?.fitSettings ?? item.fitSettings
        let targets = NSScreen.screens.map { screen in
            StillRenderer.Target(
                screenID: Self.screenID(screen),
                pixelSize: CGSize(width: screen.frame.width * screen.backingScaleFactor,
                                  height: screen.frame.height * screen.backingScaleFactor)
            )
        }
        let renders = await Task.detached(priority: .userInitiated) {
            StillRenderer.render(image, targets: targets, fit: fit)
        }.value

        guard !Task.isCancelled, current?.id == item.id else {
            renders.values.forEach { try? FileManager.default.removeItem(at: $0) }
            return
        }
        for screen in NSScreen.screens {
            guard let url = renders[Self.screenID(screen)] else { continue }
            try? NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: StillRenderer.pictureOptions)
        }
        let replaced = desktopPictures.values.filter { !renders.values.contains($0) }
        desktopPictures = renders
        replaced.forEach { try? FileManager.default.removeItem(at: $0) }
    }

    private func stillImage(for item: WallpaperItem) async -> CGImage? {
        switch item.kind {
        case .scene, .image:
            return (item.stillURL ?? item.previewURL).flatMap(StillRenderer.loadImage)
        case .video:
            guard setsLockScreen else { return nil }
            if let url = item.mainURL, StillRenderer.isNativeVideo(url),
               let frame = await StillRenderer.videoFrame(url) {
                return frame
            }
            return item.previewURL.flatMap(StillRenderer.loadImage)
        case .web:
            guard setsLockScreen else { return nil }
            return item.previewURL.flatMap(StillRenderer.loadImage)
        case .application, .unknown:
            return nil
        }
    }

    private func reassertDesktopPictures() {
        guard current != nil else { return }
        for screen in NSScreen.screens {
            guard let url = desktopPictures[Self.screenID(screen)],
                  NSWorkspace.shared.desktopImageURL(for: screen)?.standardizedFileURL.path != url.standardizedFileURL.path
            else { continue }
            try? NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: StillRenderer.pictureOptions)
        }
    }

    private static func screenID(_ screen: NSScreen) -> String {
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        return number?.stringValue ?? screen.localizedName
    }

    // MARK: - Windows

    private func addSurface(on screen: NSScreen, page: LivePage, effects: EffectSettings) {
        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = []
        let controller = config.userContentController
        controller.add(messageHandler, name: "bridge")
        controller.addUserScript(WKUserScript(
            source: WebBridge.script(properties: page.properties, muted: isMuted, effects: effects),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))

        let webView = WKWebView(frame: NSRect(origin: .zero, size: screen.frame.size), configuration: config)
        webView.loadFileURL(page.url, allowingReadAccessTo: page.folder)

        let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.ignoresMouseEvents = true
        window.isOpaque = true
        window.hasShadow = false
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false
        window.contentView = webView
        window.setFrame(screen.frame, display: false)
        window.orderFrontRegardless()

        surfaces.append(Surface(window: window, webView: webView, screenFrame: screen.frame))
    }

    private func tearDown() {
        for surface in surfaces {
            surface.webView.stopLoading()
            surface.webView.loadHTMLString("", baseURL: nil)
            surface.webView.configuration.userContentController.removeScriptMessageHandler(forName: "bridge")
            surface.window.orderOut(nil)
            surface.window.contentView = nil
            surface.window.close()
        }
        surfaces.removeAll()
        lastMouse = nil
        sentSilence = false
    }

    private func reapply() {
        guard let current else { return }
        let wasPaused = isPaused
        try? apply(current)
        if wasPaused { togglePause() }
    }

    private func setPlaying(_ playing: Bool) {
        for surface in surfaces {
            surface.webView.setAllMediaPlaybackSuspended(!playing, completionHandler: nil)
        }
        runScript("window.__bridgePause && window.__bridgePause(\(!playing))")
    }

    private func applyMute() {
        runScript("window.__bridgeSetMuted && window.__bridgeSetMuted(\(isMuted))")
    }

    private func runScript(_ script: String) {
        for surface in surfaces {
            surface.webView.evaluateJavaScript(script, completionHandler: nil)
        }
    }
}

/// Receives messages the injected script posts (for now: "a web wallpaper wants audio").
@MainActor
final class BridgeMessageHandler: NSObject, WKScriptMessageHandler {
    private let onMessage: @MainActor (String) -> Void

    init(_ onMessage: @escaping @MainActor (String) -> Void) {
        self.onMessage = onMessage
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        if let text = message.body as? String { onMessage(text) }
    }
}

/// Renders still pictures at each screen's exact pixel size.
enum StillRenderer {
    struct Target: Sendable {
        let screenID: String
        let pixelSize: CGSize
    }

    static let pictureOptions: [NSWorkspace.DesktopImageOptionKey: Any] = [
        .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
        .allowClipping: true,
    ]

    static func isNativeVideo(_ url: URL) -> Bool {
        ["mp4", "m4v", "mov"].contains(url.pathExtension.lowercased())
    }

    static func loadImage(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// A frame from about one second in (the very first frame is often black).
    static func videoFrame(_ url: URL) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        for seconds in [1.0, 0.0] {
            if let result = try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)) {
                return result.image
            }
        }
        return nil
    }

    static func render(_ image: CGImage, targets: [Target], fit: FitSettings) -> [String: URL] {
        var result: [String: URL] = [:]
        for target in targets {
            let url = AppPaths.rendered.appendingPathComponent("\(target.screenID)-\(UUID().uuidString).png")
            if render(image, pixelSize: target.pixelSize, fit: fit, to: url) {
                result[target.screenID] = url
            }
        }
        return result
    }

    private static func render(_ image: CGImage, pixelSize: CGSize, fit: FitSettings, to url: URL) -> Bool {
        let width = Int(pixelSize.width.rounded())
        let height = Int(pixelSize.height.rounded())
        guard width > 0, height > 0,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }

        let canvas = CGSize(width: width, height: height)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(origin: .zero, size: canvas))
        context.interpolationQuality = .high

        var rect = fit.frame(content: CGSize(width: image.width, height: image.height), container: canvas)
        rect.origin.y = canvas.height - rect.maxY  // CoreGraphics measures from the bottom
        context.draw(image, in: rect)

        guard let output = context.makeImage(),
              let data = NSBitmapImageRep(cgImage: output).representation(using: .png, properties: [:]) else {
            return false
        }
        return (try? data.write(to: url, options: .atomic)) != nil
    }

    /// Deletes old renders, keeping any that a screen is still showing.
    @MainActor
    static func removeUnusedRenders() {
        let inUse = Set(NSScreen.screens.compactMap {
            NSWorkspace.shared.desktopImageURL(for: $0)?.standardizedFileURL.path
        })
        let files = (try? FileManager.default.contentsOfDirectory(
            at: AppPaths.rendered, includingPropertiesForKeys: nil)) ?? []
        for file in files where !inUse.contains(file.standardizedFileURL.path) {
            try? FileManager.default.removeItem(at: file)
        }
    }
}
