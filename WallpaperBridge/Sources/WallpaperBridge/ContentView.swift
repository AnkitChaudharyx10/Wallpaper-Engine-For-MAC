import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var state: AppState
    @State private var showSettings = false
    @State private var showLog = false
    @State private var showAdjust = false
    @State private var showEffects = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header
                downloadRow
                if state.steamcmdPath == nil { setupCard }
                if state.needsSteamLogin { loginCard }
                if let progress = state.progress { progressRow(progress) }
                statusRow
                if let item = state.currentItem {
                    nowShowing(item)
                    if state.currentWantsAudio && !state.audioResponsive { audioHint }
                    if item.supportsFit { adjustPanel }
                    if item.kind.isSupported { effectsPanel }
                }
                Divider()
                libraryGrid
                Divider()
                footer
            }
            .padding(14)
        }
        .frame(width: 420, height: 660)
        .onAppear {
            if state.steamUsername.isEmpty { showSettings = true }
        }
    }

    private var audioHint: some View {
        Card(tint: .purple) {
            Text("This wallpaper reacts to music. Turn on “React to audio” to let it hear what's playing.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Button("Turn On React to Audio") { state.audioResponsive = true }
        }
    }

    private var effectsPanel: some View {
        DisclosureGroup("Effects", isExpanded: $showEffects) {
            VStack(alignment: .leading, spacing: 8) {
                sectionLabel("Particles")
                Picker("Particles", selection: effectBinding(\.particles)) {
                    ForEach(ParticleEffect.allCases) { effect in
                        Text(effect.label).tag(effect)
                    }
                }
                .labelsHidden()
                sliderRow("Amount", value: effectBinding(\.particleAmount), range: 0.1...1,
                          enabled: state.currentEffects.particles != .off) {
                    "\(Int((state.currentEffects.particleAmount * 100).rounded()))%"
                }

                sectionLabel("Cursor")
                sliderRow("Parallax", value: effectBinding(\.parallax), range: 0...1, enabled: true) {
                    "\(Int((state.currentEffects.parallax * 100).rounded()))%"
                }
                Toggle("Soft light around the cursor", isOn: effectBinding(\.cursorGlow))
                    .font(.caption)
                Text("Particles also move out of the cursor's way.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                sectionLabel("Audio")
                sliderRow("Bass pulse", value: effectBinding(\.bassPulse), range: 0...1, enabled: true) {
                    "\(Int((state.currentEffects.bassPulse * 100).rounded()))%"
                }
                Toggle("Visualizer bars", isOn: effectBinding(\.visualizer))
                    .font(.caption)
                if state.currentEffects.usesAudio && !state.audioResponsive {
                    Button("Turn on “React to audio” so these move") { state.audioResponsive = true }
                        .font(.caption)
                }

                sectionLabel("Look")
                sliderRow("Brightness", value: effectBinding(\.brightness), range: 0.5...1.5, enabled: true) {
                    "\(Int((state.currentEffects.brightness * 100).rounded()))%"
                }
                sliderRow("Saturation", value: effectBinding(\.saturation), range: 0...2, enabled: true) {
                    "\(Int((state.currentEffects.saturation * 100).rounded()))%"
                }
                sliderRow("Blur", value: effectBinding(\.blur), range: 0...20, enabled: true) {
                    String(format: "%.0f pt", state.currentEffects.blur)
                }
                sliderRow("Vignette", value: effectBinding(\.vignette), range: 0...1, enabled: true) {
                    "\(Int((state.currentEffects.vignette * 100).rounded()))%"
                }

                HStack {
                    Spacer()
                    Button("Reset Effects") { state.updateEffects(.off) }
                        .disabled(!state.currentEffects.isActive)
                }
            }
            .padding(.top, 6)
        }
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.top, 4)
    }

    private func effectBinding<Value>(_ keyPath: WritableKeyPath<EffectSettings, Value>) -> Binding<Value> {
        Binding(
            get: { state.currentEffects[keyPath: keyPath] },
            set: { newValue in
                var effects = state.currentEffects
                effects[keyPath: keyPath] = newValue
                state.updateEffects(effects)
            }
        )
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.title3)
                .foregroundStyle(Color.accentColor)
            Text("Wallpaper Bridge").font(.headline)
            Spacer()
        }
    }

    private var downloadRow: some View {
        HStack {
            TextField("Paste a Steam Workshop link", text: $state.linkText)
                .textFieldStyle(.roundedBorder)
                .onSubmit { state.startDownload() }
                .disabled(state.isWorking)
            if state.isDownloading {
                Button("Cancel") { state.cancelDownload() }
            } else {
                Button("Download") { state.startDownload() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(state.isWorking || state.linkText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private var setupCard: some View {
        Card(tint: .orange) {
            Text("SteamCMD (Valve's command-line Steam client) is needed to download from the Workshop.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Install SteamCMD") { state.installSteamCMD() }
                    .disabled(state.isWorking)
                Button("Choose Existing…") { state.chooseSteamCMD() }
            }
        }
    }

    private var loginCard: some View {
        Card(tint: .blue) {
            Text("Steam needs you to sign in once. Terminal will open: type your password and Steam Guard code there. Wallpaper Bridge never sees them.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Button("Sign in with Terminal") { state.openSteamLogin() }
        }
    }

    private func progressRow(_ progress: DownloadProgress) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(progress.phase).font(.callout)
                Spacer()
                if let fraction = progress.fraction {
                    Text("\(Int((fraction * 100).rounded()))%")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if let fraction = progress.fraction {
                ProgressView(value: fraction)
            } else {
                ProgressView().progressViewStyle(.linear)
            }
            if let detail = progress.detail {
                Text(detail)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var adjustPanel: some View {
        DisclosureGroup("Adjust to screen", isExpanded: $showAdjust) {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Size", selection: fitBinding(\.mode)) {
                    ForEach(FitMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                let movable = state.currentFit.mode != .stretch
                sliderRow("Zoom", value: fitBinding(\.zoom), range: 1...3, enabled: movable) {
                    String(format: "%.1f×", state.currentFit.zoom)
                }
                sliderRow("Left ↔ Right", value: fitBinding(\.focusX), range: 0...1, enabled: movable) {
                    "\(Int((state.currentFit.focusX * 100).rounded()))%"
                }
                sliderRow("Top ↕ Bottom", value: fitBinding(\.focusY), range: 0...1, enabled: movable) {
                    "\(Int((state.currentFit.focusY * 100).rounded()))%"
                }

                HStack {
                    Text("Fill crops to cover the screen. Fit shows the whole picture.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset") { state.updateFit(.standard) }
                        .disabled(state.currentFit == .standard)
                }
            }
            .padding(.top, 6)
        }
    }

    private func sliderRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>,
                           enabled: Bool, label: () -> String) -> some View {
        HStack {
            Text(title).font(.caption).frame(width: 84, alignment: .leading)
            Slider(value: value, in: range)
            Text(label())
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)
        }
        .disabled(!enabled)
    }

    private func fitBinding<Value>(_ keyPath: WritableKeyPath<FitSettings, Value>) -> Binding<Value> {
        Binding(
            get: { state.currentFit[keyPath: keyPath] },
            set: { newValue in
                var fit = state.currentFit
                fit[keyPath: keyPath] = newValue
                state.updateFit(fit)
            }
        )
    }

    @ViewBuilder
    private var statusRow: some View {
        if let status = state.status {
            HStack(alignment: .top, spacing: 6) {
                if state.isWorking && state.progress == nil { ProgressView().controlSize(.small) }
                Text(status)
                    .font(.callout)
                    .foregroundStyle(state.statusIsError ? Color.red : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }

    private func nowShowing(_ item: WallpaperItem) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Now showing").font(.caption).foregroundStyle(.secondary)
                Text(item.title).lineLimit(1)
            }
            Spacer()
            if state.isLive {
                Button { state.togglePause() } label: {
                    Image(systemName: state.isPaused ? "play.fill" : "pause.fill")
                }
                .help(state.isPaused ? "Resume" : "Pause")
                Button { state.isMuted.toggle() } label: {
                    Image(systemName: state.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                }
                .help(state.isMuted ? "Unmute" : "Mute")
                Button { state.stop() } label: { Image(systemName: "stop.fill") }
                    .help("Stop the animated wallpaper")
            }
        }
        .buttonStyle(.borderless)
    }

    @ViewBuilder
    private var libraryGrid: some View {
        Text("Library").font(.subheadline.weight(.semibold))
        if state.library.isEmpty {
            Text("Downloaded wallpapers show up here. Click one to use it.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 60)
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 10)], spacing: 10) {
                    ForEach(state.library) { item in
                        LibraryTile(item: item, isCurrent: item.id == state.currentID)
                            .onTapGesture { state.select(item) }
                            .contextMenu {
                                Button("Use as Wallpaper") { state.select(item) }
                                    .disabled(!item.kind.isSupported)
                                Button("Show in Finder") { state.showInFinder(item) }
                                Button("Open Workshop Page") { state.openWorkshopPage(item) }
                                Divider()
                                Button("Delete", role: .destructive) { state.delete(item) }
                            }
                    }
                }
                .padding(2)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            DisclosureGroup("Settings", isExpanded: $showSettings) {
                settings.padding(.top, 6)
            }
            DisclosureGroup("SteamCMD log", isExpanded: $showLog) {
                logView.padding(.top, 6)
            }
            HStack {
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Steam username", text: $state.steamUsername)
                .textFieldStyle(.roundedBorder)
            Text("Use the account that owns Wallpaper Engine. Your password is only ever typed into SteamCMD in Terminal.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Text(state.steamcmdPath?.path ?? "SteamCMD not found")
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Choose…") { state.chooseSteamCMD() }
            }
            Button("Sign in to Steam Again…") { state.openSteamLogin() }
                .disabled(state.steamcmdPath == nil)
            Toggle("Use on the lock screen too", isOn: $state.setsLockScreen)
            Text("Sets a matching still picture as your macOS wallpaper, which the lock screen and every Space use. Animated wallpapers show a frame from the video there, since macOS can't play video on the lock screen.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("React to cursor", isOn: $state.cursorResponsive)
            Text("Web wallpapers and effects follow your mouse as it moves over the desktop.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("React to audio", isOn: $state.audioResponsive)
            Text("Lets audio-visualizer wallpapers and audio effects hear what your Mac is playing. macOS asks for Screen & System Audio Recording permission. Only sound levels are measured; nothing is recorded or saved.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error = state.audioError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(Color.red)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Privacy Settings") { state.openPrivacySettings() }
            }
            Toggle("Open at login", isOn: Binding(
                get: { state.launchAtLogin },
                set: { state.setLaunchAtLogin($0) }
            ))
        }
    }

    private var logView: some View {
        ScrollView {
            Text(state.logLines.isEmpty ? "Nothing yet." : state.logLines.joined(separator: "\n"))
                .font(.system(size: 10, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 120)
    }
}

struct LibraryTile: View {
    let item: WallpaperItem
    let isCurrent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Color.secondary.opacity(0.15)
                .frame(height: 68)
                .frame(maxWidth: .infinity)
                .overlay(thumbnail)
                .overlay(alignment: .topTrailing) {
                    Text(item.kind.label)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(4)
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(isCurrent ? Color.accentColor : Color.clear, lineWidth: 2)
                )
                .opacity(item.kind.isSupported ? 1 : 0.5)
            Text(item.title)
                .font(.caption)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
        .help(item.kind.isSupported ? item.title : "\(item.title) — can't run on macOS")
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let url = item.previewURL ?? item.stillURL, let image = ThumbnailCache.image(for: url) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
        } else {
            Image(systemName: "photo").foregroundStyle(.secondary)
        }
    }
}

struct Card<Content: View>: View {
    let tint: Color
    let content: Content

    init(tint: Color, @ViewBuilder content: () -> Content) {
        self.tint = tint
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) { content }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}
