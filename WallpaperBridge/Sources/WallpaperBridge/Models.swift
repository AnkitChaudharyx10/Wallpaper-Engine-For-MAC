import Foundation

enum AppPaths {
    static let support: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return ensure(base.appendingPathComponent("WallpaperBridge", isDirectory: true))
    }()

    static var library: URL { ensure(support.appendingPathComponent("Library", isDirectory: true)) }
    static var steamcmdDir: URL { ensure(support.appendingPathComponent("steamcmd", isDirectory: true)) }
    static var libraryIndex: URL { support.appendingPathComponent("library.json") }
    /// Still pictures rendered at each screen's exact size.
    static var rendered: URL { ensure(support.appendingPathComponent("Rendered", isDirectory: true)) }

    @discardableResult
    static func ensure(_ dir: URL) -> URL {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

enum WallpaperKind: String, Codable {
    case video, web, scene, image, application, unknown

    var label: String {
        switch self {
        case .video: return "Video"
        case .web: return "Web"
        case .scene: return "Scene"
        case .image: return "Image"
        case .application: return "App"
        case .unknown: return "Unknown"
        }
    }

    var isSupported: Bool { self != .application && self != .unknown }
}

struct WallpaperItem: Codable, Identifiable, Hashable {
    /// Steam Workshop item ID; also the folder name in the library.
    let id: String
    var title: String
    var kind: WallpaperKind
    /// Paths relative to `folder`.
    var mainFile: String?
    var previewFile: String?
    /// A still picture for scenes/images (set as the normal macOS wallpaper).
    var stillFile: String?
    var addedAt: Date
    /// How the wallpaper is sized and positioned on screen. nil = default (fill, centred).
    var fit: FitSettings?
    /// Particles, cursor/audio reactions and colour adjustments. nil = no effects.
    var effects: EffectSettings?

    var fitSettings: FitSettings { fit ?? .standard }
    var effectSettings: EffectSettings { effects ?? .off }
    /// Web wallpapers lay themselves out, so they can't be resized from outside.
    var supportsFit: Bool { kind != .web && kind.isSupported }

    var folder: URL { AppPaths.library.appendingPathComponent(id, isDirectory: true) }
    var mainURL: URL? { existing(mainFile) }
    var previewURL: URL? { existing(previewFile) }
    var stillURL: URL? { existing(stillFile) }
    var workshopURL: URL { URL(string: "https://steamcommunity.com/sharedfiles/filedetails/?id=\(id)")! }

    private func existing(_ name: String?) -> URL? {
        guard let name, !name.isEmpty else { return nil }
        let url = folder.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

enum FitMode: String, Codable, CaseIterable, Identifiable {
    case fill, fit, stretch, center

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fill: return "Fill"
        case .fit: return "Fit"
        case .stretch: return "Stretch"
        case .center: return "Center"
        }
    }
}

struct FitSettings: Codable, Hashable {
    var mode: FitMode = .fill
    /// 1 = normal size, up to 3x.
    var zoom: Double = 1
    /// 0 = left edge, 1 = right edge.
    var focusX: Double = 0.5
    /// 0 = top edge, 1 = bottom edge.
    var focusY: Double = 0.5

    static let standard = FitSettings()

    /// Where content of size `content` goes inside `container`, measured from the top-left.
    /// `pixelScale` is screen pixels per container unit; only "Center" uses it, so one
    /// image pixel lands on one screen pixel.
    func frame(content: CGSize, container: CGSize, pixelScale: CGFloat = 1) -> CGRect {
        guard content.width > 0, content.height > 0, mode != .stretch else {
            return CGRect(origin: .zero, size: container)
        }
        let base: CGFloat
        switch mode {
        case .fill: base = max(container.width / content.width, container.height / content.height)
        case .fit: base = min(container.width / content.width, container.height / content.height)
        case .center: base = 1 / max(pixelScale, 1)
        case .stretch: base = 1
        }
        let scale = base * CGFloat(zoom)
        let size = CGSize(width: content.width * scale, height: content.height * scale)
        return CGRect(x: (container.width - size.width) * CGFloat(focusX),
                      y: (container.height - size.height) * CGFloat(focusY),
                      width: size.width,
                      height: size.height)
    }
}

enum ParticleEffect: String, Codable, CaseIterable, Identifiable {
    case off, snow, rain, fireflies, petals, bubbles, stars

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: return "None"
        case .snow: return "Snow"
        case .rain: return "Rain"
        case .fireflies: return "Fireflies"
        case .petals: return "Sakura petals"
        case .bubbles: return "Bubbles"
        case .stars: return "Twinkling stars"
        }
    }
}

/// Effects drawn on top of (or applied to) any wallpaper. Mirrored by the effects engine in
/// `WebBridge.script`, so the property names here are also used in JavaScript.
struct EffectSettings: Codable, Hashable {
    var particles: ParticleEffect = .off
    /// 0.1...1
    var particleAmount: Double = 0.5
    /// 0...1: how far the wallpaper shifts as the cursor moves.
    var parallax: Double = 0
    var cursorGlow = false
    /// 0...1: how much the wallpaper zooms on bass hits.
    var bassPulse: Double = 0
    var visualizer = false
    /// 0.5...1.5
    var brightness: Double = 1
    /// 0...2
    var saturation: Double = 1
    /// 0...20 points
    var blur: Double = 0
    /// 0...1
    var vignette: Double = 0

    static let off = EffectSettings()

    var isActive: Bool {
        particles != .off || parallax > 0 || cursorGlow || bassPulse > 0 || visualizer
            || brightness != 1 || saturation != 1 || blur > 0 || vignette > 0
    }

    var usesAudio: Bool { bassPulse > 0 || visualizer }

    init() {}

    // Read field by field so settings saved by older versions still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        particles = try c.decodeIfPresent(ParticleEffect.self, forKey: .particles) ?? .off
        particleAmount = try c.decodeIfPresent(Double.self, forKey: .particleAmount) ?? 0.5
        parallax = try c.decodeIfPresent(Double.self, forKey: .parallax) ?? 0
        cursorGlow = try c.decodeIfPresent(Bool.self, forKey: .cursorGlow) ?? false
        bassPulse = try c.decodeIfPresent(Double.self, forKey: .bassPulse) ?? 0
        visualizer = try c.decodeIfPresent(Bool.self, forKey: .visualizer) ?? false
        brightness = try c.decodeIfPresent(Double.self, forKey: .brightness) ?? 1
        saturation = try c.decodeIfPresent(Double.self, forKey: .saturation) ?? 1
        blur = try c.decodeIfPresent(Double.self, forKey: .blur) ?? 0
        vignette = try c.decodeIfPresent(Double.self, forKey: .vignette) ?? 0
    }
}

extension Encodable {
    /// This value as a JSON string, for handing to JavaScript.
    var json: String {
        guard let data = try? JSONEncoder().encode(self) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }
}
