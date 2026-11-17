import Foundation

/// Anthropic Messages API over raw HTTPS with streaming (there is no official Swift SDK).
struct AnthropicAPIProvider: TextProvider {
    let apiKey: String
    let model: String

    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    static let apiVersion = "2026-10-21"
    /// Models with a server-side refusal fallback ("fallbacks": "default").
    static let fallbackModels: Set<String> = ["claude-opus-5-5", "claude-sonnet-5-5"]

    static func body(model: String, system: String, user: String) -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            "max_tokens": 16000,
            "stream": true,
            "system": system,
            "messages": [["role": "user", "content": user]],
            // Short editing task: low effort keeps latency down; thinking stays adaptive (the model default).
            "output_config": ["effort": "low"],
        ]
        if fallbackModels.contains(model) { body["fallbacks"] = "default" }
        return body
    }

    func improve(system: String, user: String, onDelta: @escaping @Sendable (String) -> Void) async throws -> String {
        var request = URLRequest(url: Self.endpoint, timeoutInterval: 90)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        if Self.fallbackModels.contains(model) {
            request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: Self.body(model: model, system: system, user: user))

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            var raw = ""
            for try await line in bytes.lines { raw += line }
            throw ProviderError(message: Self.httpError(status: status, body: raw))
        }
        var text = ""
        for try await line in bytes.lines {
            try Task.checkCancellation()
            switch StreamParsers.sseLine(line) {
            case .delta(let t): text += t; onDelta(t)
            case .error(let m): throw ProviderError(message: m)
            case .refusal: throw ProviderError(message: L("Claude declined to edit this text."))
            default: break
            }
        }
        return text
    }

    static func httpError(status: Int, body: String) -> String {
        var message = body
        if let data = body.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let err = obj["error"] as? [String: Any], let m = err["message"] as? String { message = m }
        switch status {
        case 401: return L("The API key was rejected. Check it in Settings.")
        case 429: return L("Rate limit reached. Try again in a moment.")
        case 529: return L("Claude is overloaded right now. Try again in a moment.")
        default: return "HTTP \(status): \(message)"
        }
    }
}
