import Foundation
import Security

/// A model backend. Streams text deltas, returns the full reply.
protocol TextProvider: Sendable {
    func improve(system: String, user: String, onDelta: @escaping @Sendable (String) -> Void) async throws -> String
}

struct ProviderError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum ProviderKind: String, CaseIterable, Identifiable {
    case claudeCode, anthropicAPI
    var id: String { rawValue }
    var title: String {
        switch self {
        case .claudeCode: return L("Claude Code (your subscription)")
        case .anthropicAPI: return L("Anthropic API key")
        }
    }
}

/// Model choices. CLI uses Claude Code's aliases (always the newest of each family it knows);
/// the API uses exact model ids.
struct ModelChoice: Identifiable, Hashable {
    let id: String
    let title: String

    static let cli: [ModelChoice] = [
        ModelChoice(id: "sonnet", title: "Sonnet — " + L("balanced")),
        ModelChoice(id: "haiku", title: "Haiku — " + L("fastest")),
        ModelChoice(id: "opus", title: "Opus — " + L("best quality, slower")),
    ]
    static let api: [ModelChoice] = [
        ModelChoice(id: "claude-opus-5-5", title: "Claude Opus 5.5 — " + L("best quality")),
        ModelChoice(id: "claude-sonnet-5-5", title: "Claude Sonnet 5.5 — " + L("balanced")),
        ModelChoice(id: "claude-haiku-5-5", title: "Claude Haiku 5.5 — " + L("fastest, cheapest")),
    ]
}

/// Line-oriented parsers, kept apart from the I/O so self-tests can feed them recorded output.
enum StreamParsers {
    enum Event: Equatable { case delta(String), final(String), error(String), refusal, none }

    /// One line of `claude -p --output-format stream-json --include-partial-messages --verbose`.
    static func claudeCodeLine(_ line: String) -> Event {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return .none }
        switch type {
        case "stream_event":
            guard let event = obj["event"] as? [String: Any] else { return .none }
            return anthropicEvent(event)
        case "result":
            if obj["is_error"] as? Bool == true {
                let msg = (obj["result"] as? String) ?? (obj["subtype"] as? String) ?? "error"
                return .error(msg)
            }
            return .final((obj["result"] as? String) ?? "")
        default:
            return .none
        }
    }

    /// One `data:` line of the Messages API SSE stream.
    static func sseLine(_ line: String) -> Event {
        guard line.hasPrefix("data:") else { return .none }
        let json = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .none }
        return anthropicEvent(obj)
    }

    private static func anthropicEvent(_ event: [String: Any]) -> Event {
        switch event["type"] as? String {
        case "content_block_delta":
            if let delta = event["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
               let text = delta["text"] as? String { return .delta(text) }
        case "message_delta":
            if let delta = event["delta"] as? [String: Any], delta["stop_reason"] as? String == "refusal" { return .refusal }
        case "error":
            let err = event["error"] as? [String: Any]
            return .error((err?["message"] as? String) ?? "API error")
        default: break
        }
        return .none
    }
}

/// API key in the login keychain (never in UserDefaults or files).
enum Keychain {
    private static let service = "com.viafirst.inkfix"
    private static let account = "anthropic-api-key"

    static func load() -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ key: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(trimmed.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}
