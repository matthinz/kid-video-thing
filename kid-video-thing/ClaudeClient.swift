//
//  ClaudeClient.swift
//  kid-video-thing
//

import Foundation

enum ClaudeError: LocalizedError {
    case noAPIKey
    case http(status: Int, body: String)
    case badResponse(String)
    case refused(String)

    var errorDescription: String? {
        switch self {
        case .noAPIKey:
            return "No Claude API key. Paste one in Settings → Claude."
        case .http(let status, let body):
            let detail = body.prefix(200)
            return "Claude returned HTTP \(status)\(detail.isEmpty ? "" : " — \(detail)")"
        case .badResponse(let detail):
            return "Unexpected response from Claude: \(detail)"
        case .refused(let reason):
            return "Claude declined the request (\(reason))."
        }
    }
}

/// The handful of Claude API calls the app makes — currently just "tidy this title".
///
/// Swift has no official Anthropic SDK, so this talks to the Messages API over
/// HTTP directly. One request, one response; no streaming, no tools.
nonisolated struct ClaudeClient {
    /// Models offered in Settings. Haiku is the default: cleaning a title is a
    /// short rewrite, and the per-video cost rounds to nothing.
    enum Model: String, CaseIterable, Identifiable {
        case haiku45 = "claude-haiku-4-5"
        case sonnet5 = "claude-sonnet-5"
        case opus5 = "claude-opus-5"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .haiku45: return "Claude Haiku 4.5"
            case .sonnet5: return "Claude Sonnet 5"
            case .opus5: return "Claude Opus 5"
            }
        }

        /// Rough per-million-token prices, shown in Settings so the cost of a
        /// choice is visible at the point of making it.
        var priceNote: String {
            switch self {
            case .haiku45: return "$1 / $5 per million tokens — plenty for this"
            case .sonnet5: return "$3 / $15 per million tokens"
            case .opus5: return "$5 / $25 per million tokens"
            }
        }

        static let `default` = Model.haiku45
    }

    var apiKey: String
    var model: Model

    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        return URLSession(configuration: configuration)
    }()

    /// One non-streaming Messages API call, returning the concatenated text blocks.
    ///
    /// `max_tokens` is deliberately small — a title is a handful of tokens, and a
    /// low ceiling keeps a misbehaving response from running away.
    func complete(system: String, prompt: String, maxTokens: Int = 200) async throws -> String {
        guard !apiKey.isEmpty else { throw ClaudeError.noAPIKey }

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let body: [String: Any] = [
            "model": model.rawValue,
            "max_tokens": maxTokens,
            "system": system,
            "messages": [["role": "user", "content": prompt]],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await Self.session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ClaudeError.badResponse("no HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ClaudeError.http(
                status: http.statusCode, body: String(decoding: data, as: UTF8.self))
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeError.badResponse("not a JSON object")
        }

        // A safety decline arrives as a normal 200 with an empty content array, so
        // it has to be checked before reading the text out.
        if json["stop_reason"] as? String == "refusal" {
            let category = (json["stop_details"] as? [String: Any])?["category"] as? String
            throw ClaudeError.refused(category ?? "no reason given")
        }

        guard let content = json["content"] as? [[String: Any]] else {
            throw ClaudeError.badResponse("no content blocks")
        }
        let text =
            content
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined()

        guard !text.isEmpty else { throw ClaudeError.badResponse("empty response") }
        return text
    }
}
