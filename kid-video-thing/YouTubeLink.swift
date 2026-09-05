//
//  YouTubeLink.swift
//  kid-video-thing
//

import Foundation

/// Pulls YouTube links out of Slack message text.
enum YouTubeLink {
    private static let hosts: Set<String> = [
        "youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com",
        "youtu.be", "www.youtu.be",
    ]

    /// Returns the YouTube URLs in `text`, in order, without duplicates.
    ///
    /// Slack wraps links as `<https://example.com>` or `<https://example.com|label>`,
    /// so those brackets are stripped before matching.
    static func links(in text: String) -> [String] {
        let unwrapped = normalize(text)
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(unwrapped.startIndex..<unwrapped.endIndex, in: unwrapped)

        var found: [String] = []
        detector?.enumerateMatches(in: unwrapped, range: range) { match, _, _ in
            guard let url = match?.url, isYouTube(url) else { return }
            let normalized = url.absoluteString
            if !found.contains(normalized) { found.append(normalized) }
        }
        return found
    }

    /// True for a link that names a playlist and no particular video.
    ///
    /// A `watch?v=…&list=…` link is deliberately *not* a playlist: it points at one
    /// video that happens to sit in a playlist, and `--no-playlist` keeps yt-dlp to
    /// just that video — which is what someone sharing that link means.
    static func isPlaylist(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString), isYouTube(url),
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return false }
        let query = components.queryItems ?? []
        guard query.first(where: { $0.name == "v" })?.value == nil else { return false }
        return url.path.hasPrefix("/playlist")
            || query.contains { $0.name == "list" && !($0.value ?? "").isEmpty }
    }

    /// The canonical watch URL for a video ID.
    static func watchURL(videoID: String) -> String {
        "https://www.youtube.com/watch?v=\(videoID)"
    }

    static func isYouTube(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
            let host = url.host?.lowercased()
        else { return false }
        return hosts.contains(host)
    }

    /// Message text as the links in it are written: wrappers off, entities decoded.
    /// Anything comparing text against `links(in:)` has to use this, or an escaped
    /// `&amp;` in the raw message won't match the decoded link.
    static func normalize(_ text: String) -> String {
        unescape(unwrapSlackLinks(text))
    }

    /// Slack escapes `&`, `<` and `>` in message text, so a shared link arrives as
    /// `…?list=X&amp;si=Y`. Undo that once the link wrappers are off.
    private static func unescape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    /// Turns `<url|label>` and `<url>` into bare `url`, leaving other text alone.
    private static func unwrapSlackLinks(_ text: String) -> String {
        var result = ""
        var rest = Substring(text)

        while let open = rest.firstIndex(of: "<") {
            result += rest[rest.startIndex..<open]
            let afterOpen = rest.index(after: open)
            guard let close = rest[afterOpen...].firstIndex(of: ">") else {
                result += rest[open...]
                return result
            }
            let inner = rest[afterOpen..<close]
            // Slack's <@U123> mentions and <#C123|name> channel refs aren't links.
            if let pipe = inner.firstIndex(of: "|") {
                result += inner[inner.startIndex..<pipe] + " "
            } else {
                result += inner + " "
            }
            rest = rest[rest.index(after: close)...]
        }
        result += rest
        return result
    }
}
