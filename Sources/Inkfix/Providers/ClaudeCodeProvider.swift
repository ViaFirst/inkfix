import Foundation

/// Runs the user's own Claude Code CLI (`claude -p`), so requests go through their Claude subscription.
/// No tools, no MCP, no settings, no session files: a single text-in, text-out turn.
struct ClaudeCodeProvider: TextProvider {
    let executable: URL
    let model: String
    var timeout: TimeInterval = 90

    func improve(system: String, user: String, onDelta: @escaping @Sendable (String) -> Void) async throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = [
            "-p", "--model", model,
            "--system-prompt", system,
            "--tools", "",
            "--no-session-persistence", "--setting-sources", "", "--strict-mcp-config", "--disable-slash-commands",
            "--output-format", "stream-json", "--include-partial-messages", "--verbose",
        ]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = ClaudeCodeLocator.loginPath
        env.removeValue(forKey: "ANTHROPIC_API_KEY") // always the subscription, never a stray key
        process.environment = env
        process.currentDirectoryURL = AppPaths.support
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        let state = StreamState()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
                let finish = state.finisher(cont)
                stdout.fileHandleForReading.readabilityHandler = { handle in
                    let chunk = handle.availableData
                    if chunk.isEmpty { handle.readabilityHandler = nil; return }
                    for line in state.lines(chunk) {
                        switch StreamParsers.claudeCodeLine(line) {
                        case .delta(let t): state.append(t); onDelta(t)
                        case .final(let t): state.setFinal(t)
                        case .error(let m): state.setError(m)
                        case .refusal: state.setError(L("Claude declined to edit this text."))
                        case .none: break
                        }
                    }
                }
                process.terminationHandler = { p in
                    stdout.fileHandleForReading.readabilityHandler = nil
                    let rest = stdout.fileHandleForReading.readDataToEndOfFile()
                    for line in state.lines(rest) + state.flush() {
                        switch StreamParsers.claudeCodeLine(line) {
                        case .delta(let t): state.append(t)
                        case .final(let t): state.setFinal(t)
                        case .error(let m): state.setError(m)
                        default: break
                        }
                    }
                    if let err = state.error {
                        finish(.failure(ProviderError(message: Self.friendly(err))))
                    } else if let text = state.result, p.terminationStatus == 0 {
                        finish(.success(text))
                    } else {
                        let errText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                        let msg = errText.trimmingCharacters(in: .whitespacesAndNewlines)
                        finish(.failure(ProviderError(message: Self.friendly(msg.isEmpty ? "exit \(p.terminationStatus)" : msg))))
                    }
                }
                do {
                    try process.run()
                } catch {
                    finish(.failure(ProviderError(message: L("Could not start Claude Code: ") + error.localizedDescription)))
                    return
                }
                stdin.fileHandleForWriting.write(Data(user.utf8))
                try? stdin.fileHandleForWriting.close()
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    if process.isRunning {
                        state.setError(L("Claude Code did not answer in time."))
                        process.terminate()
                    }
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }

    static func friendly(_ message: String) -> String {
        let lower = message.lowercased()
        if lower.contains("login") || lower.contains("log in") || lower.contains("not logged") || lower.contains("authenticat") {
            return L("Claude Code is not signed in. Run `claude` in Terminal once and sign in with your Claude account.")
        }
        if lower.contains("rate limit") || lower.contains("usage limit") || lower.contains("limit reached") {
            return L("Your Claude usage limit is reached for now. Try later or switch to an API key in Settings.")
        }
        return message
    }
}

/// Mutable state shared by the pipe and termination callbacks (each runs on its own queue).
/// Guarded by a lock, hence @unchecked Sendable.
final class StreamState: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var text = ""
    private var final: String?
    private(set) var error: String?
    private var done = false

    var result: String? { lock.withLock { final ?? (text.isEmpty ? nil : text) } }

    func lines(_ chunk: Data) -> [String] {
        lock.withLock {
            buffer.append(chunk)
            var out: [String] = []
            while let nl = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer[buffer.startIndex..<nl]
                buffer.removeSubrange(buffer.startIndex...nl)
                if let s = String(data: lineData, encoding: .utf8), !s.isEmpty { out.append(s) }
            }
            return out
        }
    }

    func flush() -> [String] {
        lock.withLock {
            defer { buffer.removeAll() }
            guard let s = String(data: buffer, encoding: .utf8), !s.isEmpty else { return [] }
            return [s]
        }
    }

    func append(_ t: String) { lock.withLock { text += t } }
    func setFinal(_ t: String) { lock.withLock { final = t } }
    func setError(_ m: String) { lock.withLock { if error == nil { error = m } } }

    func finisher(_ cont: CheckedContinuation<String, Error>) -> (Result<String, Error>) -> Void {
        { [self] result in
            let first: Bool = lock.withLock { defer { done = true }; return !done }
            if first { cont.resume(with: result) }
        }
    }
}

/// Finds the `claude` executable and the user's login-shell PATH (GUI apps get a minimal PATH,
/// and the npm-installed `claude` needs `node` on PATH).
enum ClaudeCodeLocator {
    static let loginPath: String = {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-l", "-c", "printf %s \"$PATH\""]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        var path = ""
        if (try? p.run()) != nil {
            // Blocking read, no waitUntilExit(): that spins the main run loop, which can re-enter this
            // lazy initializer from a SwiftUI redraw (dispatch_once trap, found 2026-11-17).
            path = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        }
        let home = NSHomeDirectory()
        let extra = ["\(home)/.npm-global/bin", "\(home)/.local/bin", "\(home)/.claude/local", "/opt/homebrew/bin",
                     "/usr/local/bin", "/usr/bin", "/bin"]
        var parts = path.split(separator: ":").map(String.init)
        for e in extra where !parts.contains(e) { parts.append(e) }
        return parts.joined(separator: ":")
    }()

    /// A path from Settings wins; otherwise the first `claude` on the login PATH.
    static func find(override: String?) -> URL? {
        let fm = FileManager.default
        if let o = override?.trimmingCharacters(in: .whitespaces), !o.isEmpty {
            let path = (o as NSString).expandingTildeInPath
            return fm.isExecutableFile(atPath: path) ? URL(fileURLWithPath: path) : nil
        }
        for dir in loginPath.split(separator: ":") {
            let candidate = "\(dir)/claude"
            if fm.isExecutableFile(atPath: candidate) { return URL(fileURLWithPath: candidate) }
        }
        return nil
    }
}
