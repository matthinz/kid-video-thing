//
//  PlexClient.swift
//  kid-video-thing
//

import Foundation

enum PlexError: LocalizedError {
    case noToken
    case unreachable(host: String, detail: String)
    case unauthorized
    case http(Int)
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case .noToken:
            return """
                Couldn't find a Plex token. Open Plex once on this Mac, or paste a \
                token in Settings.
                """
        case .unreachable(let host, let detail):
            return "Can't reach Plex at \(host) — \(detail)"
        case .unauthorized:
            return "Plex rejected the token. Paste a current one in Settings."
        case .http(let status):
            return "Plex returned HTTP \(status)."
        case .badResponse(let detail):
            return "Unexpected response from Plex: \(detail)"
        }
    }
}

/// Reads viewing figures from the Plex server running on this Mac.
///
/// Plex's section listing carries each item's file path alongside its view
/// counts, so the whole library comes back in one request per section — no
/// per-item lookups.
nonisolated struct PlexClient {
    var baseURL = URL(string: "http://127.0.0.1:32400")!
    var token: String

    struct Playlist {
        var ratingKey: String
        var title: String
        /// Emoji in the title are what Slack reactions are matched against.
        var emoji: [String] { EmojiNames.characters(in: title) }
    }

    /// One of the poster images Plex is offering for a video.
    ///
    /// `provider` is `"local"` for a `poster.jpg` sitting next to the video, and
    /// nil for a frame Plex grabbed out of the video itself.
    struct Poster {
        var provider: String?
        var selected: Bool
        /// The `metadata://…` or `media://…` reference Plex wants back when
        /// choosing this image.
        var url: String

        var isLocal: Bool { provider == "local" }
    }

    /// A video's membership in a playlist. Removing one needs `playlistItemID`,
    /// which is per-membership and not the same as the video's `ratingKey`.
    struct PlaylistItem {
        var playlistItemID: String
        var ratingKey: String
    }

    /// One video as Plex knows it.
    struct Item {
        var ratingKey: String
        /// The library section this came from — needed to edit it, since Plex
        /// takes metadata writes on the section rather than on the item.
        var sectionKey: String
        var title: String
        var filePath: String
        var viewCount: Int?
        var lastViewedAt: Date?

        /// yt-dlp names every file `… [<video id>].<ext>`, which is what ties a
        /// Plex item back to the video it was downloaded from.
        var youTubeID: String? {
            let name = URL(filePath: filePath).deletingPathExtension().lastPathComponent
            guard name.hasSuffix("]"), let open = name.range(of: "[", options: .backwards) else {
                return nil
            }
            let id = String(name[open.upperBound..<name.index(before: name.endIndex)])
            return YTDLP.isVideoID(id) ? id : nil
        }
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        return URLSession(configuration: configuration)
    }()

    /// The token Plex Media Server stores for itself on this Mac. Only works when
    /// the server runs as the same user, which is the local-server case.
    static func discoverToken() -> String? {
        let domain = "com.plexapp.plexmediaserver"
        if let token = UserDefaults(suiteName: domain)?.string(forKey: "PlexOnlineToken"),
            !token.isEmpty
        {
            return token
        }
        // Reading the preferences file directly covers a domain the defaults
        // system won't hand over.
        let plist = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Preferences/\(domain).plist")
        guard let contents = NSDictionary(contentsOf: plist),
            let token = contents["PlexOnlineToken"] as? String, !token.isEmpty
        else { return nil }
        return token
    }

    /// Every video Plex has, across every library section.
    func allItems() async throws -> [Item] {
        var items: [Item] = []
        for section in try await sectionKeys() {
            items += try await self.items(inSection: section)
        }
        return items
    }

    private func sectionKeys() async throws -> [String] {
        let document = try await get("/library/sections")
        let directories = (try? document.nodes(forXPath: "//Directory")) ?? []
        return directories.compactMap { ($0 as? XMLElement)?.attribute("key") }
    }

    private func items(inSection key: String) async throws -> [Item] {
        let document = try await get("/library/sections/\(key)/all")
        let videos = (try? document.nodes(forXPath: "//Video")) ?? []

        return videos.compactMap { node -> Item? in
            guard let video = node as? XMLElement,
                let file = (try? video.nodes(forXPath: ".//Part/@file"))?.first?.stringValue
            else { return nil }

            return Item(
                ratingKey: video.attribute("ratingKey") ?? "",
                sectionKey: key,
                title: video.attribute("title") ?? "",
                filePath: file,
                // Plex leaves these attributes out entirely rather than sending
                // zero, so absent means "never watched", not "unknown".
                viewCount: video.attribute("viewCount").flatMap(Int.init),
                lastViewedAt: video.attribute("lastViewedAt").flatMap(Double.init).map {
                    Date(timeIntervalSince1970: $0)
                })
        }
    }

    // MARK: - Titles and artwork

    /// The poster images Plex is offering for a video, and which one it picked.
    func posters(_ ratingKey: String) async throws -> [Poster] {
        let document = try await get("/library/metadata/\(ratingKey)/posters")
        let photos = (try? document.nodes(forXPath: "//Photo")) ?? []

        return photos.compactMap { node -> Poster? in
            guard let photo = node as? XMLElement, let key = photo.attribute("key") else {
                return nil
            }
            // The key is a URL of its own with the reference we need buried in
            // its query: `/library/metadata/1/file?url=metadata%3A%2F%2F…`.
            guard
                let url = URLComponents(string: key)?
                    .queryItems?.first(where: { $0.name == "url" })?.value
            else { return nil }

            return Poster(
                provider: photo.attribute("provider"),
                selected: photo.attribute("selected") == "1",
                url: url)
        }
    }

    /// Tells Plex which poster to use for a video.
    func selectPoster(_ ratingKey: String, url: String) async throws {
        _ = try await send("PUT", "/library/metadata/\(ratingKey)/poster", query: ["url": url])
    }

    /// Sets a video's title, and pins the fields we care about.
    ///
    /// Locking is the point of this, not a detail. Left unlocked, Plex treats
    /// both of these as its own to work out — it re-derives the title from the
    /// filename and re-picks the artwork whenever it refreshes an item, which is
    /// how a library ends up showing video stills instead of the posters sitting
    /// right beside the files. A locked field is one Plex stops second-guessing.
    ///
    /// Passing `locked: false` hands a field back to Plex, which is what undoing
    /// a cleanup wants: the title returns to being whatever the filename says.
    func setTitle(
        _ ratingKey: String, inSection section: String, title: String, locked: Bool
    ) async throws {
        _ = try await send(
            "PUT", "/library/sections/\(section)/all",
            query: [
                "type": "1",
                "id": ratingKey,
                "title.value": title,
                "title.locked": locked ? "1" : "0",
            ])
    }

    /// Pins a video's artwork, so Plex stops replacing the poster with a frame
    /// it picked out of the video.
    func lockThumb(_ ratingKey: String, inSection section: String) async throws {
        _ = try await send(
            "PUT", "/library/sections/\(section)/all",
            query: ["type": "1", "id": ratingKey, "thumb.locked": "1"])
    }

    // MARK: - Playlists

    func playlists() async throws -> [Playlist] {
        let document = try await send("GET", "/playlists")
        return ((try? document.nodes(forXPath: "//Playlist")) ?? []).compactMap { node in
            guard let element = node as? XMLElement,
                let key = element.attribute("ratingKey"),
                let title = element.attribute("title")
            else { return nil }
            return Playlist(ratingKey: key, title: title)
        }
    }

    func playlistItems(_ playlist: String) async throws -> [PlaylistItem] {
        let document = try await send("GET", "/playlists/\(playlist)/items")
        return ((try? document.nodes(forXPath: "//Video")) ?? []).compactMap { node in
            guard let element = node as? XMLElement,
                let itemID = element.attribute("playlistItemID"),
                let key = element.attribute("ratingKey")
            else { return nil }
            return PlaylistItem(playlistItemID: itemID, ratingKey: key)
        }
    }

    func addToPlaylist(_ playlist: String, ratingKey: String) async throws {
        let uri =
            "server://\(try await machineIdentifier())"
            + "/com.plexapp.plugins.library/library/metadata/\(ratingKey)"
        _ = try await send("PUT", "/playlists/\(playlist)/items", query: ["uri": uri])
    }

    func removeFromPlaylist(_ playlist: String, itemID: String) async throws {
        _ = try await send("DELETE", "/playlists/\(playlist)/items/\(itemID)")
    }

    /// Cached: it identifies the server and never changes while it's running.
    private static var cachedMachineID: String?

    private func machineIdentifier() async throws -> String {
        if let cached = Self.cachedMachineID { return cached }
        let document = try await send("GET", "/identity")
        guard
            let id = (try? document.nodes(forXPath: "//MediaContainer/@machineIdentifier"))?
                .first?.stringValue
        else { throw PlexError.badResponse("/identity gave no machineIdentifier") }
        Self.cachedMachineID = id
        return id
    }

    // MARK: - Transport

    private func get(_ path: String) async throws -> XMLDocument {
        try await send("GET", path)
    }

    private func send(
        _ method: String, _ path: String, query: [String: String] = [:]
    ) async throws -> XMLDocument {
        guard !token.isEmpty else { throw PlexError.noToken }

        var components = URLComponents(
            url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            // Encoded by hand: a playlist `uri` contains `/` and `:`, which
            // URLComponents would otherwise leave raw in the query.
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
            components.percentEncodedQuery =
                query
                .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
                .joined(separator: "&")
        }

        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.setValue(token, forHTTPHeaderField: "X-Plex-Token")
        request.setValue("application/xml", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await Self.session.data(for: request)
        } catch {
            let host = [baseURL.host(), baseURL.port.map(String.init)]
                .compactMap { $0 }.joined(separator: ":")
            throw PlexError.unreachable(host: host, detail: error.localizedDescription)
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 { throw PlexError.unauthorized }
        guard status == 200 else { throw PlexError.http(status) }

        // A successful DELETE comes back with no body, which isn't an error.
        guard !data.isEmpty else { return XMLDocument() }
        do {
            return try XMLDocument(data: data)
        } catch {
            throw PlexError.badResponse(error.localizedDescription)
        }
    }
}

extension XMLElement {
    fileprivate func attribute(_ name: String) -> String? {
        attribute(forName: name)?.stringValue
    }
}
