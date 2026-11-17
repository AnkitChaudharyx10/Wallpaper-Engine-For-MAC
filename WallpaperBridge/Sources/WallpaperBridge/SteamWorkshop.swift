import Foundation

enum WorkshopLink {
    /// Accepts a Workshop URL (…/filedetails/?id=123), a steam:// link, or a bare numeric ID.
    static func itemID(from input: String) -> String? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if isNumericID(text) { return text }

        if let components = URLComponents(string: text),
           let id = components.queryItems?.first(where: { $0.name == "id" })?.value,
           isNumericID(id) {
            return id
        }

        let pattern = #"(?:CommunityFilePage/|[?&]id=)(\d{4,20})"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    private static func isNumericID(_ s: String) -> Bool {
        (4...20).contains(s.count) && s.allSatisfy { $0.isASCII && $0.isNumber }
    }
}

struct WorkshopDetails {
    let id: String
    let title: String
    let appID: Int64
    let fileSize: Int64?
}

/// Steam's public Workshop metadata endpoint (no API key needed).
enum SteamWorkshopAPI {
    static let wallpaperEngineAppID: Int64 = 431960

    enum APIError: LocalizedError {
        case badResponse
        case notFound(String)

        var errorDescription: String? {
            switch self {
            case .badResponse:
                return "Steam returned an unexpected response. Try again in a moment."
            case .notFound(let id):
                return "Workshop item \(id) wasn't found. It may be private, removed, or a collection."
            }
        }
    }

    static func details(for id: String) async throws -> WorkshopDetails {
        let endpoint = URL(string: "https://api.steampowered.com/ISteamRemoteStorage/GetPublishedFileDetails/v1/")!
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("itemcount=1&publishedfileids%5B0%5D=\(id)".utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let body = root["response"] as? [String: Any],
              let list = body["publishedfiledetails"] as? [[String: Any]],
              let item = list.first else { throw APIError.badResponse }
        guard int64(item["result"]) == 1 else { throw APIError.notFound(id) }

        let rawTitle = (item["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return WorkshopDetails(
            id: id,
            title: rawTitle.isEmpty ? "Workshop item \(id)" : rawTitle,
            appID: int64(item["consumer_app_id"]) ?? 0,
            fileSize: int64(item["file_size"])
        )
    }

    private static func int64(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber { return number.int64Value }
        if let string = value as? String { return Int64(string) }
        return nil
    }
}
