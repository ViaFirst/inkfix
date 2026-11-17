import Foundation

/// Word-level diff (LCS over words, spaces and punctuation) for showing what changed.
enum TextDiff {
    enum Op: Equatable { case same(String), added(String), removed(String) }

    /// Above this many tokens per side the O(n·m) table gets too big; the popup shows plain text instead.
    static let maxTokens = 2500

    static func tokens(_ s: String) -> [String] {
        var result: [String] = []
        var current = ""
        var currentKind = -1
        for ch in s {
            let kind = ch.isLetter || ch.isNumber || ch == "_" ? 0 : (ch.isWhitespace ? 1 : 2)
            if kind == currentKind && kind != 2 {
                current.append(ch)
            } else {
                if !current.isEmpty { result.append(current) }
                current = String(ch)
                currentKind = kind
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    static func diff(_ old: String, _ new: String) -> [Op]? {
        let a = tokens(old), b = tokens(new)
        guard a.count <= maxTokens, b.count <= maxTokens else { return nil }
        let n = a.count, m = b.count
        // lcs[i][j] = LCS length of a[i...] and b[j...]
        var lcs = [[Int32]](repeating: [Int32](repeating: 0, count: m + 1), count: n + 1)
        if n > 0 && m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    lcs[i][j] = a[i] == b[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
                }
            }
        }
        var ops: [Op] = []
        func push(_ op: Op) {
            switch (ops.last, op) {
            case let (.same(x)?, .same(y)): ops[ops.count - 1] = .same(x + y)
            case let (.added(x)?, .added(y)): ops[ops.count - 1] = .added(x + y)
            case let (.removed(x)?, .removed(y)): ops[ops.count - 1] = .removed(x + y)
            default: ops.append(op)
            }
        }
        var i = 0, j = 0
        while i < n || j < m {
            if i < n, j < m, a[i] == b[j] {
                push(.same(a[i])); i += 1; j += 1
            } else if i < n, j == m || lcs[i + 1][j] >= lcs[i][j + 1] {
                push(.removed(a[i])); i += 1   // removed first, so it reads "old → new"
            } else {
                push(.added(b[j])); j += 1
            }
        }
        return ops
    }

    /// Number of changed (added or removed) non-space tokens: 0 means "no changes".
    static func changeCount(_ ops: [Op]) -> Int {
        ops.reduce(0) { n, op in
            switch op {
            case .same: return n
            case .added(let s), .removed(let s): return n + (s.isBlank ? 0 : 1)
            }
        }
    }
}
