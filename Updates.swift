import Foundation

enum Updates {
    struct Release: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: URL
        }

        let tag_name: String
        let assets: [Asset]
    }

    struct Available {
        let version: String
        let download: URL
    }

    enum Failure: Error {
        case invalidResponse
    }

    static func latest(current: String) async throws -> Available? {
        let endpoint = URL(string: "https://api.github.com/repos/StrenghtLab/Blattkarten/releases/latest")!
        var request = URLRequest(url: endpoint, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode else { throw Failure.invalidResponse }
        if status == 404 { return nil }
        guard status == 200 else { throw Failure.invalidResponse }
        return try available(from: data, current: current)
    }

    static func available(from data: Data, current: String) throws -> Available? {
        let release = try JSONDecoder().decode(Release.self, from: data)
        let version = release.tag_name.hasPrefix("v") ? String(release.tag_name.dropFirst()) : release.tag_name
        guard version.range(of: #"^[0-9]+(?:\.[0-9]+){1,2}$"#, options: .regularExpression) != nil,
              version.compare(current, options: .numeric) == .orderedDescending else { return nil }
        guard let url = release.assets.first(where: { $0.name == "Blattkarten-\(version).dmg" })?.browser_download_url,
              url.scheme == "https", url.host == "github.com",
              url.path == "/StrenghtLab/Blattkarten/releases/download/\(release.tag_name)/Blattkarten-\(version).dmg" else {
            throw Failure.invalidResponse
        }
        return Available(version: version, download: url)
    }
}
