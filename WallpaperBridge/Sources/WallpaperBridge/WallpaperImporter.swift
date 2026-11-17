import AppKit
import Foundation

/// Copies a downloaded Workshop folder into the library and works out how to show it on macOS.
enum WallpaperImporter {
    static let videoExtensions: Set<String> = ["mp4", "m4v", "mov", "webm"]
    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "bmp", "heic", "tif", "tiff", "webp"]

    static func importFolder(_ source: URL, id: String, fallbackTitle: String) throws -> WallpaperItem {
        let fm = FileManager.default
        let destination = AppPaths.library.appendingPathComponent(id, isDirectory: true)
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.copyItem(at: source, to: destination)

        let project = readProject(in: destination)
        let files = relativeFiles(in: destination)
        let exists: (String?) -> Bool = { name in
            guard let name, !name.isEmpty else { return false }
            return fm.fileExists(atPath: destination.appendingPathComponent(name).path)
        }

        let title = nonEmpty(project["title"] as? String) ?? fallbackTitle
        var mainFile = project["file"] as? String
        var kind = detectKind(typeName: project["type"] as? String, file: mainFile)

        // No usable project.json entry: guess from what's in the folder.
        if !exists(mainFile) {
            if let video = files.first(where: { videoExtensions.contains(ext($0)) }) {
                mainFile = video
                kind = .video
            } else if let page = files.first(where: { ($0 as NSString).lastPathComponent.lowercased() == "index.html" }) {
                mainFile = page
                kind = .web
            } else if let package = files.first(where: { ext($0) == "pkg" }) {
                mainFile = package
                kind = .scene
            } else if let image = files
                .filter({ imageExtensions.contains(ext($0)) && !isPreview($0) })
                .max(by: { fileSize($0, in: destination) < fileSize($1, in: destination) }) {
                mainFile = image
                kind = .image
            }
        }

        var preview = project["preview"] as? String
        if !exists(preview) { preview = files.first(where: isPreview) }

        var still: String?
        switch kind {
        case .image:
            still = mainFile
        case .scene:
            if let png = SceneStillExtractor.bestStill(in: destination) {
                let name = "_still.png"
                try png.write(to: destination.appendingPathComponent(name))
                still = name
            }
        default:
            break
        }

        return WallpaperItem(id: id, title: title, kind: kind, mainFile: mainFile,
                             previewFile: preview, stillFile: still, addedAt: Date())
    }

    static func detectKind(typeName: String?, file: String?) -> WallpaperKind {
        switch typeName?.lowercased() {
        case "video": return .video
        case "web": return .web
        case "scene": return .scene
        case "application": return .application
        default: break
        }
        guard let file else { return .unknown }
        let e = ext(file)
        if videoExtensions.contains(e) { return .video }
        if e == "html" || e == "htm" { return .web }
        if e == "pkg" || file.lowercased().hasSuffix("scene.json") { return .scene }
        if imageExtensions.contains(e) { return .image }
        if e == "exe" { return .application }
        return .unknown
    }

    static func readProject(in folder: URL) -> [String: Any] {
        guard var data = try? Data(contentsOf: folder.appendingPathComponent("project.json")) else { return [:] }
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { data = data.dropFirst(3) }
        return ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
    }

    /// Regular files under `folder` as relative paths, shallowest first.
    static func relativeFiles(in folder: URL) -> [String] {
        let base = folder.standardizedFileURL.path
        guard let enumerator = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
        ) else { return [] }

        var result: [String] = []
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(base + "/") else { continue }
            result.append(String(path.dropFirst(base.count + 1)))
        }
        return result.sorted { a, b in
            let depthA = a.split(separator: "/").count
            let depthB = b.split(separator: "/").count
            return depthA == depthB ? a < b : depthA < depthB
        }
    }

    static func isPreview(_ path: String) -> Bool {
        (path as NSString).lastPathComponent.lowercased().hasPrefix("preview.")
    }

    static func ext(_ path: String) -> String {
        (path as NSString).pathExtension.lowercased()
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    private static func fileSize(_ path: String, in folder: URL) -> Int {
        (try? folder.appendingPathComponent(path).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }
}

/// Scene wallpapers need Wallpaper Engine's renderer, which doesn't exist on macOS.
/// As a fallback this pulls the largest picture out of the scene: loose images, images inside
/// scene.pkg, and PNG/JPEG data embedded in .tex textures. Many "image" wallpapers are scenes
/// with a single picture, so this usually recovers the full-resolution image.
enum SceneStillExtractor {
    private static let pngSignature = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    private static let jpegSignature = Data([0xFF, 0xD8, 0xFF])
    private static let maxEntrySize = 96 * 1024 * 1024
    private static let minUsefulWidth = 640

    /// Returns PNG data for the best still, or nil if nothing usable was found.
    static func bestStill(in folder: URL) -> Data? {
        var best: (rep: NSBitmapImageRep, area: Int)?

        func consider(_ name: String, _ data: Data) {
            guard !WallpaperImporter.isPreview(name),
                  let rep = decode(name: name.lowercased(), data: data) else { return }
            let area = rep.pixelsWide * rep.pixelsHigh
            if area > (best?.area ?? 0) { best = (rep, area) }
        }

        for relative in WallpaperImporter.relativeFiles(in: folder) {
            let url = folder.appendingPathComponent(relative)
            let lower = relative.lowercased()
            if lower.hasSuffix(".pkg") {
                forEachPackageEntry(in: url, consider)
            } else if isCandidate(lower),
                      let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                      data.count <= maxEntrySize {
                consider(relative, data)
            }
        }

        guard let best, best.rep.pixelsWide >= minUsefulWidth else { return nil }
        return best.rep.representation(using: .png, properties: [:])
    }

    private static func isCandidate(_ lowercasedName: String) -> Bool {
        [".tex", ".png", ".jpg", ".jpeg"].contains { lowercasedName.hasSuffix($0) }
    }

    private static func decode(name: String, data: Data) -> NSBitmapImageRep? {
        guard name.hasSuffix(".tex") else { return NSBitmapImageRep(data: data) }
        // A .tex starts with a small header; textures stored as "FreeImage" carry an ordinary
        // PNG/JPEG right after it. Compressed GPU formats (DXT etc.) are skipped.
        let window = data.startIndex..<min(data.endIndex, data.startIndex + 2048)
        let starts = [data.range(of: pngSignature, in: window), data.range(of: jpegSignature, in: window)]
            .compactMap { $0?.lowerBound }
        guard let start = starts.min() else { return nil }
        return NSBitmapImageRep(data: data.subdata(in: start..<data.endIndex))
    }

    /// scene.pkg layout: [string "PKGV00xx"][u32 count] then per entry [string path][u32 offset][u32 length],
    /// followed by the file data. Strings are a u32 length then bytes; integers are little-endian.
    private static func forEachPackageEntry(in url: URL, _ body: (String, Data) -> Void) {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return }
        var reader = ByteReader(data: data)
        guard let magic = reader.string(), magic.hasPrefix("PKGV"),
              let count = reader.uint32(), count < 100_000 else { return }

        var entries: [(name: String, offset: Int, length: Int)] = []
        for _ in 0..<count {
            guard let name = reader.string(), let offset = reader.uint32(), let length = reader.uint32() else { return }
            entries.append((name, Int(offset), Int(length)))
        }

        let dataStart = data.startIndex + reader.position
        for entry in entries where isCandidate(entry.name.lowercased()) && entry.length <= maxEntrySize {
            let start = dataStart + entry.offset
            let end = start + entry.length
            guard start >= data.startIndex, end <= data.endIndex, start < end else { continue }
            body(entry.name, data.subdata(in: start..<end))
        }
    }
}

private struct ByteReader {
    let data: Data
    var position = 0

    init(data: Data) {
        self.data = data
    }

    mutating func uint32() -> UInt32? {
        let start = data.startIndex + position
        guard start + 4 <= data.endIndex else { return nil }
        position += 4
        return data[start..<start + 4].reversed().reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    mutating func string() -> String? {
        guard let length = uint32(), length <= 4096 else { return nil }
        let start = data.startIndex + position
        let end = start + Int(length)
        guard end <= data.endIndex else { return nil }
        position += Int(length)
        return String(decoding: data[start..<end], as: UTF8.self)
    }
}
