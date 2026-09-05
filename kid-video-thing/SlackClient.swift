//
//  SlackClient.swift
//  kid-video-thing
//

import Foundation

enum SlackError: LocalizedError {
    case missingToken(String)
    case api(method: String, error: String)
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case .missingToken(let which):
            return "No \(which) set. Add one in Settings."
        case .api(let method, let error):
            return "Slack \(method) failed: \(error)"
        case .badResponse(let detail):
            return "Unexpected response from Slack: \(detail)"
        }
    }
}

/// Thin wrapper over the handful of Slack Web API methods this app needs.
struct SlackClient {
    var botToken: String
    var appToken: String

    private static let session = URLSession(configuration: .default)

    /// Emoji names (no colons) used to mark progress on the original message.
    enum Reaction: String {
        case seen = "eyes"
        case done = "white_check_mark"
        case failed = "warning"
        case deleted = "x"
    }

    /// Confirms the bot token works and returns the workspace/bot identity.
    func checkAuth() async throws -> (team: String, bot: String, userID: String) {
        let response = try await call("auth.test", token: botToken, body: [:])
        let team = response["team"] as? String ?? "?"
        let bot = response["user"] as? String ?? "?"
        let userID = response["user_id"] as? String ?? ""
        return (team, bot, userID)
    }

    /// Opens a Socket Mode connection URL using the app-level token.
    func openSocketConnection() async throws -> URL {
        guard !appToken.isEmpty else { throw SlackError.missingToken("app-level token") }
        let response = try await call("apps.connections.open", token: appToken, body: [:])
        guard let string = response["url"] as? String, let url = URL(string: string) else {
            throw SlackError.badResponse("apps.connections.open returned no url")
        }
        return url
    }

    /// IDs of every channel the bot has been invited to, public and private.
    func joinedChannels() async throws -> [String] {
        var channels: [String] = []
        var cursor: String?
        repeat {
            var body: [String: Any] = [
                "types": "public_channel,private_channel",
                "exclude_archived": true,
                "limit": 200,
            ]
            if let cursor, !cursor.isEmpty { body["cursor"] = cursor }

            let response = try await call("conversations.list", token: botToken, body: body)
            for case let channel as [String: Any] in response["channels"] as? [Any] ?? [] {
                if channel["is_member"] as? Bool == true, let id = channel["id"] as? String {
                    channels.append(id)
                }
            }
            cursor = (response["response_metadata"] as? [String: Any])?["next_cursor"] as? String
        } while !(cursor?.isEmpty ?? true)
        return channels
    }

    struct History {
        var messages: [[String: Any]]
        /// True when `maxPages` cut the walk short before reaching `since`.
        var truncated: Bool
    }

    /// Every message in a channel back to `since`, newest first, each with its
    /// `reactions`. Stops after `maxPages` so one very busy channel can't stall a
    /// resync; the caller is told when that happens.
    func allHistory(
        channel: String, since: TimeInterval, maxPages: Int = 10
    ) async throws -> History {
        var messages: [[String: Any]] = []
        var cursor: String?
        var page = 0

        repeat {
            var body: [String: Any] = [
                "channel": channel,
                "oldest": String(format: "%.6f", since),
                "limit": 200,
            ]
            if let cursor, !cursor.isEmpty { body["cursor"] = cursor }

            let response = try await call("conversations.history", token: botToken, body: body)
            messages += response["messages"] as? [[String: Any]] ?? []
            cursor = (response["response_metadata"] as? [String: Any])?["next_cursor"] as? String
            page += 1

            if page == maxPages, !(cursor?.isEmpty ?? true) {
                return History(messages: messages, truncated: true)
            }
        } while !(cursor?.isEmpty ?? true)

        return History(messages: messages, truncated: false)
    }

    func addReaction(_ reaction: Reaction, channel: String, timestamp: String) async throws {
        try await addReaction(named: reaction.rawValue, channel: channel, timestamp: timestamp)
    }

    func removeReaction(_ reaction: Reaction, channel: String, timestamp: String) async throws {
        try await removeReaction(named: reaction.rawValue, channel: channel, timestamp: timestamp)
    }

    /// Both of these are safe to call without knowing the current state: Slack's
    /// "already there" and "not there" responses are the outcome we wanted.
    func addReaction(named name: String, channel: String, timestamp: String) async throws {
        do {
            _ = try await call(
                "reactions.add", token: botToken,
                body: ["channel": channel, "timestamp": timestamp, "name": name])
        } catch SlackError.api(_, let error) where error == "already_reacted" {
            // Harmless — a retry or a duplicate event delivery.
        }
    }

    /// Only ever removes the bot's own reaction; a person's stays put.
    func removeReaction(named name: String, channel: String, timestamp: String) async throws {
        do {
            _ = try await call(
                "reactions.remove", token: botToken,
                body: ["channel": channel, "timestamp": timestamp, "name": name])
        } catch SlackError.api(_, let error)
            where error == "no_reaction" || error == "message_not_found"
        {
            // Nothing to remove.
        }
    }

    private func call(
        _ method: String, token: String, body: [String: Any]
    ) async throws -> [String: Any] {
        guard !token.isEmpty else { throw SlackError.missingToken("bot token") }

        var request = URLRequest(url: URL(string: "https://slack.com/api/\(method)")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await Self.session.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SlackError.badResponse("\(method) returned non-JSON")
        }
        guard json["ok"] as? Bool == true else {
            throw SlackError.api(method: method, error: json["error"] as? String ?? "unknown")
        }
        return json
    }
}
